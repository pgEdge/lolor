# The library refuses critical operations while the installed extension is
# another version, and ALTER EXTENSION lolor UPDATE makes them agree.
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('version_skew');

$node->init;
$node->append_conf(
	'postgresql.conf', qq{
shared_preload_libraries = 'lolor'
lolor.node = 1
});
$node->start;

# quit waits for psql to exit, not for its backend, and the session checks
# would still count a backend that has not exited yet.
sub wait_for_other_sessions_to_exit
{
	$node->poll_query_until(
		'postgres', qq(
		SELECT count(*) = 0 FROM pg_stat_activity
		 WHERE datname = current_database()
		   AND backend_type = 'client backend'
		   AND pid <> pg_backend_pid()))
	  or die "the other sessions' backends did not exit";
	return;
}

my ($result, $stdout, $stderr);

# The library under test is newer than the extension: the state right after
# the binaries are upgraded and before ALTER EXTENSION UPDATE.
$node->safe_psql('postgres', "CREATE EXTENSION lolor VERSION '1.2.3'");
is($node->safe_psql('postgres', "SELECT lolor.is_enabled()"),
	't', "1.2.3 is installed and enabled");

my $other = $node->background_psql('postgres');
$other->query_safe("SELECT 1");

# The drop would run 1.2.3's disable(), so it is refused on the version,
# before the session count, and renames nothing.
($result, $stdout, $stderr) =
  $node->psql('postgres', "DROP EXTENSION lolor");
isnt($result, 0, "the drop is refused while the versions disagree");
like(
	$stderr,
	qr/cannot drop the lolor extension: the lolor library is version 1\.3\.0 but the installed extension is version 1\.2\.3/,
	"and the refusal names both versions");
is( $node->safe_psql(
		'postgres',
		"SELECT to_regprocedure('pg_catalog.lo_open_orig(oid,int4)') IS NOT NULL"
	),
	't',
	"the native functions are still parked");

# Updating the extension needs no sole access.
$node->safe_psql('postgres', "ALTER EXTENSION lolor UPDATE");
is( $node->safe_psql(
		'postgres', "SELECT extversion FROM pg_extension WHERE extname = 'lolor'"),
	'1.3.0',
	"ALTER EXTENSION lolor UPDATE brings the extension to 1.3.0");
is($node->safe_psql('postgres', "SELECT lolor.is_enabled()"),
	't', "and lolor is still enabled");

# With the versions in agreement the session check applies again.
($result, $stdout, $stderr) =
  $node->psql('postgres', "DROP EXTENSION lolor");
isnt($result, 0, "the drop is refused while another session is connected");
like(
	$stderr,
	qr/cannot drop the lolor extension while other sessions are connected/,
	"and the refusal says why");

# A 1.3.0 SQL entry point asks the library too.  Pretend the library is
# ahead of the installed SQL by changing extversion, then put it back.
$node->safe_psql('postgres',
	"UPDATE pg_extension SET extversion = '1.2.9' WHERE extname = 'lolor'");
foreach my $call (
	'lolor.disable()', 'lolor.enable()',
	'lolor.migrate_to_native()', 'lolor.check_orphans()')
{
	($result, $stdout, $stderr) =
	  $node->psql('postgres', "SELECT $call");
	isnt($result, 0, "$call is refused while the versions disagree");
	like(
		$stderr,
		qr/the lolor library is version 1\.3\.0 but the installed extension is version 1\.2\.9/,
		"and $call says why");
}
$node->safe_psql('postgres',
	"UPDATE pg_extension SET extversion = '1.3.0' WHERE extname = 'lolor'");

$other->quit;
wait_for_other_sessions_to_exit();

$node->safe_psql('postgres', "DROP EXTENSION lolor");
is( $node->safe_psql(
		'postgres',
		"SELECT to_regprocedure('pg_catalog.lo_open_orig(oid,int4)') IS NULL "
		  . "AND to_regprocedure('pg_catalog.lo_open(oid,int4)') IS NOT NULL"),
	't',
	"once alone, the drop restores the native functions");

# A standalone backend is not refused as a non-client process: nothing else
# can be connected to it.
$node->safe_psql('postgres', "CREATE EXTENSION lolor");
$node->stop;
my $sql = "SELECT lolor.disable();\nSELECT lolor.enable();\n";
my ($out, $err);
IPC::Run::run(
	[
		'postgres', '--single', '-F', '-c', 'exit_on_error=true',
		'-D', $node->data_dir, 'postgres'
	],
	'<' => \$sql,
	'>' => \$out,
	'2>' => \$err);
unlike($err, qr/cannot (disable|enable) lolor from/,
	"disable() and enable() run in a standalone backend");
$node->start;
is($node->safe_psql('postgres', "SELECT lolor.is_enabled()"),
	't', "and leave lolor enabled");
$node->safe_psql('postgres', "DROP EXTENSION lolor");

$node->stop;

done_testing();
