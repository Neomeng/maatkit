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
require "$trunk/mk-duplicate-key-checker/mk-duplicate-key-checker";

my $dp  = new DSNParser();
my $sb  = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $dbh = $sb->get_dbh_for('master');

if ( !$dbh ) {
   plan skip_all => 'Cannot connect to sandbox master';
}
else {
   plan tests => 1;
}

my $output;
my $cnf = "/tmp/12345/my.sandbox.cnf";
my $cmd = "$trunk/mk-duplicate-key-checker/mk-duplicate-key-checker -F $cnf -h 127.1";

$sb->wipe_clean($dbh);
$sb->create_dbs($dbh, ['test']);

# #############################################################################
# Issue 331: mk-duplicate-key-checker crashes getting size of foreign keys
# #############################################################################

$sb->load_file('master', 'mk-duplicate-key-checker/t/samples/issue_331.sql', 'test');
ok(
   no_diff("$cmd -d issue_331", 'mk-duplicate-key-checker/t/samples/issue_331.txt'),
   'Issue 331 crash on fks'
);

# #############################################################################
# Done.
# #############################################################################
$sb->wipe_clean($dbh);
exit;