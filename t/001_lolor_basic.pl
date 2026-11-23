# Single-node tests of lolor on a patched server.
#
# Checks that every large object function keeps working with lolor loaded and
# the large object catalogs logically logged, that the changes are decoded as
# expected, and that the setup survives the usual operational paths: dump and
# restore, a physical standby, DROP/CREATE EXTENSION.
#
# Copyright (c) 2022-2026, pgEdge, Inc.

use strict;
use warnings FATAL => 'all';

use File::Compare;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init(allows_streaming => 'logical');
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'lolor'");
$node->append_conf('postgresql.conf', "lolor.node = 3");
$node->start;

# Run PL/pgSQL, expecting it to complete.  The block raises an exception when
# it finds something wrong, and psql reports it.
sub plpgsql_ok
{
	my ($body, $name) = @_;
	my ($rc, $out, $err) =
	  $node->psql('postgres', "DO \$test\$ $body \$test\$;");
	is($rc, 0, $name) or diag($err);
}

# ---------------------------------------------------------------------------
# Setup and the install script
# ---------------------------------------------------------------------------

$node->safe_psql('postgres', 'CREATE EXTENSION lolor');

$node->safe_psql(
	'postgres', q{
CREATE FUNCTION t_eq(a anyelement, b anyelement, what text) RETURNS void AS $$
BEGIN
	IF a IS DISTINCT FROM b THEN
		RAISE EXCEPTION '%: got %, expected %', what, a, b;
	END IF;
END $$ LANGUAGE plpgsql;
CREATE FUNCTION t_fails(stmt text, pattern text) RETURNS void AS $$
BEGIN
	EXECUTE stmt;
	RAISE EXCEPTION 'expected failure matching "%", but "%" succeeded', pattern, stmt;
EXCEPTION WHEN others THEN
	IF SQLERRM NOT LIKE pattern THEN RAISE; END IF;
END $$ LANGUAGE plpgsql;
});

is( $node->safe_psql(
		'postgres',
		q{SELECT string_agg(relname || '=' || relreplident::text, ',' ORDER BY relname)
		  FROM pg_class
		  WHERE oid IN ('pg_largeobject'::regclass,
						'pg_largeobject_metadata'::regclass)}),
	'pg_largeobject=d,pg_largeobject_metadata=d',
	'CREATE EXTENSION gives both large object catalogs a replica identity');

is($node->safe_psql('postgres', 'SELECT lolor.replication_enabled()'),
	't', 'replication_enabled() reports it');

is($node->safe_psql('postgres', 'SHOW allow_system_table_mods'),
	'off', 'allow_system_table_mods is not left on');

# ---------------------------------------------------------------------------
# OID generation
# ---------------------------------------------------------------------------

is( $node->safe_psql(
		'postgres',
		q{SELECT bool_and(o::bigint & 15 = 3)
		  FROM (SELECT lo_create(0) AS o FROM generate_series(1, 20)
				UNION ALL SELECT lo_creat(-1)
				UNION ALL SELECT lo_from_bytea(0, 'x')) s}),
	't', 'generated OIDs carry the node id in the low bits');

is( $node->safe_psql(
		'postgres',
		q{SELECT count(DISTINCT o) FROM (SELECT lo_create(0) AS o
										 FROM generate_series(1, 500)) s}),
	'500', 'generated OIDs are distinct');

is($node->safe_psql('postgres', 'SELECT lo_create(7100001)'),
	'7100001', 'an explicitly requested OID is used as given');
$node->safe_psql('postgres', 'SELECT lo_unlink(7100001)');

# ---------------------------------------------------------------------------
# The large object functions
# ---------------------------------------------------------------------------

plpgsql_ok(
	q{
DECLARE o oid; fd int;
BEGIN
	o := lo_create(0);
	fd := lo_open(o, 393216);			-- INV_READ | INV_WRITE
	PERFORM t_eq(lowrite(fd, 'hello world'::bytea), 11, 'lowrite');
	PERFORM t_eq(lo_tell(fd), 11, 'lo_tell after write');
	PERFORM t_eq(lo_lseek(fd, 6, 0), 6, 'lo_lseek SEEK_SET');
	PERFORM t_eq(loread(fd, 5), 'world'::bytea, 'loread');
	PERFORM t_eq(lo_lseek(fd, -5, 2), 6, 'lo_lseek SEEK_END');
	PERFORM t_eq(lo_lseek(fd, -3, 1), 3, 'lo_lseek SEEK_CUR');
	PERFORM t_eq(lo_close(fd), 0, 'lo_close');
	PERFORM t_eq(lo_get(o), 'hello world'::bytea, 'lo_get');
	PERFORM t_eq(lo_unlink(o), 1, 'lo_unlink');
END},
	'create, open, write, seek, tell, read, close, unlink');

plpgsql_ok(
	q{
DECLARE o oid; fd int;
BEGIN
	o := lo_from_bytea(0, 'abcdefghij'::bytea);
	fd := lo_open(o, 393216);
	PERFORM t_eq(lo_truncate(fd, 4), 0, 'lo_truncate shrinks');
	PERFORM t_eq(lo_get(o), 'abcd'::bytea, 'content after shrink');
	PERFORM t_eq(lo_truncate64(fd, 20), 0, 'lo_truncate64 extends');
	PERFORM t_eq(length(lo_get(o)), 20, 'length after extend');
	PERFORM t_eq(get_byte(lo_get(o), 10), 0, 'extension is zero filled');
	PERFORM t_eq(lo_lseek64(fd, 5000000000, 0), 5000000000, 'lo_lseek64 beyond 4GB');
	PERFORM t_eq(lo_tell64(fd), 5000000000, 'lo_tell64 beyond 4GB');
	PERFORM lo_close(fd);
	PERFORM lo_unlink(o);
END},
	'lo_truncate, lo_truncate64, lo_lseek64, lo_tell64');

plpgsql_ok(
	q{
DECLARE o oid;
BEGIN
	o := lo_from_bytea(0, 'ABCDEFGHIJ'::bytea);
	PERFORM lo_put(o, 3, 'xyz'::bytea);
	PERFORM t_eq(lo_get(o), 'ABCxyzGHIJ'::bytea, 'lo_put');
	PERFORM t_eq(lo_get(o, 2, 4), 'Cxyz'::bytea, 'lo_get with offset and length');
	PERFORM t_eq(lo_get(o, 8, 100), 'IJ'::bytea, 'lo_get past the end');
	PERFORM t_eq(lo_from_bytea(7100002, 'q'::bytea), 7100002::oid, 'lo_from_bytea with OID');
	PERFORM lo_unlink(o);
	PERFORM lo_unlink(7100002);
END},
	'lo_put, lo_get, lo_from_bytea');

plpgsql_ok(
	q{
DECLARE o oid; data bytea; expected bytea; fd int;
BEGIN
	-- 100000 bytes: 49 pages
	SELECT convert_to(string_agg(md5(g::text), ''), 'UTF8') INTO data
	  FROM generate_series(1, 3125) g;
	PERFORM t_eq(length(data), 100000, 'test data size');
	o := lo_from_bytea(0, data);
	PERFORM t_eq(md5(lo_get(o)), md5(data), 'multi-page round trip');
	-- a write across the page boundary at 2048
	PERFORM lo_put(o, 2040, '0123456789ABCDEFGHIJ'::bytea);
	expected := overlay(data placing '0123456789ABCDEFGHIJ'::bytea from 2041 for 20);
	PERFORM t_eq(md5(lo_get(o)), md5(expected), 'write across a page boundary');
	PERFORM t_eq(lo_get(o, 2030, 40), substring(expected from 2031 for 40),
				 'read across a page boundary');
	fd := lo_open(o, 262144);
	PERFORM lo_lseek(fd, 50000, 0);
	PERFORM t_eq(loread(fd, 3000), substring(expected from 50001 for 3000), 'loread over pages');
	PERFORM lo_close(fd);
	PERFORM lo_unlink(o);
END},
	'objects that span many pages');

plpgsql_ok(
	q{
DECLARE o oid; empty oid;
BEGIN
	o := lo_create(0);
	PERFORM lo_put(o, 10000, 'x'::bytea);
	PERFORM t_eq(length(lo_get(o)), 10001, 'sparse length');
	PERFORM t_eq(get_byte(lo_get(o), 5000), 0, 'hole reads as zero');
	PERFORM t_eq(get_byte(lo_get(o), 10000), 120, 'byte after the hole');
	empty := lo_create(0);
	PERFORM t_eq(length(lo_get(empty)), 0, 'empty object');
	PERFORM lo_unlink(o);
	PERFORM lo_unlink(empty);
END},
	'holes and empty objects');

# lo_import and lo_export, with files.
{
	my $dir = PostgreSQL::Test::Utils::tempdir;
	my $src = "$dir/lo_source.bin";
	my $dst = "$dir/lo_export.bin";
	my $dst2 = "$dir/lo_export2.bin";

	open(my $fh, '>', $src) or die "could not create $src: $!";
	binmode($fh);
	print $fh map { chr($_ % 256) } 0 .. 9999;
	close($fh);

	my $oid = $node->safe_psql('postgres', "SELECT lo_import('$src')");
	is($oid & 15, 3, 'lo_import allocates an OID with the node id');
	$node->safe_psql('postgres', "SELECT lo_export($oid, '$dst')");
	is(compare($src, $dst), 0, 'lo_export writes back what lo_import read');

	is( $node->safe_psql('postgres', "SELECT lo_import('$src', 7100003)"),
		'7100003', 'lo_import with an explicit OID');
	$node->safe_psql('postgres', "SELECT lo_export(7100003, '$dst2')");
	is(compare($src, $dst2), 0, 'round trip with an explicit OID');
	$node->safe_psql('postgres', "SELECT lo_unlink($oid), lo_unlink(7100003)");
}

plpgsql_ok(
	q{
DECLARE o oid;
BEGIN
	o := lo_from_bytea(0, 'x'::bytea);
	PERFORM t_eq(lo_unlink(o), 1, 'first unlink');
	PERFORM t_fails(format('SELECT lo_unlink(%s)', o), '%does not exist%');
	PERFORM t_fails(format('SELECT lo_open(%s, 262144)', o), '%does not exist%');
	o := lo_from_bytea(0, 'x'::bytea);
	PERFORM t_fails(format('SELECT lowrite(lo_open(%s, 262144), ''y''::bytea)', o),
					'%not opened for writing%');
	PERFORM t_fails(format('SELECT lo_create(%s)', o), '%duplicate key%');
	PERFORM lo_unlink(o);
END},
	'error cases');

# Permissions, ownership and comments.
$node->safe_psql('postgres', 'CREATE ROLE lo_reader');
plpgsql_ok(
	q{
DECLARE o oid;
BEGIN
	o := lo_from_bytea(0, 'secret'::bytea);
	SET LOCAL ROLE lo_reader;
	PERFORM t_fails(format('SELECT lo_open(%s, 262144)', o), '%permission denied%');
	RESET ROLE;
	EXECUTE format('GRANT SELECT ON LARGE OBJECT %s TO lo_reader', o);
	SET LOCAL ROLE lo_reader;
	PERFORM t_eq(lo_get(o), 'secret'::bytea, 'read after GRANT');
	PERFORM t_fails(format('SELECT lowrite(lo_open(%s, 393216), ''x''::bytea)', o), '%permission denied%');
	RESET ROLE;
	EXECUTE format('ALTER LARGE OBJECT %s OWNER TO lo_reader', o);
	PERFORM t_eq((SELECT lomowner::regrole::text FROM pg_largeobject_metadata WHERE oid = o),
				 'lo_reader', 'owner changed');
	EXECUTE format('COMMENT ON LARGE OBJECT %s IS ''a comment''', o);
	PERFORM t_eq(obj_description(o, 'pg_largeobject'), 'a comment', 'comment');
	PERFORM lo_unlink(o);
END},
	'GRANT, ALTER LARGE OBJECT OWNER, COMMENT ON LARGE OBJECT');

# Transactions.
$node->safe_psql(
	'postgres', q{
BEGIN;
SELECT lo_from_bytea(7100010, 'rolled back');
ROLLBACK;
BEGIN;
SELECT lo_from_bytea(7100011, 'kept');
SAVEPOINT s;
SELECT lo_from_bytea(7100012, 'discarded');
SELECT lo_put(7100011, 0, 'KEPT');
ROLLBACK TO s;
COMMIT;
});
is( $node->safe_psql(
		'postgres',
		q{SELECT string_agg(oid::text || ':' || convert_from(lo_get(oid), 'UTF8'), ',' ORDER BY oid)
		  FROM pg_largeobject_metadata WHERE oid BETWEEN 7100010 AND 7100012}),
	'7100011:kept',
	'rollback and rollback to savepoint undo large object changes');
$node->safe_psql('postgres', 'SELECT lo_unlink(7100011)');

# ---------------------------------------------------------------------------
# What logical decoding sees
# ---------------------------------------------------------------------------

$node->safe_psql('postgres',
	"SELECT pg_create_logical_replication_slot('lolor_t', 'test_decoding')");

$node->safe_psql(
	'postgres', q{
SELECT lo_from_bytea(7100020,
	(SELECT convert_to(string_agg(md5(g::text), ''), 'UTF8') FROM generate_series(1, 3125) g));
SELECT lo_put(7100020, 5000, 'Z');
SELECT lo_truncate64(lo_open(7100020, 131072), 4096);
SELECT lo_unlink(7100020);
});

my @changes = split /\n/,
  $node->safe_psql('postgres',
	q{SELECT data FROM pg_logical_slot_get_changes('lolor_t', NULL, NULL)
	  WHERE data !~ '^(BEGIN|COMMIT)'});

ok(@changes > 0, 'large object changes are decoded');
is( scalar(grep { !/^table pg_catalog\.pg_largeobject(_metadata)?: / } @changes),
	0, 'and they are changes to the large object catalogs only');
is( scalar(grep { /^table pg_catalog\.pg_largeobject: INSERT:/ } @changes),
	49, 'one INSERT per page');
# the overwrite, and the truncate, which rewrites the page it ends on
is( scalar(grep { /^table pg_catalog\.pg_largeobject: UPDATE: loid\[oid\]:7100020 pageno\[integer\]:2 data\[bytea\]/ } @changes),
	2, 'overwrite and truncate are decoded as UPDATEs of the page');
is( scalar(grep { /^table pg_catalog\.pg_largeobject: DELETE: loid\[oid\]:7100020 pageno\[integer\]:\d+$/ } @changes),
	49, 'every page DELETE carries the key');
is( scalar(grep { /^table pg_catalog\.pg_largeobject_metadata: DELETE: oid\[oid\]:7100020$/ } @changes),
	1, 'the metadata DELETE carries the key');

$node->safe_psql('postgres', "SELECT pg_drop_replication_slot('lolor_t')");

# ---------------------------------------------------------------------------
# Dump and restore
# ---------------------------------------------------------------------------

$node->safe_psql(
	'postgres', q{
SELECT lo_from_bytea(7100030, convert_to(repeat('dump me ', 1000), 'UTF8'));
SELECT lo_put(7100030, 100, 'PATCH');
});
my $expected_md5 = $node->safe_psql('postgres',
	'SELECT md5(lo_get(7100030))');

my $dump = $node->basedir . '/lolor.dump';
$node->command_ok(
	[ 'pg_dump', '--format=custom', '--file' => $dump,
		'--dbname' => $node->connstr('postgres') ],
	'pg_dump with large objects');
$node->safe_psql('postgres', 'CREATE DATABASE restored');
$node->command_ok(
	[ 'pg_restore', '--exit-on-error', '--dbname' => $node->connstr('restored'), $dump ],
	'pg_restore into a new database');
is($node->safe_psql('restored', 'SELECT md5(lo_get(7100030))'),
	$expected_md5, 'restored large object has the same content and OID');
is( $node->safe_psql('restored', 'SELECT lolor.replication_enabled()'),
	't', 'the extension is set up again in the restored database');

# ---------------------------------------------------------------------------
# A physical standby
# ---------------------------------------------------------------------------

$node->backup('lolor_backup');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($node, 'lolor_backup', has_streaming => 1);
$standby->start;
$node->safe_psql('postgres',
	q{SELECT lo_from_bytea(7100031, 'on the standby'::bytea)});
$node->wait_for_catchup($standby);
is( $standby->safe_psql('postgres', 'SELECT convert_from(lo_get(7100031), \'UTF8\')'),
	'on the standby', 'large objects are readable on a standby');
is($standby->safe_psql('postgres', 'SELECT lolor.replication_enabled()'),
	't', 'with the replica identity in place');
$standby->stop;

# ---------------------------------------------------------------------------
# DROP and CREATE EXTENSION
# ---------------------------------------------------------------------------

$node->safe_psql('postgres', 'DROP EXTENSION lolor');
is( $node->safe_psql(
		'postgres',
		q{SELECT string_agg(relreplident::text, ',') FROM pg_class
		  WHERE oid IN ('pg_largeobject'::regclass, 'pg_largeobject_metadata'::regclass)}),
	'n,n', 'DROP EXTENSION switches logging off again');
is($node->safe_psql('postgres', 'SELECT convert_from(lo_get(7100031), \'UTF8\')'),
	'on the standby', 'large objects are untouched by DROP EXTENSION');

$node->safe_psql('postgres', 'CREATE EXTENSION lolor');
is($node->safe_psql('postgres', 'SELECT lolor.replication_enabled()'),
	't', 'CREATE EXTENSION switches it on again');

# DROP SCHEMA ... CASCADE removes the extension without running DROP EXTENSION
# and so without our event trigger.  That must not break large objects.
$node->safe_psql('postgres', 'DROP SCHEMA lolor CASCADE');
is($node->safe_psql('postgres', 'SELECT convert_from(lo_get(7100031), \'UTF8\')'),
	'on the standby', 'large objects work after DROP SCHEMA lolor CASCADE');
$node->safe_psql('postgres', 'CREATE EXTENSION lolor');
$node->safe_psql('postgres', 'SELECT lolor.set_replica_identity(true)');

# ---------------------------------------------------------------------------
# Server start and extension creation requirements
# ---------------------------------------------------------------------------

{
	my $bad = PostgreSQL::Test::Cluster->new('badnode');
	$bad->init;
	$bad->append_conf('postgresql.conf', "shared_preload_libraries = 'lolor'");
	$bad->append_conf('postgresql.conf', "lolor.node = 16");
	ok(!$bad->start(fail_ok => 1), 'lolor.node = 16 does not fit and is refused');
	like(slurp_file($bad->logfile),
		qr/invalid value "16" for parameter "lolor\.node"/,
		'with a clear message');
}

{
	my $unset = PostgreSQL::Test::Cluster->new('unset');
	$unset->init;
	$unset->append_conf('postgresql.conf', "shared_preload_libraries = 'lolor'");
	$unset->start;
	$unset->safe_psql('postgres', 'CREATE EXTENSION lolor');
	my ($rc, $out, $err) = $unset->psql('postgres', 'SELECT lo_create(0)');
	isnt($rc, 0, 'no OID can be generated without lolor.node');
	like($err, qr/lolor\.node is not set/, 'and the error says so');
	is($unset->safe_psql('postgres', 'SELECT lo_create(7100040)'),
		'7100040', 'but an explicit OID needs no node id');
	($rc, $out, $err) = $unset->psql('postgres', 'SET lolor.node = 5');
	like($err, qr/cannot be changed without restarting/,
		'lolor.node cannot change on a running server');
	$unset->stop;
}

{
	my $nopreload = PostgreSQL::Test::Cluster->new('nopreload');
	$nopreload->init;
	$nopreload->start;
	my ($rc, $out, $err) = $nopreload->psql('postgres', 'CREATE EXTENSION lolor');
	isnt($rc, 0, 'CREATE EXTENSION fails if lolor is not preloaded');
	like($err, qr/must be loaded via "shared_preload_libraries"/, 'with a clear message');
	$nopreload->stop;
}

$node->stop;
done_testing();
