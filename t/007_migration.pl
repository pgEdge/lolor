# Check large object migration between native and lolor storage
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('migration');
my ($result, $stdout, $stderr);

$node->init(allows_streaming => 'logical');
$node->append_conf('postgresql.conf', qq{lolor.node = 1});
$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION lolor");

# ##############################################################################
#
# Build native large objects covering the shapes that migration has to
# preserve, then move them into lolor storage and back.
#
# ##############################################################################

$node->safe_psql('postgres', "SELECT lolor.disable()");
$node->safe_psql('postgres', "CREATE ROLE lo_owner");
$node->safe_psql('postgres', "CREATE ROLE lo_grantee");

my $plain = $node->safe_psql('postgres',
	"SELECT lo_from_bytea(0, 'annotated native object')");
$node->safe_psql('postgres', qq(
	ALTER LARGE OBJECT $plain OWNER TO lo_owner;
	GRANT SELECT ON LARGE OBJECT $plain TO lo_grantee;
	COMMENT ON LARGE OBJECT $plain IS 'survives the round trip';
));

# A sparse object: a few bytes at offset 0 and a few 10MB in.
my $sparse = $node->safe_psql('postgres', "SELECT lo_create(0)");
$node->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open($sparse, x'60000'::int) AS fd \\gset
	SELECT lowrite(:fd, 'start');
	SELECT lo_lseek64(:fd, 10000000, 0);
	SELECT lowrite(:fd, 'end');
	SELECT lo_close(:fd);
	COMMIT;
));

# An object with no data pages at all.
my $empty = $node->safe_psql('postgres', "SELECT lo_create(0)");

my $native_pages = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_catalog.pg_largeobject");

$node->safe_psql('postgres', "SELECT lolor.enable()");
$node->safe_psql('postgres', "SELECT lolor.migrate_from_native()");

is($node->safe_psql('postgres',
		"SELECT count(*) FROM pg_catalog.pg_largeobject_metadata"),
	'0', "native storage emptied by migrate_from_native()");

is($node->safe_psql('postgres',
		"SELECT count(*) FROM lolor.pg_largeobject"),
	$native_pages,
	"page count preserved exactly, so sparse objects stay sparse");

is($node->safe_psql('postgres',
		"SELECT count(*) FROM pg_shdepend WHERE classid = 'pg_largeobject'::regclass "
	  . "AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())"),
	'0', "native shared dependencies removed with the objects");

is($node->safe_psql('postgres',
		"SELECT description FROM lolor.pg_largeobject_description WHERE loid = $plain"),
	'survives the round trip', "comment parked while in lolor storage");

is($node->safe_psql('postgres',
		"SELECT pg_get_userbyid(lomowner) FROM lolor.pg_largeobject_metadata WHERE oid = $plain"),
	'lo_owner', "owner preserved into lolor storage");

is($node->safe_psql('postgres', "SELECT convert_from(lo_get($plain), 'UTF8')"),
	'annotated native object', "content readable from lolor storage");

is($node->safe_psql('postgres', "SELECT length(lo_get($sparse))"),
	'10000003', "sparse object keeps its logical length");

is($node->safe_psql('postgres', "SELECT length(lo_get($empty))"),
	'0', "object with no data pages survives");

# ##############################################################################
#
# Everything must come back intact, including the catalog bookkeeping that
# only native storage participates in.
#
# ##############################################################################

$node->safe_psql('postgres', "SELECT lolor.migrate_to_native()");

is($node->safe_psql('postgres',
		"SELECT count(*) FROM lolor.pg_largeobject_metadata"),
	'0', "lolor storage emptied by migrate_to_native()");

is($node->safe_psql('postgres',
		"SELECT pg_get_userbyid(lomowner) FROM pg_catalog.pg_largeobject_metadata WHERE oid = $plain"),
	'lo_owner', "owner restored");

is($node->safe_psql('postgres',
		"SELECT string_agg(deptype::text || ':' || refobjid::regrole::text, ',' ORDER BY deptype) "
	  . "FROM pg_shdepend WHERE classid = 'pg_largeobject'::regclass AND objid = $plain "
	  . "AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())"),
	'a:lo_grantee,o:lo_owner',
	"owner and ACL grantee recorded in pg_shdepend");

is($node->safe_psql('postgres',
		"SELECT description FROM pg_description "
	  . "WHERE classoid = 'pg_largeobject'::regclass AND objoid = $plain"),
	'survives the round trip', "comment reinstated on the catalog object");

is($node->safe_psql('postgres',
		"SELECT count(*) FROM lolor.pg_largeobject_description"),
	'0', "comment parking table drained");

is($node->safe_psql('postgres', "SELECT count(*) FROM pg_catalog.pg_largeobject"),
	$native_pages, "page count still exact after the return trip");

# DROP ROLE must now see the objects, which a raw catalog update would not
# have allowed.
($result, $stdout, $stderr) = $node->psql('postgres', "DROP ROLE lo_owner");
like($stderr, qr/cannot be dropped because some objects depend on it/,
	"DROP ROLE refuses while the role owns migrated large objects");

($result, $stdout, $stderr) = $node->psql('postgres', "DROP ROLE lo_grantee");
like($stderr, qr/cannot be dropped because some objects depend on it/,
	"DROP ROLE refuses for an ACL grantee of a migrated large object");

# ##############################################################################
#
# Migrated objects must survive a restart, and an unclean one.
#
# ##############################################################################

$node->safe_psql('postgres', "SELECT lolor.migrate_from_native()");
$node->restart;

is($node->safe_psql('postgres', "SELECT convert_from(lo_get($plain), 'UTF8')"),
	'annotated native object', "content survives a clean restart");

$node->safe_psql('postgres',
	"SELECT lo_from_bytea(0, 'written before a crash') AS o");
my $crash_oid = $node->safe_psql('postgres',
	"SELECT oid FROM lolor.pg_largeobject_metadata ORDER BY oid DESC LIMIT 1");

$node->stop('immediate');
$node->start;

is($node->safe_psql('postgres', "SELECT convert_from(lo_get($plain), 'UTF8')"),
	'annotated native object', "content survives an immediate stop and recovery");

is($node->safe_psql('postgres', "SELECT convert_from(lo_get($crash_oid), 'UTF8')"),
	'written before a crash',
	"a committed object written just before the crash is recovered");

# ##############################################################################
#
# Without spock there is no way to keep the migration out of logical decoding,
# so the presence of a logical slot must stop it rather than let subscribers
# diverge.
#
# ##############################################################################

$node->safe_psql('postgres', "SELECT lolor.migrate_to_native()");
$node->safe_psql('postgres',
	"SELECT pg_create_logical_replication_slot('lolor_test_slot', 'pgoutput')");

($result, $stdout, $stderr) =
	$node->psql('postgres', "SELECT lolor.migrate_from_native()");
is($stdout, '-1',
	"migrate_from_native() refuses with a logical slot present and reports -1");
like($stderr, qr/logical replication slot\(s\) exist/,
	"refusal explains why");

is($node->safe_psql('postgres',
		"SELECT count(*) > 0 FROM pg_catalog.pg_largeobject_metadata"),
	't', "refusal left the native objects untouched");

# The zero-object case returns early, so put something in lolor storage for
# the guard to actually be reached.
$node->safe_psql('postgres', "SELECT lo_from_bytea(0, 'held in lolor storage')");

($result, $stdout, $stderr) =
	$node->psql('postgres', "SELECT lolor.migrate_to_native()");
isnt($result, 0, "migrate_to_native() raises an error rather than reporting -1");
like($stderr, qr/cannot migrate large objects/,
	"migrate_to_native() refuses on the drop path rather than losing objects");

$node->safe_psql('postgres',
	"SELECT pg_drop_replication_slot('lolor_test_slot')");

is($node->safe_psql('postgres', "SELECT lolor.migrate_from_native() > 0"),
	't', "migration proceeds once the slot is gone");

$node->stop;
done_testing();
