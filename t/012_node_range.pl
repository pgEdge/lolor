# lolor.node = 16 was accepted through 1.2.3 and is out of range from 1.3.0.
# The server then ignores the configured value and the node id reads as
# unset, so the update to 1.3.0 refuses and says what to change.
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('node_range');

$node->init;
$node->append_conf(
	'postgresql.conf', qq{
shared_preload_libraries = 'lolor'
lolor.node = 16
});
$node->start;

my ($result, $stdout, $stderr);

# The state of a 1.2.3 node configured as 16, right after the new library
# is installed and the server restarted.
$node->safe_psql('postgres', "CREATE EXTENSION lolor VERSION '1.2.3'");
is($node->safe_psql('postgres', "SHOW lolor.node"),
	'0', "the out-of-range node id is rejected and reads as unset");

($result, $stdout, $stderr) =
  $node->psql('postgres', "SELECT lo_creat(-1)");
isnt($result, 0, "large objects cannot be created without a node id");
like($stderr, qr/value for lolor\.node is not set/, "and the error says so");

($result, $stdout, $stderr) =
  $node->psql('postgres', "ALTER EXTENSION lolor UPDATE");
isnt($result, 0, "the update is refused while lolor.node is out of range");
like(
	$stderr,
	qr/lolor\.node is configured with a value the server rejects: .*postgresql\.conf \(lolor\.node = 16\)/,
	"and the refusal names the file that sets it");
is( $node->safe_psql(
		'postgres',
		"SELECT extversion FROM pg_extension WHERE extname = 'lolor'"),
	'1.2.3',
	"the extension is still at 1.2.3");

# The same value written in hex or octal is refused as well.
foreach my $value ('0x10', '020')
{
	$node->append_conf('postgresql.conf', "lolor.node = $value\n");
	($result, $stdout, $stderr) =
	  $node->psql('postgres', "ALTER EXTENSION lolor UPDATE");
	isnt($result, 0, "the update is refused with lolor.node = $value");
	like($stderr, qr/\(lolor\.node = \Q$value\E\)/,
		"and the refusal shows the value as written");
}

# A later line in the file overrides the earlier one, for the server and
# for the check alike.
$node->append_conf('postgresql.conf', "lolor.node = 5\n");
$node->reload;
$node->poll_query_until('postgres',
	"SELECT current_setting('lolor.node') = '5'")
  or die "lolor.node did not change after the reload";

# A database or role setting left over from 1.2.3 is rejected by the server
# in the same way.  ALTER DATABASE no longer accepts 16, so store the rows
# directly.  The first one applies to another database and does not block
# the update here.
$node->safe_psql('postgres', "CREATE DATABASE other");
$node->safe_psql('postgres', "CREATE ROLE node_range_role");
$node->safe_psql(
	'postgres', q{
INSERT INTO pg_db_role_setting
SELECT oid, 0, '{lolor.node=16}' FROM pg_database WHERE datname = 'other'});

my %settings = (
	q{SELECT oid, 0, '{lolor.node=16}'::text[] FROM pg_database
	   WHERE datname = 'postgres'} =>
	  qr/ALTER DATABASE postgres SET lolor\.node = 16/,
	q{SELECT 0, oid, '{lolor.node=0x10}'::text[] FROM pg_roles
	   WHERE rolname = 'node_range_role'} =>
	  qr/ALTER ROLE node_range_role SET lolor\.node = 0x10/,
	# Forms the server reads as 16 although they are not plain digits.
	q{SELECT oid, 0, '{lolor.node=+16}'::text[] FROM pg_database
	   WHERE datname = 'postgres'} =>
	  qr/ALTER DATABASE postgres SET lolor\.node = \+16/,
	q{SELECT 0, oid, '{lolor.node=16.0}'::text[] FROM pg_roles
	   WHERE rolname = 'node_range_role'} =>
	  qr/ALTER ROLE node_range_role SET lolor\.node = 16\.0/,
	q{SELECT d.oid, r.oid, '{work_mem=64MB,lolor.node=020}'::text[]
	    FROM pg_database d, pg_roles r
	   WHERE d.datname = 'postgres' AND r.rolname = 'node_range_role'} =>
	  qr/ALTER ROLE node_range_role IN DATABASE postgres SET lolor\.node = 020/,
);
foreach my $rows (sort keys %settings)
{
	$node->safe_psql('postgres', "INSERT INTO pg_db_role_setting $rows");
	($result, $stdout, $stderr) =
	  $node->psql('postgres', "ALTER EXTENSION lolor UPDATE");
	isnt($result, 0, "the update is refused for a stored setting");
	like($stderr, $settings{$rows}, "and the refusal names the setting");
	unlike($stderr, qr/DATABASE other/, "and not the one on another database");
	$node->safe_psql('postgres',
		"DELETE FROM pg_db_role_setting WHERE setdatabase <> "
		  . "(SELECT oid FROM pg_database WHERE datname = 'other')");
}

# In-range values written in hex or octal are fine.
$node->safe_psql('postgres', "ALTER ROLE node_range_role SET lolor.node = '0x7'");
$node->safe_psql('postgres', "ALTER DATABASE postgres SET lolor.node = '017'");

# Trying the stored values does not change the node id for the rest of the
# transaction the update runs in.
is( $node->safe_psql(
		'postgres', q{
BEGIN;
SET LOCAL client_min_messages = warning;
ALTER EXTENSION lolor UPDATE;
SHOW lolor.node;
ROLLBACK;}),
	'15',
	"the check leaves lolor.node as it was");

$node->safe_psql('postgres', "ALTER EXTENSION lolor UPDATE");
is( $node->safe_psql(
		'postgres',
		"SELECT extversion FROM pg_extension WHERE extname = 'lolor'"),
	'1.3.0',
	"the update succeeds once lolor.node is in range");
is($node->safe_psql('postgres', "SELECT lo_creat(-1)::bigint & 15"),
	'15', "new large objects carry the node id in effect");

$node->stop;

done_testing();
