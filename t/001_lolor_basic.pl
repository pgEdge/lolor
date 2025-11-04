# Trivial check on the lolor functionality
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

my $node = PostgreSQL::Test::Cluster->new('main');
my $result;

$node->init;
$node->append_conf('postgresql.conf', qq{shared_preload_libraries = 'lolor'});
$node->start;

$result = $node->safe_psql('postgres', "CREATE EXTENSION lolor");

is($result, '', 'Basic check on create extension script');

$result = $node->safe_psql('postgres', "DROP EXTENSION lolor");

$node->stop();

done_testing();
