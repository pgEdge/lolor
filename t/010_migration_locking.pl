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

# A migration refuses while another session is connected: the row movement
# cannot be made atomic for backends that already resolved the large object
# functions.
my $other = $node->background_psql('postgres');
$other->query_safe("SELECT 1");
($result, $stdout, $stderr) =
  $node->psql('postgres', "SELECT lolor.migrate_to_native()");
isnt($result, 0,
	"migrate_to_native() refuses while another session is connected");
like(
	$stderr,
	qr/while other sessions are connected to the database/,
	"the refusal says why");
$other->quit;

# Once alone it proceeds, and for the window between that check and commit it
# holds ShareRowExclusiveLock on both stores, which excludes ordinary large
# object access (RowExclusiveLock) that could otherwise slip in.
is( $node->safe_psql(
		'postgres', qq(
		SET client_min_messages = warning;
		BEGIN;
		SELECT lolor.migrate_to_native();
		SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
		WHERE c.relname IN ('pg_largeobject', 'pg_largeobject_metadata')
		  AND l.mode = 'ShareRowExclusiveLock' AND l.pid = pg_backend_pid();
		COMMIT;)),
	"1\n4",
	"the migration runs and holds ShareRowExclusiveLock on both stores until commit"
);

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
	qr/also held natively by another node/,
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
