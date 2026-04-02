# Check lolor works after promoting a streaming standby
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

# Create lolor large objects on primary
$primary->safe_psql('postgres',
				qq(SELECT lo_from_bytea(1, 'LO before standby')));
$primary->safe_psql('postgres',
				qq(SELECT lo_from_bytea(2, 'LO after standby setup')));

# Take a backup and create streaming standby
my $backup_name = 'my_backup';
$primary->backup($backup_name);

my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, $backup_name,
	has_streaming => 1);
$standby->start;

# Create one more object on the primary and let it replicate
$primary->safe_psql('postgres',
				qq(SELECT lo_from_bytea(3, 'LO streamed to standby')));
$primary->wait_for_replay_catchup($standby);

# Stop the primary to simulate a failover
$primary->stop;

# Promote the standby
$standby->promote;

# Verify all lolor objects are readable after promotion
$result = $standby->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'LO before standby',
	"Pre-backup LO readable after promotion");

$result = $standby->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(2, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'LO after standby setup',
	"Backup-time LO readable after promotion");

$result = $standby->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(3, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'LO streamed to standby',
	"Streamed LO readable after promotion");

# Verify new lolor objects can be created on the promoted standby
$standby->safe_psql('postgres',
				qq(SELECT lo_from_bytea(4, 'LO created after promotion')));
$result = $standby->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(4, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'LO created after promotion',
	"Can create and read new lolor objects after promotion");

$standby->stop;

done_testing();
