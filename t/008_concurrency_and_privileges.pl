# Check migration locking, server-side file privileges and cross-node OID
# collision detection
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Cwd qw(abs_path);

my $node = PostgreSQL::Test::Cluster->new('concurrency');
my ($result, $stdout, $stderr);

$node->init;
$node->append_conf('postgresql.conf', qq{lolor.node = 1});
$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION lolor");

# ##############################################################################
#
# A migration must exclude concurrent large object activity for its whole
# transaction.  Ordinary large object access takes RowExclusiveLock, which does
# not conflict with itself, so a migration holding only that lock would let a
# concurrent write commit between the copy and the emptying of the source
# store, losing it silently.
#
# ##############################################################################

$node->safe_psql('postgres', "SELECT lo_from_bytea(0, 'to be migrated')");

my $bg = $node->background_psql('postgres');
# query_safe() treats any stderr output as a failure, and the migration
# reports its progress as a NOTICE.
$bg->query_safe("SET client_min_messages = warning");
$bg->query_safe("BEGIN");
$bg->query_safe("SELECT lolor.migrate_to_native()");

is($node->safe_psql('postgres', qq(
		SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
		WHERE c.relname IN ('pg_largeobject', 'pg_largeobject_metadata')
		  AND l.mode = 'ShareRowExclusiveLock')),
	'4',
	"migration holds ShareRowExclusiveLock on both stores");

($result, $stdout, $stderr) = $node->psql('postgres',
	"SET lock_timeout = '2s'; SELECT lo_from_bytea(0, 'concurrent write')");
like($stderr, qr/canceling statement due to lock timeout/,
	"a concurrent large object write blocks while a migration is running");

$bg->query_safe("COMMIT");
$bg->quit;

is($node->safe_psql('postgres',
		"SELECT lo_from_bytea(0, 'after commit') IS NOT NULL"),
	't', "the same write succeeds once the migration has committed");

# The migration itself must not have lost anything.
is($node->safe_psql('postgres',
		"SELECT count(*) FROM pg_catalog.pg_largeobject_metadata"),
	'1', "the migrated object is in native storage");

# ##############################################################################
#
# lo_import() and lo_export() read and write files as the server's operating
# system account.  Core revokes EXECUTE on them from PUBLIC; lolor's
# replacements must be restricted the same way, or any user could read or
# overwrite arbitrary files.
#
# ##############################################################################

$node->safe_psql('postgres', "CREATE ROLE lo_plain LOGIN");

# The server resolves relative paths against its data directory, so these
# have to be absolute.
my $filedir = abs_path(PostgreSQL::Test::Utils::tempdir());
my $srcfile = "$filedir/lolor_import_source.txt";
open(my $fh, '>', $srcfile) or die "could not write $srcfile: $!";
print $fh "imported through a large object\n";
close($fh);

($result, $stdout, $stderr) = $node->psql('postgres',
	"SELECT lo_import('$srcfile')", extra_params => [ '-U', 'lo_plain' ]);
like($stderr, qr/permission denied for function lo_import/,
	"lo_import() is not executable by an ordinary user");

my $dstfile = "$filedir/lolor_export_target.txt";
($result, $stdout, $stderr) = $node->psql('postgres',
	"SELECT lo_export(1, '$dstfile')", extra_params => [ '-U', 'lo_plain' ]);
like($stderr, qr/permission denied for function lo_export/,
	"lo_export() is not executable by an ordinary user");

ok(!-e $dstfile, "the refused lo_export() wrote no file");

# The superuser can still round-trip a file through lolor storage.
my $imported = $node->safe_psql('postgres', "SELECT lo_import('$srcfile')");
is($node->safe_psql('postgres', "SELECT convert_from(lo_get($imported), 'UTF8')"),
	"imported through a large object\n",
	"lo_import() stores the file contents in lolor storage");

$node->safe_psql('postgres', "SELECT lo_export($imported, '$dstfile')");
ok(-e $dstfile, "lo_export() wrote the file");
is(slurp_file($dstfile), "imported through a large object\n",
	"exported contents match what was imported");

# ##############################################################################
#
# DROP SCHEMA reaches the extension by dependency cascade rather than as DROP
# EXTENSION.  The cleanup has to run anyway, or the large objects are
# destroyed along with the lolor tables and pg_catalog is left without a
# working lo_open().
#
# ##############################################################################

$node->safe_psql('postgres', "SELECT lolor.migrate_from_native()");
my $rescued = $node->safe_psql('postgres',
	"SELECT lo_from_bytea(0, 'rescued from drop schema')");

$node->safe_psql('postgres', "DROP SCHEMA lolor CASCADE");

is($node->safe_psql('postgres',
		"SELECT count(*) FROM pg_extension WHERE extname = 'lolor'"),
	'0', "DROP SCHEMA CASCADE removed the extension");

is($node->safe_psql('postgres',
		"SELECT to_regprocedure('pg_catalog.lo_open(oid,int4)') IS NOT NULL"),
	't', "the native lo_open() was put back");

is($node->safe_psql('postgres',
		"SELECT to_regprocedure('pg_catalog.lo_open_orig(oid,int4)') IS NULL"),
	't', "no *_orig functions were left behind");

is($node->safe_psql('postgres', "SELECT convert_from(lo_get($rescued), 'UTF8')"),
	'rescued from drop schema',
	"the large object was migrated out rather than dropped with the schema");

$node->stop;

# ##############################################################################
#
# Native large object OIDs are not node encoded, so two nodes can hold
# different objects under the same OID.  Migrating both would converge them
# onto one row, and because the migration is hidden from replication nothing
# would report it.  Passing the peer OIDs turns that into a refusal.
#
# ##############################################################################

my $n1 = PostgreSQL::Test::Cluster->new('node1');
my $n2 = PostgreSQL::Test::Cluster->new('node2');
foreach my $n ($n1, $n2)
{
	$n->init;
	$n->start;
}
$n1->append_conf('postgresql.conf', qq{lolor.node = 1});
$n2->append_conf('postgresql.conf', qq{lolor.node = 2});
$n1->restart;
$n2->restart;

foreach my $n ($n1, $n2)
{
	$n->safe_psql('postgres', "CREATE EXTENSION lolor");
	$n->safe_psql('postgres', "SELECT lolor.disable()");
}

# Give both nodes a native object under the same OID but with different
# contents, which is exactly the situation that silently diverges.
$n1->safe_psql('postgres', "SELECT lo_from_bytea(500001, 'node one content')");
$n2->safe_psql('postgres', "SELECT lo_from_bytea(500001, 'node two content')");

foreach my $n ($n1, $n2)
{
	$n->safe_psql('postgres', "SELECT lolor.enable()");
}

my $peer_oids = $n2->safe_psql('postgres',
	"SELECT coalesce(string_agg(o::text, ','), '') FROM lolor.native_lo_oids() AS o");
is($peer_oids, '500001', "native_lo_oids() reports the peer's OIDs");

($result, $stdout, $stderr) = $n1->psql('postgres',
	"SELECT lolor.migrate_from_native(peer_oids => ARRAY[$peer_oids]::oid[])");
isnt($result, 0, "migrate_from_native() refuses a colliding peer OID");
like($stderr, qr/also held natively by another node/,
	"the refusal names the reason");

is($n1->safe_psql('postgres',
		"SELECT count(*) FROM pg_catalog.pg_largeobject_metadata"),
	'1', "the refusal left node one's native objects in place");

# Without the peer list the collision is invisible, which is why the argument
# exists; the migration itself still succeeds locally.
is($n1->safe_psql('postgres', "SELECT lolor.migrate_from_native()"),
	'1', "migration proceeds when no peer OIDs are supplied");

$n1->stop;
$n2->stop;

done_testing();
