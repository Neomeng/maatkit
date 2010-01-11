#!/usr/bin/env perl

BEGIN {
   die "The MAATKIT_TRUNK environment variable is not set.  See http://code.google.com/p/maatkit/wiki/Testing"
      unless $ENV{MAATKIT_TRUNK} && -d $ENV{MAATKIT_TRUNK};
   unshift @INC, "$ENV{MAATKIT_TRUNK}/common";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More;

use MaatkitTest;
use Sandbox;
require "$trunk/mk-table-checksum/mk-table-checksum";

my $dp = new DSNParser();
my $sb = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $master_dbh = $sb->get_dbh_for('master');
my $slave_dbh  = $sb->get_dbh_for('slave1');

if ( !$master_dbh ) {
   plan skip_all => 'Cannot connect to sandbox master';
}
elsif ( !$slave_dbh ) {
   plan skip_all => 'Cannot connect to sandbox slave';
}

my $cnf='/tmp/12345/my.sandbox.cnf';
my ($output, $output2);
my $cmd = "$trunk/mk-table-checksum/mk-table-checksum -F $cnf -d test -t checksum_test 127.0.0.1";

$sb->create_dbs($master_dbh, [qw(test)]);
$sb->load_file('master', 'mk-table-checksum/t/samples/before.sql');

eval { $master_dbh->do('DROP FUNCTION test.fnv_64'); };
eval { $master_dbh->do("CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'fnv_udf.so';"); };
if ( $EVAL_ERROR ) {
   chomp $EVAL_ERROR;
   plan skip_all => "Failed to created FNV_64 UDF: $EVAL_ERROR";
}
else {
   plan tests => 5;
}

$output = `/tmp/12345/use -N -e 'select fnv_64(1)' 2>&1`;
is($output + 0, -6320923009900088257, 'FNV_64(1)');

$output = `/tmp/12345/use -N -e 'select fnv_64("hello, world")' 2>&1`;
is($output + 0, 6062351191941526764, 'FNV_64(hello, world)');

$output = `$cmd --function FNV_64 --checksum --algorithm ACCUM 2>&1`;
like($output, qr/DD2CD41DB91F2EAE/, 'FNV_64 ACCUM' );

$output = `$cmd --function CRC32 --checksum --algorithm BIT_XOR 2>&1`;
like($output, qr/83dcefb7/, 'CRC32 BIT_XOR' );

$output = `$cmd --function FNV_64 --checksum --algorithm BIT_XOR 2>&1`;
like($output, qr/a84792031e4ff43f/, 'FNV_64 BIT_XOR' );

# #############################################################################
# Done.
# #############################################################################
$sb->wipe_clean($master_dbh);
$sb->wipe_clean($slave_dbh);
exit;
