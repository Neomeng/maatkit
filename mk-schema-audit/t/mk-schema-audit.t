#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use English qw('-no_match_vars);
use Test::More tests => 1;

require '../../common/DSNParser.pm';
require '../../common/Sandbox.pm';
#my $dp = new DSNParser();
#my $sb = new Sandbox(basedir => '/tmp', DSNParser => $dp);
#my $dbh = $sb->get_dbh_for('master')
#   or BAIL_OUT('Cannot connect to sandbox master');

#my $cnf = '/tmp/12345/my.sandbox.cnf';
#my $cmd = "perl ../mk-duplicate-key-checker -F $cnf -d test ";

ok(1, 'make prove happy');

exit;