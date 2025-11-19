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
my ($result, $stdout, $stderr);

$node->init;

# ##############################################################################
#
# Lolor is loaded dynamically, on demand
#
# ##############################################################################

$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION lolor");

# Check
($result, $stdout, $stderr) = $node->psql('postgres', qq(
  SET lolor.node = 0;
  SELECT lo_creat(-1)
));
like($stderr, qr/value for lolor.node is not set/, "Zero value of lolor node is treated as an unset");

$result = $node->safe_psql('postgres', qq(
  SET lolor.node = 1;
  SELECT lo_creat(-1);
));
ok($result > 0, "Lolor works and produces LO IDs");

$node->safe_psql('postgres', "DROP EXTENSION lolor");
$result = $node->safe_psql('postgres', qq(
  SET lolor.node = 0;
  SELECT lo_creat(-1);
));
ok($result > 0, "Lolor has been removed and standard lo_creat routine is used");
$node->stop();

# ##############################################################################
#
# Tests when lolor is loaded statically
#
# ##############################################################################

$node->append_conf('postgresql.conf', qq{shared_preload_libraries = 'lolor'});
$node->start;

$result = $node->safe_psql('postgres', "CREATE EXTENSION lolor");

is($result, '', 'Basic check on create extension script');

$result = $node->safe_psql('postgres', "DROP EXTENSION lolor");

$node->stop();

done_testing();
