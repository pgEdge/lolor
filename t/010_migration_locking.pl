# Check migration locking and cross-node OID collision detection
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('migration_locking');
my ($result, $stdout, $stderr);

$node->init;
$node->append_conf('postgresql.conf', qq{pg_lolor.node = 1});
$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION pg_lolor");

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

is( $node->safe_psql(
		'postgres', qq(
		SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
		WHERE c.relname IN ('pg_largeobject', 'pg_largeobject_metadata')
		  AND l.mode = 'ShareRowExclusiveLock')),
	'4',
	"migration holds ShareRowExclusiveLock on both stores");

($result, $stdout, $stderr) = $node->psql('postgres',
	"SET lock_timeout = '2s'; SELECT lo_from_bytea(0, 'concurrent write')");
like(
	$stderr,
	qr/canceling statement due to lock timeout/,
	"a concurrent large object write blocks while a migration is running");

$bg->query_safe("COMMIT");
$bg->quit;

is( $node->safe_psql(
		'postgres', "SELECT lo_from_bytea(0, 'after commit') IS NOT NULL"),
	't',
	"the same write succeeds once the migration has committed");

# The migration itself must not have lost anything.
is( $node->safe_psql(
		'postgres', "SELECT count(*) FROM pg_catalog.pg_largeobject_metadata"
	),
	'1',
	"the migrated object is in native storage");

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
$n1->append_conf('postgresql.conf', qq{pg_lolor.node = 1});
$n2->append_conf('postgresql.conf', qq{pg_lolor.node = 2});
$n1->restart;
$n2->restart;

foreach my $n ($n1, $n2)
{
	$n->safe_psql('postgres', "CREATE EXTENSION pg_lolor");
	$n->safe_psql('postgres', "SELECT lolor.disable()");
}

# Give both nodes a native object under the same OID but with different
# contents, which is exactly the situation that silently diverges.
$n1->safe_psql('postgres',
	"SELECT lo_from_bytea(500001, 'node one content')");
$n2->safe_psql('postgres',
	"SELECT lo_from_bytea(500001, 'node two content')");

foreach my $n ($n1, $n2)
{
	$n->safe_psql('postgres', "SELECT lolor.enable()");
}

my $peer_oids = $n2->safe_psql('postgres',
	"SELECT coalesce(string_agg(o::text, ','), '') FROM lolor.native_lo_oids() AS o"
);
is($peer_oids, '500001', "native_lo_oids() reports the peer's OIDs");

($result, $stdout, $stderr) = $n1->psql('postgres',
	"SELECT lolor.migrate_from_native(peer_oids => ARRAY[$peer_oids]::oid[])"
);
isnt($result, 0, "migrate_from_native() refuses a colliding peer OID");
like(
	$stderr,
	qr/another node also holds natively/,
	"the refusal names the reason");

is( $n1->safe_psql(
		'postgres', "SELECT count(*) FROM pg_catalog.pg_largeobject_metadata"
	),
	'1',
	"the refusal left node one's native objects in place");

# Without the peer list the collision is invisible, which is why the argument
# exists; the migration itself still succeeds locally.
is($n1->safe_psql('postgres', "SELECT lolor.migrate_from_native()"),
	'1', "migration proceeds when no peer OIDs are supplied");

$n1->stop;
$n2->stop;

done_testing();
