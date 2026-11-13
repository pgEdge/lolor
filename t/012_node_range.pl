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
	qr/lolor\.node is set to a value above 15 in .*postgresql\.conf/,
	"and the refusal names the file that sets it");
is( $node->safe_psql(
		'postgres',
		"SELECT extversion FROM pg_extension WHERE extname = 'lolor'"),
	'1.2.3',
	"the extension is still at 1.2.3");

# A later line in the file overrides the earlier one, for the server and
# for the check alike.
$node->append_conf('postgresql.conf', "lolor.node = 5\n");
$node->reload;
$node->poll_query_until('postgres',
	"SELECT current_setting('lolor.node') = '5'")
  or die "lolor.node did not change after the reload";

$node->safe_psql('postgres', "ALTER EXTENSION lolor UPDATE");
is( $node->safe_psql(
		'postgres',
		"SELECT extversion FROM pg_extension WHERE extname = 'lolor'"),
	'1.3.0',
	"the update succeeds once lolor.node is in range");
is($node->safe_psql('postgres', "SELECT lo_creat(-1)::bigint & 15"),
	'5', "new large objects carry the new node id");

$node->stop;

done_testing();
