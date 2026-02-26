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

$subscriber->stop;
$publisher->stop;

done_testing();
