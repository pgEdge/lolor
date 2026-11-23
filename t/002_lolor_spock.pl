# Two-node test of large object replication with Spock.
#
# Every kind of large object change is made on one node and has to arrive,
# page for page, on the other; the large object functions have to work on the
# replicated data; and changes made on the second node have to flow back.
#
# Needs Spock (built for the same server) installed; skipped otherwise.
#
# Copyright (c) 2022-2026, pgEdge, Inc.

use strict;
use warnings FATAL => 'all';

use File::Compare;
use IPC::Run;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $sharedir = `pg_config --sharedir`;
chomp $sharedir;
plan skip_all => 'Spock is not installed'
  unless -f "$sharedir/extension/spock.control";

# A DSN that can be put in an SQL string literal.
sub dsn
{
	my ($n) = @_;
	return 'host=' . $n->host . ' port=' . $n->port . ' dbname=postgres';
}

my @nodes;
foreach my $i (1, 2)
{
	my $n = PostgreSQL::Test::Cluster->new("n$i");
	$n->init(allows_streaming => 'logical');
	$n->append_conf(
		'postgresql.conf', qq{
shared_preload_libraries = 'spock, lolor'
lolor.node = $i
track_commit_timestamp = on
max_worker_processes = 24
max_replication_slots = 12
max_wal_senders = 12
spock.conflict_resolution = last_update_wins
});
	$n->start;
	push @nodes, $n;
}
my ($n1, $n2) = @nodes;

# What every test node needs: the extensions, a Spock node, and helpers.
foreach my $i (0, 1)
{
	my $n = $nodes[$i];
	$n->safe_psql(
		'postgres', q{
CREATE EXTENSION spock;
CREATE EXTENSION lolor;
CREATE TABLE t_docs (id int PRIMARY KEY, lo oid);

-- A fingerprint of all large objects, page for page.
CREATE FUNCTION t_fingerprint() RETURNS text AS $$
	SELECT count(*) || ':' || coalesce(md5(string_agg(m.oid::text || '=' ||
			coalesce((SELECT md5(string_agg(l.pageno || encode(l.data, 'hex'), ''
									   ORDER BY l.pageno))
					  FROM pg_largeobject l WHERE l.loid = m.oid), '-'),
			',' ORDER BY m.oid)), '')
	FROM pg_largeobject_metadata m
$$ LANGUAGE sql;

-- Everything the read functions say about one object.
CREATE FUNCTION t_readback(o oid) RETURNS text AS $$
DECLARE fd int; size bigint; tail bytea;
BEGIN
	fd := lo_open(o, 262144);
	size := lo_lseek64(fd, 0, 2);
	PERFORM lo_lseek64(fd, least(size, 777), 0);
	tail := loread(fd, 1500);
	PERFORM lo_close(fd);
	RETURN size || ':' || md5(lo_get(o)) || ':' || md5(lo_get(o, 100, 3000)) ||
		   ':' || md5(tail);
END $$ LANGUAGE plpgsql;

-- A transaction that exercises all kinds of change.  base+N are explicit
-- OIDs, the others are generated.
CREATE FUNCTION t_workload(base bigint) RETURNS void AS $$
DECLARE data bytea; o oid; fd int;
BEGIN
	SELECT convert_to(string_agg(md5(g::text), ''), 'UTF8') INTO data
	  FROM generate_series(1, 3125) g;							-- 100000 bytes
	PERFORM lo_create(base + 1);									-- empty
	PERFORM lo_from_bytea(base + 2, 'hello'::bytea);				-- small
	PERFORM lo_from_bytea(base + 3, data);							-- 49 pages
	PERFORM lo_put(base + 3, 2040, 'XXXXXXXXXXXXXXXXXXXX'::bytea);	-- page boundary
	PERFORM lo_create(base + 4);									-- sparse
	PERFORM lo_put(base + 4, 10000, 'x'::bytea);
	PERFORM lo_from_bytea(base + 5, data);							-- shrunk
	PERFORM lo_truncate(lo_open(base + 5, 131072), 3000);
	PERFORM lo_from_bytea(base + 6, 'short'::bytea);				-- extended
	PERFORM lo_truncate64(lo_open(base + 6, 131072), 9000);
	o := lo_create(base + 7);										-- many small writes
	fd := lo_open(o, 393216);
	FOR i IN 1 .. 50 LOOP
		PERFORM lowrite(fd, convert_to(repeat('w' || i, 100), 'UTF8'));
	END LOOP;
	PERFORM lo_close(fd);
	PERFORM lo_from_bytea(base + 8, data);							-- gone again
	PERFORM lo_unlink(base + 8);
	BEGIN															-- rolled back
		PERFORM lo_from_bytea(base + 9, 'never'::bytea);
		RAISE EXCEPTION 'undo';
	EXCEPTION WHEN others THEN
		IF SQLERRM <> 'undo' THEN RAISE; END IF;
	END;
	FOR i IN 1 .. 20 LOOP											-- generated OIDs
		PERFORM lo_from_bytea(0, convert_to(repeat('gen' || i, 300 * i), 'UTF8'));
	END LOOP;
END $$ LANGUAGE plpgsql;
});
	$n->safe_psql('postgres',
		"SELECT spock.node_create('n" . ($i + 1) . "', '" . dsn($n) . "')");
}

# Wire the nodes up in both directions.
$n2->safe_psql('postgres',
	"SELECT spock.sub_create('sub_n1_n2', '" . dsn($n1)
	  . "', ARRAY['default'], false, false)");
$n1->safe_psql('postgres',
	"SELECT spock.sub_create('sub_n2_n1', '" . dsn($n2)
	  . "', ARRAY['default'], false, false)");

foreach my $n ($n1, $n2)
{
	$n->safe_psql(
		'postgres', q{
SELECT spock.repset_add_table('default', 'pg_catalog.pg_largeobject');
SELECT spock.repset_add_table('default', 'pg_catalog.pg_largeobject_metadata');
SELECT spock.repset_add_table('default', 'public.t_docs');
});
}

$n2->poll_query_until('postgres',
	q{SELECT bool_and(status = 'replicating') FROM spock.sub_show_status()})
  or die "subscription on n2 does not replicate";
$n1->poll_query_until('postgres',
	q{SELECT bool_and(status = 'replicating') FROM spock.sub_show_status()})
  or die "subscription on n1 does not replicate";
pass('both nodes replicate, with the large object catalogs in the replication set');

# Wait until the second node has what the first one has.
sub converged
{
	my ($from, $to, $name) = @_;
	my $fp = $from->safe_psql('postgres', 'SELECT t_fingerprint()');
	my $ok = $to->poll_query_until('postgres',
		"SELECT t_fingerprint() = '$fp'");
	ok($ok, $name)
	  or diag("expected $fp, got "
		  . $to->safe_psql('postgres', 'SELECT t_fingerprint()'));
	return $fp;
}

# ---------------------------------------------------------------------------
# n1 -> n2
# ---------------------------------------------------------------------------

$n1->safe_psql('postgres', 'SELECT t_workload(8100000)');
my $fp = converged($n1, $n2, 'n2 has the large objects the workload made on n1');

is( $n2->safe_psql('postgres',
		q{SELECT count(*) FROM pg_largeobject_metadata WHERE oid IN (8100008, 8100009)}),
	'0', 'unlinked and rolled back objects are absent on n2');
is( $n2->safe_psql('postgres',
		q{SELECT count(*) FROM pg_largeobject_metadata WHERE oid::bigint & 15 = 1 AND oid NOT BETWEEN 8000000 AND 8999999}),
	'20', 'the 20 generated OIDs of n1 arrived');

# Explicit test OIDs live in 8000000..8999999; the others were generated.
# The functions have to work on replicated data, as they do on the origin.
my @explicit = map { 8100000 + $_ } 1 .. 7;
my @generated = split /\n/, $n1->safe_psql('postgres',
	q{SELECT oid FROM pg_largeobject_metadata WHERE oid::bigint & 15 = 1 AND oid NOT BETWEEN 8000000 AND 8999999 ORDER BY oid});
foreach my $o (@explicit, @generated)
{
	my $sql = "SELECT t_readback($o)";
	my $want = $n1->safe_psql('postgres', $sql);
	my $got = $n2->safe_psql('postgres', $sql);
	if ($want ne $got)
	{
		fail("lo functions agree on both nodes for $o");
		diag("n1: $want\nn2: $got");
	}
}
pass('loread, lo_lseek64 and lo_get agree on both nodes for every object');

{
	my $dir = PostgreSQL::Test::Utils::tempdir;
	$n1->safe_psql('postgres', "SELECT lo_export(8100003, '$dir/from_n1')");
	$n2->safe_psql('postgres', "SELECT lo_export(8100003, '$dir/from_n2')");
	is(compare("$dir/from_n1", "$dir/from_n2"), 0,
		'lo_export on n2 writes the same file as on n1');

	# And n2 can use a replicated object in a transaction of its own.
	$n2->safe_psql(
		'postgres', q{
BEGIN;
SELECT lo_put(8100002, 0, 'HELLO');
COMMIT;});
	is( $n2->safe_psql('postgres', 'SELECT lo_get(8100002)'),
		'\x48454c4c4f', 'n2 can modify an object created on n1');
}

# ---------------------------------------------------------------------------
# n2 -> n1: its own objects, and edits of the ones it received
# ---------------------------------------------------------------------------

$n2->safe_psql('postgres', 'SELECT t_workload(8200000)');
$n2->safe_psql(
	'postgres', q{
SELECT lo_unlink(8100004);
SELECT lo_truncate(lo_open(8100003, 131072), 5000);
SELECT lo_put(8100007, 20, 'EDITED ON N2'::bytea);
});
$fp = converged($n2, $n1, 'n1 has what n2 did, including edits of objects from n1');
is( $n1->safe_psql('postgres',
		q{SELECT count(*) FROM pg_largeobject_metadata WHERE oid::bigint & 15 = 2 AND oid NOT BETWEEN 8000000 AND 8999999}),
	'20', 'the generated OIDs of n2 arrived on n1, and none collided');

# ---------------------------------------------------------------------------
# Changes in different shapes
# ---------------------------------------------------------------------------

# A large object and the row that refers to it, in one transaction.
$n1->safe_psql(
	'postgres', q{
BEGIN;
INSERT INTO t_docs SELECT 1, lo_from_bytea(0, 'document one');
INSERT INTO t_docs SELECT 2, lo_from_bytea(0, 'document two');
COMMIT;
});
$n2->poll_query_until('postgres',
	q{SELECT count(*) = 2 AND bool_and(lo_get(lo) IS NOT NULL) FROM t_docs})
  or fail('rows and their objects arrive together');
is( $n2->safe_psql('postgres',
		q{SELECT string_agg(convert_from(lo_get(lo), 'UTF8'), ',' ORDER BY id) FROM t_docs}),
	'document one,document two',
	'a row and the object it refers to are replicated in one transaction');

# One big transaction.
$n1->safe_psql('postgres',
	q{SELECT lo_from_bytea(8300001, convert_to(repeat('0123456789abcdef', 1250000), 'UTF8'))});
converged($n1, $n2, 'a 20 MB object arrives intact');
is( $n2->safe_psql('postgres', 'SELECT length(lo_get(8300001))'),
	'20000000', 'with its full length');

# Many small transactions on both nodes at the same time.
{
	# the two sessions overlap in time
	my $h1 = IPC::Run::start(
		[ 'psql', '-X', '-q', '-d', $n1->connstr('postgres'), '-c',
		  "DO \$\$ BEGIN FOR i IN 1 .. 150 LOOP PERFORM lo_from_bytea(8400000 + i, convert_to(repeat('x', i * 40), 'UTF8')); COMMIT; PERFORM lo_put(8400000 + i, 5, 'one'::bytea); COMMIT; IF i % 4 = 0 THEN PERFORM lo_unlink(8400000 + i); COMMIT; END IF; END LOOP; END \$\$;" ]);
	my $h2 = IPC::Run::start(
		[ 'psql', '-X', '-q', '-d', $n2->connstr('postgres'), '-c',
		  "DO \$\$ BEGIN FOR i IN 1 .. 150 LOOP PERFORM lo_from_bytea(8500000 + i, convert_to(repeat('y', i * 40), 'UTF8')); COMMIT; PERFORM lo_put(8500000 + i, 5, 'two'::bytea); COMMIT; IF i % 4 = 0 THEN PERFORM lo_unlink(8500000 + i); COMMIT; END IF; END LOOP; END \$\$;" ]);
	IPC::Run::finish($h1);
	IPC::Run::finish($h2);
	is($h1->result(0) + $h2->result(0), 0, 'the concurrent loads ran');
}
my $fp1 = $n1->safe_psql('postgres', 'SELECT t_fingerprint()');
$n2->poll_query_until('postgres', "SELECT t_fingerprint() = '$fp1'")
  or diag('n1: ' . $fp1 . ' n2: ' . $n2->safe_psql('postgres', 'SELECT t_fingerprint()'));
is( $n1->safe_psql('postgres', 'SELECT t_fingerprint()'),
	$n2->safe_psql('postgres', 'SELECT t_fingerprint()'),
	'both nodes end with the same large objects after concurrent loads');

# ---------------------------------------------------------------------------
# Nothing went wrong on the way
# ---------------------------------------------------------------------------

foreach my $n ($n1, $n2)
{
	is($n->safe_psql('postgres', 'SELECT count(*) FROM spock.exception_log'),
		'0', 'no replication exceptions on ' . $n->name);
	is($n->safe_psql('postgres',
		q{SELECT bool_and(status = 'replicating') FROM spock.sub_show_status()}),
		't', 'the subscription on ' . $n->name . ' is still replicating');
}

$_->stop foreach @nodes;
done_testing();
