# Check streaming replication of lolor large objects
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $primary = PostgreSQL::Test::Cluster->new('primary');
my ($result, $stdout, $stderr);

# Setup primary node with lolor extension
$primary->init(allows_streaming => 1);
$primary->append_conf('postgresql.conf', qq{lolor.node = 1});
$primary->start;
$primary->safe_psql('postgres', "CREATE EXTENSION lolor");

# Create a lolor large object BEFORE setting up the replica
$primary->safe_psql('postgres',
				qq(SELECT lo_from_bytea(1, 'pre-backup LO object')));

$result = $primary->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'pre-backup LO object', "Pre-backup LO created on primary");

# Take a backup and create streaming standby
my $backup_name = 'my_backup';
$primary->backup($backup_name);

my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, $backup_name,
	has_streaming => 1);
$standby->start;

# Create another lolor object on the primary AFTER standby is running
$primary->safe_psql('postgres',
				qq(SELECT lo_from_bytea(2, 'post-backup LO object')));

# Wait for standby to catch up
$primary->wait_for_replay_catchup($standby);

# Verify the pre-backup object is available on standby
$result = $standby->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'pre-backup LO object',
	"Pre-backup LO available on standby");

# Verify the post-backup object was streamed to standby
$result = $standby->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(2, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'post-backup LO object',
	"Post-backup LO replicated to standby via streaming");

$standby->stop;
$primary->stop;

done_testing();
