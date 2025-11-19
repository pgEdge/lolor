# Check binary upgrade
#
# Copyright (c) 2022-2025, pgEdge, Inc.
# Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $old = PostgreSQL::Test::Cluster->new('old_node');
my $new = PostgreSQL::Test::Cluster->new('new_node');
my $newbindir = $new->config_data('--bindir');
my $oldbindir = $old->config_data('--bindir');
my ($result, $stdout, $stderr);

# Prepare old node to be upgraded
$old->init;
$old->append_conf('postgresql.conf', qq{lolor.node = 1});
$old->start;
$old->safe_psql('postgres', "CREATE EXTENSION lolor");
$old->safe_psql('postgres',
				qq(SELECT lo_from_bytea(1, 'lolor LO object - 1')));
$old->safe_psql('postgres', qq(
  SET lolor.node = 1;
  SELECT lo_creat(-1);
));
$old->safe_psql('postgres', "SELECT lolor.disable()");
$old->safe_psql('postgres',
				qq(SELECT lo_from_bytea(1, 'built-in LO object - 1')));
$old->stop();

$new->init;
$new->append_conf('postgresql.conf', qq{lolor.node = 1});

command_ok(
	[
		'pg_upgrade',
		'--old-datadir' => $old->data_dir,
		'--new-datadir' => $new->data_dir,
		'--old-bindir' => $oldbindir,
		'--new-bindir' => $newbindir,
		'--link',
	],
	'run of pg_upgrade for new instance');

$new->start;
$new->safe_psql('postgres', "SELECT 1");

# Should not conflict with lolor
$new->safe_psql('postgres', "SELECT lo_from_bytea(2, 'built-in LO object - 2')");
# Should see built-in object, created on the old node
$result = $new->safe_psql('postgres', qq(
	BEGIN; -- built-in object
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
ok($result eq 'built-in LO object - 1', "Check built-in LO works after upgrade");

$new->safe_psql('postgres', "SELECT lolor.enable()");
# Should not conflict with built-in LO storage
$new->safe_psql('postgres', "SELECT lo_from_bytea(2, 'lolor LO object')");
# Should see lolor object, created on the old node
$result = $new->safe_psql('postgres', qq(
	BEGIN; -- lolor object
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
ok($result eq 'lolor LO object - 1', "Check lolor works after upgrade");

$new->stop();

done_testing();
