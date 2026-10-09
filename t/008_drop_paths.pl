# Check the drop guard and the cleanup for every spelling of the drop
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('drop_paths');

$node->init;
$node->append_conf(
	'postgresql.conf', qq{
shared_preload_libraries = 'lolor'
lolor.node = 1
});
$node->start;

# DROP SCHEMA reaches the extension by dependency cascade rather than as DROP
# EXTENSION.  It must be refused while objects remain in lolor storage, and
# once they are migrated out the cleanup has to run anyway, or pg_catalog is
# left without a working lo_open().

$node->safe_psql('postgres', "CREATE EXTENSION lolor");
my $rescued = $node->safe_psql('postgres',
	"SELECT lo_from_bytea(0, 'rescued from drop schema')");

my ($result, $stdout, $stderr) =
  $node->psql('postgres', "DROP SCHEMA lolor CASCADE");
isnt($result, 0, "DROP SCHEMA CASCADE is refused while objects remain");
like(
	$stderr,
	qr/cannot drop lolor storage while it holds 1 large object/,
	"the refusal names the storage");
is( $node->safe_psql(
		'postgres',
		"SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = $rescued"
	),
	'1',
	"the object is untouched");

$node->safe_psql('postgres', "SELECT lolor.migrate_to_native()");
$node->safe_psql('postgres', "DROP SCHEMA lolor CASCADE");

is( $node->safe_psql(
		'postgres',
		"SELECT count(*) FROM pg_extension WHERE extname = 'lolor'"),
	'0',
	"DROP SCHEMA CASCADE removed the extension");

is( $node->safe_psql(
		'postgres',
		"SELECT to_regprocedure('pg_catalog.lo_open(oid,int4)') IS NOT NULL"),
	't',
	"the native lo_open() was put back");

is( $node->safe_psql(
		'postgres',
		"SELECT to_regprocedure('pg_catalog.lo_open_orig(oid,int4)') IS NULL"
	),
	't',
	"no *_orig functions were left behind");

is( $node->safe_psql(
		'postgres', "SELECT convert_from(lo_get($rescued), 'UTF8')"),
	'rescued from drop schema',
	"the large object survived in native storage");

$node->safe_psql('postgres', "SELECT lo_unlink($rescued)");

# DROP OWNED BY the extension owner reaches it the same way.

# There is no ALTER EXTENSION ... OWNER TO, so install it as the role whose
# objects are about to be dropped.  lolor is not trusted, hence SUPERUSER.
$node->safe_psql('postgres', "CREATE ROLE lolor_ext_owner SUPERUSER LOGIN");
$node->safe_psql(
	'postgres',
	"CREATE EXTENSION lolor",
	extra_params => [ '-U', 'lolor_ext_owner' ]);

my $owned = $node->safe_psql('postgres',
	"SELECT lo_from_bytea(0, 'rescued from drop owned')");

($result, $stdout, $stderr) =
  $node->psql('postgres', "DROP OWNED BY lolor_ext_owner");
isnt($result, 0, "DROP OWNED BY is refused while objects remain");
like(
	$stderr,
	qr/cannot drop lolor storage while it holds 1 large object/,
	"the refusal names the storage");

$node->safe_psql('postgres', "SELECT lolor.migrate_to_native()");
$node->safe_psql('postgres', "DROP OWNED BY lolor_ext_owner");

is( $node->safe_psql(
		'postgres',
		"SELECT count(*) FROM pg_extension WHERE extname = 'lolor'"),
	'0',
	"DROP OWNED BY the extension owner removed the extension");

is( $node->safe_psql(
		'postgres',
		"SELECT to_regprocedure('pg_catalog.lo_open(oid,int4)') IS NOT NULL"),
	't',
	"the native lo_open() was put back");

is( $node->safe_psql(
		'postgres', "SELECT convert_from(lo_get($owned), 'UTF8')"),
	'rescued from drop owned',
	"the large object survived in native storage");

# enable() and disable() rename functions in pg_catalog.  A rename keeps the
# OID, so a session that has already resolved lo_open() keeps calling the
# previous implementation.  Both therefore refuse while another session is
# connected to the database.

$node->safe_psql('postgres', "CREATE EXTENSION lolor");
my $other = $node->background_psql('postgres');
$other->query_safe("SELECT 1");

($result, $stdout, $stderr) =
  $node->psql('postgres', "SELECT lolor.disable()");
isnt($result, 0, "disable() refuses while another session is connected");
like(
	$stderr,
	qr/while other sessions are connected to the database/,
	"the refusal says why");

# Dropping the extension renames the functions back too, so it is refused
# under the same condition, and says so under its own name.
($result, $stdout, $stderr) =
  $node->psql('postgres', "DROP EXTENSION lolor");
isnt($result, 0, "the drop refuses while another session is connected");
like(
	$stderr,
	qr/cannot drop the lolor extension while other sessions are connected/,
	"and the refusal names the drop");

$other->quit;
# The backend exits after the client has gone; a disable() issued at once
# could still count it.
$node->poll_query_until(
	'postgres', qq(
	SELECT count(*) = 0 FROM pg_stat_activity
	 WHERE datname = current_database()
	   AND backend_type = 'client backend'
	   AND pid <> pg_backend_pid()))
  or die "the other session's backend did not exit";
is($node->safe_psql('postgres', "SELECT lolor.disable()"),
	't', "disable() works once the other session is gone");
is($node->safe_psql('postgres', "SELECT lolor.enable()"),
	't', "and so does enable()");
$node->safe_psql('postgres', "DROP EXTENSION lolor");

$node->stop;

done_testing();
