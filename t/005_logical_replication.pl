# Check logical replication of lolor large objects
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $publisher = PostgreSQL::Test::Cluster->new('publisher');
my $subscriber = PostgreSQL::Test::Cluster->new('subscriber');
my ($result, $stdout, $stderr);

# Setup publisher with logical replication support
$publisher->init(allows_streaming => 'logical');
$publisher->append_conf('postgresql.conf', qq{lolor.node = 1});
$publisher->start;
$publisher->safe_psql('postgres', "CREATE EXTENSION lolor");

# Create a lolor large object BEFORE setting up subscription
$publisher->safe_psql('postgres',
				qq(SELECT lo_from_bytea(1, 'pre-subscription LO')));

# Create publication for lolor tables
$publisher->safe_psql('postgres',
	"CREATE PUBLICATION lolor_pub FOR TABLE lolor.pg_largeobject, lolor.pg_largeobject_metadata");

# Setup subscriber with lolor extension (tables must exist before subscription)
$subscriber->init;
$subscriber->append_conf('postgresql.conf', qq{lolor.node = 2});
$subscriber->start;
$subscriber->safe_psql('postgres', "CREATE EXTENSION lolor");

# Create subscription
my $publisher_connstr = $publisher->connstr . ' dbname=postgres';
$subscriber->safe_psql('postgres',
	"CREATE SUBSCRIPTION lolor_sub CONNECTION '$publisher_connstr' PUBLICATION lolor_pub");

# Wait for initial table sync to complete
$subscriber->wait_for_subscription_sync($publisher, 'lolor_sub');

# Verify pre-subscription object replicated via initial sync
$result = $subscriber->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'pre-subscription LO',
	"Pre-subscription LO replicated via initial sync");

# Create another object on publisher AFTER subscription is active
$publisher->safe_psql('postgres',
				qq(SELECT lo_from_bytea(2, 'post-subscription LO')));

# Wait for subscriber to catch up with ongoing changes
$publisher->wait_for_catchup('lolor_sub');

# Verify post-subscription object replicated via streaming
$result = $subscriber->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(2, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'post-subscription LO',
	"Post-subscription LO replicated via logical streaming");

# lo_lseek: seek to offset 15, overwrite 11 bytes, verify on both nodes
$publisher->safe_psql('postgres',
	qq(SELECT lo_from_bytea(3, '0123456789abcdefghijklmnopqrstuvwxyz')));
$publisher->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(3, x'60000'::int) AS fd \\gset
	SELECT lo_lseek(:fd, 15, 0);
	SELECT lowrite(:fd, '<ADDEDDATA>');
	SELECT lo_close(:fd);
	END;
));
$publisher->wait_for_catchup('lolor_sub');

$result = $publisher->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(3, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, '0123456789abcde<ADDEDDATA>qrstuvwxyz',
	"lo_lseek: overwritten content correct on publisher");

$result = $subscriber->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(3, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, '0123456789abcde<ADDEDDATA>qrstuvwxyz',
	"lo_lseek: seeked/overwritten content replicated to subscriber");

# lo_tell: verify cursor positions (publisher only — tell is a local cursor op).
# Two separate transactions: first confirms position is 0 on a fresh open;
# second confirms position advances to 11 after writing 11 bytes.
$publisher->safe_psql('postgres',
	qq(SELECT lo_from_bytea(4, '0123456789abcdefghijklmnopqrstuvwxyz')));

# \gset suppresses lo_open output; only lo_tell and lo_close print a row each.
my $pos = $publisher->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(4, 262144) AS fd \\gset
	SELECT lo_tell(:fd);
	SELECT lo_close(:fd);
	END;
));
is((split /\n/, $pos)[0], '0', "lo_tell: position at open is 0");

# lowrite prints one row, then lo_tell prints one row, then lo_close one row.
$pos = $publisher->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(4, x'60000'::int) AS fd \\gset
	SELECT lowrite(:fd, '<ADDEDDATA>');
	SELECT lo_tell(:fd);
	SELECT lo_close(:fd);
	END;
));
is((split /\n/, $pos)[1], '11', "lo_tell: position after 11-byte write is 11");

$publisher->wait_for_catchup('lolor_sub');

$pos = $subscriber->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(4, x'60000'::int) AS fd \\gset
	SELECT lowrite(:fd, '<ADDEDDATA>');
	SELECT lo_tell(:fd);
	SELECT lo_close(:fd);
	END;
));
is((split /\n/, $pos)[1], '11',
	"lo_tell: position after 11-byte write is 11 on subscriber");

# lo_truncate: truncate to 10 bytes, verify prefix on both nodes
$publisher->safe_psql('postgres',
	qq(SELECT lo_from_bytea(5, '0123456789abcdefghijklmnopqrstuvwxyz')));
$publisher->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(5, x'60000'::int) AS fd \\gset
	SELECT lo_truncate(:fd, 10);
	SELECT lo_close(:fd);
	END;
));
$publisher->wait_for_catchup('lolor_sub');

$result = $publisher->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(5, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, '0123456789', "lo_truncate: only prefix survives on publisher");

$result = $subscriber->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(5, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, '0123456789', "lo_truncate: truncated content replicated to subscriber");

# Catalog consistency: pg_largeobject_metadata and pg_largeobject row counts
# must match between publisher and subscriber after all operations.
my $pub_meta = $publisher->safe_psql('postgres',
	"SELECT count(*) FROM lolor.pg_largeobject_metadata");
my $sub_meta = $subscriber->safe_psql('postgres',
	"SELECT count(*) FROM lolor.pg_largeobject_metadata");
is($sub_meta, $pub_meta,
	"catalog consistency: pg_largeobject_metadata row count matches across nodes");

my $pub_lo = $publisher->safe_psql('postgres',
	"SELECT count(*) FROM lolor.pg_largeobject");
my $sub_lo = $subscriber->safe_psql('postgres',
	"SELECT count(*) FROM lolor.pg_largeobject");
is($sub_lo, $pub_lo,
	"catalog consistency: pg_largeobject row count matches across nodes");

$subscriber->stop;
$publisher->stop;

done_testing();
