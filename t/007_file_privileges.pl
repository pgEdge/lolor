# Check that the server-side file access functions are not executable by
# ordinary users
#
# Copyright (c) 2022-2026, pgEdge, Inc.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Cwd qw(abs_path);

my $node = PostgreSQL::Test::Cluster->new('privileges');
my ($result, $stdout, $stderr);

$node->init;
$node->append_conf('postgresql.conf', qq{lolor.node = 1});
$node->start;
$node->safe_psql('postgres', "CREATE EXTENSION lolor");
$node->safe_psql('postgres', "CREATE ROLE lo_plain LOGIN");

# lo_import() and lo_export() read and write files as the server's operating
# system account.  Core revokes EXECUTE on them from PUBLIC; lolor's
# replacements must be restricted the same way, or any user could read or
# overwrite arbitrary files.

# The server resolves relative paths against its data directory, so these have
# to be absolute.
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

$node->stop;

done_testing();
