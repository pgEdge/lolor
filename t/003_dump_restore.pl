# Check dump and restore of lolor large objects
#
# Copyright (c) 2022-2025, pgEdge, Inc.
# Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $src = PostgreSQL::Test::Cluster->new('src_node');
my $dst = PostgreSQL::Test::Cluster->new('dst_node');
my ($result, $stdout, $stderr);

# Setup source node with lolor extension
$src->init;
$src->append_conf('postgresql.conf', qq{lolor.node = 1});
$src->start;
$src->safe_psql('postgres', "CREATE EXTENSION lolor");

# Create lolor large objects with known content
$src->safe_psql('postgres',
				qq(SELECT lo_from_bytea(1, 'lolor LO object - 1')));
$src->safe_psql('postgres',
				qq(SELECT lo_from_bytea(2, 'lolor LO object - 2')));

# Verify content on source before dump
$result = $src->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'lolor LO object - 1', "Verify first LO content on source");

$result = $src->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(2, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'lolor LO object - 2', "Verify second LO content on source");

# Dump the source database
my $dump_file = $src->data_dir . '/dump.sql';
command_ok(
	['pg_dump', '-f', $dump_file, '-d', $src->connstr('postgres')],
	'pg_dump succeeds on source with lolor objects');

$src->stop;

# Setup destination node and restore
$dst->init;
$dst->append_conf('postgresql.conf', qq{lolor.node = 1});
$dst->start;

command_ok(
	['psql', '-X', '-f', $dump_file, '-d', $dst->connstr('postgres')],
	'restore dump on destination node succeeds');

# Verify lolor objects survived dump/restore
$result = $dst->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(1, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'lolor LO object - 1',
	"First lolor LO preserved after dump/restore");

$result = $dst->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(2, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'lolor LO object - 2',
	"Second lolor LO preserved after dump/restore");

# Verify new lolor objects can be created on destination
$dst->safe_psql('postgres',
				qq(SELECT lo_from_bytea(3, 'new object on dst')));
$result = $dst->safe_psql('postgres', qq(
	BEGIN;
	SELECT lo_open(3, 262144) AS fd \\gset
	SELECT convert_from(loread(:fd, 1024), 'UTF8');
	END;
));
is($result, 'new object on dst',
	"Can create and read new lolor objects after restore");

$dst->stop;

done_testing();