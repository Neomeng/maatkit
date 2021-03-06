#!/usr/bin/env perl

BEGIN {
   die "The MAATKIT_WORKING_COPY environment variable is not set.  See http://code.google.com/p/maatkit/wiki/Testing"
      unless $ENV{MAATKIT_WORKING_COPY} && -d $ENV{MAATKIT_WORKING_COPY};
   unshift @INC, "$ENV{MAATKIT_WORKING_COPY}/common";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More;

use MaatkitTest;
use Sandbox;
require "$trunk/mk-slave-find/mk-slave-find";

my $dp = new DSNParser(opts=>$dsn_opts);
my $sb = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $master_dbh = $sb->get_dbh_for('master');
my $slave_dbh  = $sb->get_dbh_for('slave1');

# Create slave2 as slave of slave1.
diag(`/tmp/12347/stop >/dev/null 2>&1`);
diag(`rm -rf /tmp/12347 >/dev/null 2>&1`);
diag(`$trunk/sandbox/mk-test-env reset`);
diag(`$trunk/sandbox/start-sandbox slave 12347 12346 >/dev/null`);
my $slave_2_dbh = $sb->get_dbh_for('slave2');

if ( !$master_dbh ) {
   plan skip_all => 'Cannot connect to sandbox master';
}
elsif ( !$slave_dbh ) {
   plan skip_all => 'Cannot connect to sandbox slave';
}
elsif ( !$slave_2_dbh ) {
   plan skip_all => 'Cannot connect to second sandbox slave';
}
else {
   plan tests => 5;
}

my @args = ('h=127.0.0.1,P=12345,u=msandbox,p=msandbox');

my $output = `$trunk/mk-slave-find/mk-slave-find --help`;
like($output, qr/Prompt for a password/, 'It compiles');

# Double check that we're setup correctly.
my $row = $slave_2_dbh->selectall_arrayref('SHOW SLAVE STATUS', {Slice => {}});
is(
   $row->[0]->{master_port},
   '12346',
   'slave2 is slave of slave1'
);

$output = `$trunk/mk-slave-find/mk-slave-find -h 127.0.0.1 -P 12345 -u msandbox -p msandbox --report-format hostname`;
my $expected = <<EOF;
127.0.0.1:12345
+- 127.0.0.1:12346
   +- 127.0.0.1:12347
EOF
is($output, $expected, 'Master with slave and slave of slave');

# #############################################################################
# Until MasterSlave::find_slave_hosts() is improved to overcome the problems
# with SHOW SLAVE HOSTS, this test won't work.
# #############################################################################
# Make slave2 slave of master.
#diag(`../../mk-slave-move/mk-slave-move --sibling-of-master h=127.1,P=12347`);
#$output = `perl ../mk-slave-find -h 127.0.0.1 -P 12345 -u msandbox -p msandbox`;
#$expected = <<EOF;
#127.0.0.1:12345
#+- 127.0.0.1:12346
#+- 127.0.0.1:12347
#EOF
#is($output, $expected, 'Master with two slaves');

# #########################################################################
# Issue 391: Add --pid option to all scripts
# #########################################################################
`touch /tmp/mk-script.pid`;
$output = `$trunk/mk-slave-find/mk-slave-find -h 127.0.0.1 -P 12345 -u msandbox -p msandbox --pid /tmp/mk-script.pid 2>&1`;
like(
   $output,
   qr{PID file /tmp/mk-script.pid already exists},
   'Dies if PID file already exists (issue 391)'
);
`rm -rf /tmp/mk-script.pid`;


# #############################################################################
# Summary report format.
# #############################################################################
my $outfile = "/tmp/mk-slave-find-output.txt";
diag(`rm -rf $outfile >/dev/null`);

$output = output(
   sub { mk_slave_find::main(@args) },
   file => $outfile,
);
diag(`sed -i -e 's/Version.*/Version/g' $outfile`);
diag(`sed -i -e 's/Uptime.*/Uptime/g' $outfile`);
diag(`sed -i -e 's/[0-9]* seconds/0 seconds/g' $outfile`);

is(
   ($sandbox_version ge '5.1'
      ? `diff $outfile $trunk/mk-slave-find/t/samples/summary001.txt`
      : `diff $outfile $trunk/mk-slave-find/t/samples/summary001-5.0.txt`),
   "",
   "Summary report format"
);

# #############################################################################
# Done.
# #############################################################################
#diag(`rm -rf $outfile >/dev/null`);
diag(`/tmp/12347/stop >/dev/null`);
diag(`rm -rf /tmp/12347 >/dev/null`);
exit;
