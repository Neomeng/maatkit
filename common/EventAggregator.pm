# This program is copyright 2008-2009 Percona Inc.
# Feedback and improvements are welcome.
#
# THIS PROGRAM IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
# MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, version 2; OR the Perl Artistic License.  On UNIX and similar
# systems, you can issue `man perlgpl' or `man perlartistic' to read these
# licenses.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 59 Temple
# Place, Suite 330, Boston, MA  02111-1307  USA.
# ###########################################################################
# EventAggregator package $Revision$
# ###########################################################################
package EventAggregator;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);

# ###########################################################################
# Set up some constants for bucketing values.  It is impossible to keep all
# values seen in memory, but putting them into logarithmically scaled buckets
# and just incrementing the bucket each time works, although it is imprecise.
# See http://code.google.com/p/maatkit/wiki/EventAggregatorInternals.
# ###########################################################################
use constant MKDEBUG      => $ENV{MKDEBUG};
use constant BUCK_SIZE    => 1.05;
use constant BASE_LOG     => log(BUCK_SIZE);
use constant BASE_OFFSET  => abs(1 - log(0.000001) / BASE_LOG); # 284.1617969
use constant NUM_BUCK     => 1000;
use constant MIN_BUCK     => .000001;

# Used to pre-initialize {all} arrayrefs for event attribs in make_handler.
our @buckets  = map { 0 } (0..NUM_BUCK-1);

# Used in buckets_of() to map buckets of log10 to log1.05 buckets.
my @buck_vals = map { bucket_value($_); } (0..NUM_BUCK-1);

# The best way to see how to use this is to look at the .t file.
#
# %args is a hash containing:
# groupby      The name of the property to group/aggregate by.
# attributes   A hashref.  Each key is the name of an element to aggregate.
#              And the values of those elements are arrayrefs of the
#              values to pull from the hashref, with any second or subsequent
#              values being fallbacks for the first in case it's not defined.
# worst        The name of an element which defines the "worst" hashref in its
#              class.  If this is Query_time, then each class will contain
#              a sample that holds the event with the largest Query_time.
# unroll_limit If this many events have been processed and some handlers haven't
#              been generated yet (due to lack of sample data) unroll the loop
#              anyway.  Defaults to 50.
# attrib_limit Sanity limit for attribute values.  If the value exceeds the
#              limit, use the last-seen for this class; if none, then 0.
sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(groupby worst attributes) ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   return bless {
      groupby      => $args{groupby},
      attributes   => {
         map  { $_ => $args{attributes}->{$_} }
         grep { $_ ne $args{groupby} }
         keys %{$args{attributes}}
      },
      worst        => $args{worst},
      unroll_limit => $args{unroll_limit} || 50,
      attrib_limit => $args{attrib_limit},
   }, $class;
}

# Aggregate an event hashref's properties.  Code is built on the fly to do this,
# based on the values being passed in.  After code is built for every attribute
# (or 50 events are seen and we decide to give up) the little bits of code get
# unrolled into a whole subroutine to handle events.  For that reason, you can't
# re-use an instance.
sub aggregate {
   my ( $self, $event ) = @_;

   my $group_by = $event->{$self->{groupby}};
   return unless defined $group_by;

   # There might be a specially built sub that handles the work.
   if ( exists $self->{unrolled_loops} ) {
      return $self->{unrolled_loops}->($self, $event, $group_by);
   }

   my @attrs = sort keys %{$self->{attributes}};
   ATTRIB:
   foreach my $attrib ( @attrs ) {
      # The value of the attribute ( $group_by ) may be an arrayref.
      GROUPBY:
      foreach my $val ( ref $group_by ? @$group_by : ($group_by) ) {
         my $class_attrib  = $self->{result_class}->{$val}->{$attrib} ||= {};
         my $global_attrib = $self->{result_globals}->{$attrib} ||= {};
         my $handler = $self->{handlers}->{ $attrib };
         if ( !$handler ) {
            $handler = $self->make_handler(
               $attrib,
               $event,
               wor => $self->{worst} eq $attrib,
               alt => $self->{attributes}->{$attrib},
            );
            $self->{handlers}->{$attrib} = $handler;
         }
         next GROUPBY unless $handler;
         $handler->($event, $class_attrib, $global_attrib);
      }
   }

   # Figure out whether we are ready to generate a faster version.
   if ( $self->{n_queries}++ > 50 # Give up waiting after 50 events.
      || !grep {ref $self->{handlers}->{$_} ne 'CODE'} @attrs
   ) {
      # All attributes have handlers, so let's combine them into one faster sub.
      # Start by getting direct handles to the location of each data store and
      # thing that would otherwise be looked up via hash keys.
      my @attrs = grep { $self->{handlers}->{$_} } @attrs;
      my $globs = $self->{result_globals}; # Global stats for each

      # Now the tricky part -- must make sure only the desired variables from
      # the outer scope are re-used, and any variables that should have their
      # own scope are declared within the subroutine.
      my @lines = (
         'my ( $self, $event, $group_by ) = @_;',
         'my ($val, $class, $global, $idx);',
         (ref $group_by ? ('foreach my $group_by ( @$group_by ) {') : ()),
         # Create and get each attribute's storage
         'my $temp = $self->{result_class}->{ $group_by }
            ||= { map { $_ => { } } @attrs };',
      );
      foreach my $i ( 0 .. $#attrs ) {
         # Access through array indexes, it's faster than hash lookups
         push @lines, (
            '$class  = $temp->{"'  . $attrs[$i] . '"};',
            '$global = $globs->{"' . $attrs[$i] . '"};',
            $self->{unrolled_for}->{$attrs[$i]},
         );
      }
      if ( ref $group_by ) {
         push @lines, '}'; # Close the loop opened above
      }
      @lines = map { s/^/   /gm; $_ } @lines; # Indent for debugging
      unshift @lines, 'sub {';
      push @lines, '}';

      # Make the subroutine
      my $code = join("\n", @lines);
      MKDEBUG && _d('Unrolled subroutine:', @lines);
      my $sub = eval $code;
      die if $EVAL_ERROR;
      $self->{unrolled_loops} = $sub;
   }
}

# Return the aggregated results.
sub results {
   my ( $self ) = @_;
   return {
      classes => $self->{result_class},
      globals => $self->{result_globals},
   };
}

# Return the attributes that this object is tracking, and their data types, as
# a hashref of name => type.
sub attributes {
   my ( $self ) = @_;
   return $self->{type_for};
}

# Make subroutines that do things with events.
#
# $attrib: the name of the attrib (Query_time, Rows_read, etc)
# $event:  a sample event
# %args:
#     min => keep min for this attrib (default except strings)
#     max => keep max (default except strings)
#     sum => keep sum (default for numerics)
#     cnt => keep count (default except strings)
#     unq => keep all unique values per-class (default for strings and bools)
#     all => keep a bucketed list of values seen per class (default for numerics)
#     glo => keep stats globally as well as per-class (default)
#     trf => An expression to transform the value before working with it
#     wor => Whether to keep worst-samples for this attrib (default no)
#     alt => Arrayref of other name(s) for the attribute, like db => Schema.
#
# The bucketed list works this way: each range of values from MIN_BUCK in
# increments of BUCK_SIZE (that is 5%) we consider a bucket.  We keep NUM_BUCK
# buckets.  The upper end of the range is more than 1.5e15 so it should be big
# enough for almost anything.  The buckets are accessed by a log base BUCK_SIZE,
# so floor(log(N)/log(BUCK_SIZE)).  The smallest bucket's index is -284. We
# shift all values up 284 so we have values from 0 to 999 that can be used as
# array indexes.  A value that falls into a bucket simply increments the array
# entry.  We do NOT use POSIX::floor() because it is too expensive.
#
# This eliminates the need to keep and sort all values to calculate median,
# standard deviation, 95th percentile etc.  Thus the memory usage is bounded by
# the number of distinct aggregated values, not the number of events.
#
# Return value:
# a subroutine with this signature:
#    my ( $event, $class, $global ) = @_;
# where
#  $event   is the event
#  $class   is the container to store the aggregated values
#  $global  is is the container to store the globally aggregated values
sub make_handler {
   my ( $self, $attrib, $event, %args ) = @_;
   die "I need an attrib" unless defined $attrib;
   my ($val) = grep { defined $_ } map { $event->{$_} } @{ $args{alt} };
   my $is_array = 0;
   if (ref $val eq 'ARRAY') {
      $is_array = 1;
      $val      = $val->[0];
   }
   return unless defined $val; # Can't decide type if it's undef.

   # Ripped off from Regexp::Common::number and modified.
   my $float_re = qr{[+-]?(?:(?=\d|[.])\d+(?:[.])\d{0,})(?:E[+-]?\d+)?}i;
   my $type = $val  =~ m/^(?:\d+|$float_re)$/o ? 'num'
            : $val  =~ m/^(?:Yes|No)$/         ? 'bool'
            :                                    'string';
   MKDEBUG && _d('Type for', $attrib, 'is', $type,
      '(sample:', $val, '), is array:', $is_array);
   $self->{type_for}->{$attrib} = $type;

   %args = ( # Set up defaults
      min => 1,
      max => 1,
      sum => $type =~ m/num|bool/    ? 1 : 0,
      cnt => 1,
      unq => $type =~ m/bool|string/ ? 1 : 0,
      all => $type eq 'num'          ? 1 : 0,
      glo => 1,
      trf => ($type eq 'bool') ? q{($val || '' eq 'Yes') ? 1 : 0} : undef,
      wor => 0,
      alt => [],
      %args,
   );

   my @lines = ("# type: $type"); # Lines of code for the subroutine
   if ( $args{trf} ) {
      push @lines, q{$val = } . $args{trf} . ';';
   }

   foreach my $place ( qw($class $global) ) {
      my @tmp;
      if ( $args{min} ) {
         my $op   = $type eq 'num' ? '<' : 'lt';
         push @tmp, (
            'PLACE->{min} = $val if !defined PLACE->{min} || $val '
               . $op . ' PLACE->{min};',
         );
      }
      if ( $args{max} ) {
         my $op = ($type eq 'num') ? '>' : 'gt';
         push @tmp, (
            'PLACE->{max} = $val if !defined PLACE->{max} || $val '
               . $op . ' PLACE->{max};',
         );
      }
      if ( $args{sum} ) {
         push @tmp, 'PLACE->{sum} += $val;';
      }
      if ( $args{cnt} ) {
         push @tmp, '++PLACE->{cnt};';
      }
      if ( $args{all} ) {
         push @tmp, (
            'exists PLACE->{all} or PLACE->{all} = [ @buckets ];',
            '++PLACE->{all}->[ EventAggregator::bucket_idx($val) ];',
         );
      }
      push @lines, map { s/PLACE/$place/g; $_ } @tmp;
   }

   # We only save unique/worst values for the class, not globally.
   if ( $args{unq} ) {
      push @lines, '++$class->{unq}->{$val};';
   }
   if ( $args{wor} ) {
      my $op = $type eq 'num' ? '>=' : 'ge';
      push @lines, (
         'if ( $val ' . $op . ' ($class->{max} || 0) ) {',
         '   $class->{sample} = $event;',
         '}',
      );
   }

   # Make sure the value is constrained to legal limits.  If it's out of bounds,
   # just use the last-seen value for it.
   my @limit;
   if ( $args{all} && $type eq 'num' && $self->{attrib_limit} ) {
      push @limit, (
         "if ( \$val > $self->{attrib_limit} ) {",
         '   $val = $class->{last} ||= 0;',
         '}',
         '$class->{last} = $val;',
      );
   }

   # Save the code for later, as part of an "unrolled" subroutine.
   my @unrolled = (
      "\$val = \$event->{'$attrib'};",
      ($is_array ? ('foreach my $val ( @$val ) {') : ()),
      (map { "\$val = \$event->{'$_'} unless defined \$val;" }
         grep { $_ ne $attrib } @{$args{alt}}),
      'defined $val && do {',
      ( map { s/^/   /gm; $_ } (@limit, @lines) ), # Indent for debugging
      '};',
      ($is_array ? ('}') : ()),
   );
   $self->{unrolled_for}->{$attrib} = join("\n", @unrolled);

   # Build a subroutine with the code.
   unshift @lines, (
      'sub {',
      'my ( $event, $class, $global ) = @_;',
      'my ($val, $idx);', # NOTE: define all variables here
      "\$val = \$event->{'$attrib'};",
      (map { "\$val = \$event->{'$_'} unless defined \$val;" }
         grep { $_ ne $attrib } @{$args{alt}}),
      'return unless defined $val;',
      ($is_array ? ('foreach my $val ( @$val ) {') : ()),
      @limit,
      ($is_array ? ('}') : ()),
   );
   push @lines, '}';
   my $code = join("\n", @lines);
   $self->{code_for}->{$attrib} = $code;

   MKDEBUG && _d('Metric handler for', $attrib, ':', @lines);
   my $sub = eval join("\n", @lines);
   die if $EVAL_ERROR;
   return $sub;
}

# Returns the bucket number for the given val. Buck numbers are zero-indexed,
# so although there are 1,000 buckets (NUM_BUCK), 999 is the greatest idx.
# *** Notice that this sub is not a class method, so either call it
# from inside this module like bucket_idx() or outside this module
# like EventAggregator::bucket_idx(). ***
# TODO: could export this by default to avoid having to specific packge::.
sub bucket_idx {
   my ( $val ) = @_;
   return 0 if $val < MIN_BUCK;
   my $idx = int(BASE_OFFSET + log($val)/BASE_LOG);
   return $idx > (NUM_BUCK-1) ? (NUM_BUCK-1) : $idx;
}

# Returns the value for the given bucket.
# The value of each bucket is the first value that it covers. So the value
# of bucket 1 is 0.000001000 because it covers [0.000001000, 0.000001050).
#
# *** Notice that this sub is not a class method, so either call it
# from inside this module like bucket_idx() or outside this module
# like EventAggregator::bucket_value(). ***
# TODO: could export this by default to avoid having to specific packge::.
sub bucket_value {
   my ( $bucket ) = @_;
   return 0 if $bucket == 0;
   die "Invalid bucket: $bucket" if $bucket < 0 || $bucket > (NUM_BUCK-1);
   # $bucket - 1 because buckets are shifted up by 1 to handle zero values.
   return (BUCK_SIZE**($bucket-1)) * MIN_BUCK;
}

# Map the 1,000 base 1.05 buckets to 8 base 10 buckets. Returns an array
# of 1,000 buckets, the value of each represents its index in an 8 bucket
# base 10 array. For example: base 10 bucket 0 represents vals (0, 0.000010),
# and base 1.05 buckets 0..47 represent vals (0, 0.000010401). So the first
# 48 elements of the returned array will have 0 as their values. 
# TODO: right now it's hardcoded to buckets of 10, in the future maybe not.
{
   my @buck_tens;
   sub buckets_of {
      return @buck_tens if @buck_tens;

      # To make a more precise map, we first set the starting values for
      # each of the 8 base 10 buckets. 
      my $start_bucket  = 0;
      my @base10_starts = (0);
      map { push @base10_starts, (10**$_)*MIN_BUCK } (1..7);

      # Then find the base 1.05 buckets that correspond to each
      # base 10 bucket. The last value in each bucket's range belongs
      # to the next bucket, so $next_bucket-1 represents the real last
      # base 1.05 bucket in which the base 10 bucket's range falls.
      for my $base10_bucket ( 0..($#base10_starts-1) ) {
         my $next_bucket = bucket_idx( $base10_starts[$base10_bucket+1] );
         MKDEBUG && _d('Base 10 bucket $base10_bucket maps to',
            'base 1.05 buckets', $start_bucket, '..', $next_bucket-1);
         for my $base1_05_bucket ($start_bucket..($next_bucket-1)) {
            $buck_tens[$base1_05_bucket] = $base10_bucket;
         }
         $start_bucket = $next_bucket;
      }

      # Map all remaining base 1.05 buckets to base 10 bucket 7 which
      # is for vals > 10.
      map { $buck_tens[$_] = 7 } ($start_bucket..(NUM_BUCK-1));

      return @buck_tens;
   }
}

# Given an arrayref of vals, returns a hashref with the following
# statistical metrics:
#
#    pct_95    => top bucket value in the 95th percentile
#    cutoff    => How many values fall into the 95th percentile
#    stddev    => of 95% values
#    median    => of 95% values
#
# The vals arrayref is the buckets as per the above (see the comments at the top
# of this file).  $args should contain cnt, min, max and sum properties.
sub calculate_statistical_metrics {
   my ( $self, $vals, $args ) = @_;
   my $statistical_metrics = {
      pct_95    => 0,
      stddev    => 0,
      median    => 0,
      cutoff    => undef,
   };

   # These cases might happen when there is nothing to get from the event, for
   # example, processlist sniffing doesn't gather Rows_examined, so $args won't
   # have {cnt} or other properties.
   return $statistical_metrics
      unless defined $vals && @$vals && $args->{cnt};

   # Return accurate metrics for some cases.
   my $n_vals = $args->{cnt};
   if ( $n_vals == 1 || $args->{max} == $args->{min} ) {
      my $v      = $args->{max} || 0;
      my $bucket = int(6 + ( log($v > 0 ? $v : MIN_BUCK) / log(10)));
      $bucket    = $bucket > 7 ? 7 : $bucket < 0 ? 0 : $bucket;
      return {
         pct_95 => $v,
         stddev => 0,
         median => $v,
         cutoff => $n_vals,
      };
   }
   elsif ( $n_vals == 2 ) {
      foreach my $v ( $args->{min}, $args->{max} ) {
         my $bucket = int(6 + ( log($v && $v > 0 ? $v : MIN_BUCK) / log(10)));
         $bucket = $bucket > 7 ? 7 : $bucket < 0 ? 0 : $bucket;
      }
      my $v      = $args->{max} || 0;
      my $mean = (($args->{min} || 0) + $v) / 2;
      return {
         pct_95 => $v,
         stddev => sqrt((($v - $mean) ** 2) *2),
         median => $mean,
         cutoff => $n_vals,
      };
   }

   # Determine cutoff point for 95% if there are at least 10 vals.  Cutoff
   # serves also for the number of vals left in the 95%.  E.g. with 50 vals the
   # cutoff is 47 which means there are 47 vals: 0..46.  $cutoff is NOT an array
   # index.
   my $cutoff = $n_vals >= 10 ? int ( $n_vals * 0.95 ) : $n_vals;
   $statistical_metrics->{cutoff} = $cutoff;

   # Exclude values above the 95th percentile.
   # For example, if there are 605 values, the 95th cutoff is 574. That
   # means if we ordered all 605 values, values 1 to 574 inclusive would
   # be the 95th percentile values. Since, however, $vals is an arrayref
   # of buckets not vaues, we cannot simply take slice 0..cutoff. Instead,
   # we must run the array backwards (counting down from NUM_BUCK) until we
   # have excluded the top 31 values (605-574). 
   my $total_left = $n_vals;
   my $top_vals   = $n_vals - $cutoff;
   my $bucket     = NUM_BUCK - 1; # 999
   my $sum_excl   = 0;

   MKDEBUG && _d('total vals:', $total_left, 'top vals:', $top_vals,
      'cutoff:', $cutoff);

   while ( $bucket-- >= 0 && $top_vals ) {
      if ( $vals->[$bucket] ) {
         if ( $vals->[$bucket] <= $top_vals )  {
            # Exclude all vals in this bucket.
            $top_vals   -= $vals->[$bucket];
            $total_left -= $vals->[$bucket];
            $sum_excl   += $vals->[$bucket] * $buck_vals[$bucket];
         }
         else {
            # Exclude only enough vals in this bucket to satisfy $top_vals,
            # then stop because we have excluded all the top vals.
            $total_left      -= $top_vals;
            # TODO: do we have to modify this? maybe restore it later?
            $vals->[$bucket] -= $top_vals;
            $sum_excl        += $top_vals * $buck_vals[$bucket];
            $top_vals         = 0;
         }
      }
   }

   MKDEBUG && _d('total left:', $total_left, 'bucket:', $bucket,
      'sum excl', $sum_excl);

   # If $bucket <= 0, then the loop above had to run all the way down
   # to bucket 0 to find enough values to exclude. In such a case, the
   # only values left are zero.
   return $statistical_metrics if $bucket <= 0;

   # Find the next bucket with values. It may be the current bucket if
   # only some of its values were excluded.
   if ( !$vals->[$bucket] ) {
      while ( --$bucket >= 0 ) {
         last if $vals->[$bucket];
      }
   }

   # At this point, $bucket points to the top bucket in the 95th percentile
   # that has values. If, however, it's bucket 0, then only zero values remain,
   # so we can return early. 
   return $statistical_metrics if $bucket <= 0;
   my $bucket_95 = $bucket; # save for later to determine pct_95
   MKDEBUG && _d('95th bucket:', $bucket_95, $buck_vals[$bucket_95]);

   # Calculate the standard deviation, median, and max value of the 95th
   # percentile of values.
   my $sum    = $buck_vals[$bucket] * $vals->[$bucket];
   my $sumsq  = $sum ** 2;
   my $mid    = int($cutoff / 2);
   my $median = 0;
   my $prev   = $bucket; # Used for getting median when $cutoff is odd

   # The vars above account for the current bucket's vals.
   $total_left -= $vals->[$bucket];

   # Continue through the remaining buckets.
   while ( --$bucket >= 0 ) {
      my $val = $vals->[$bucket];
      if ( $val ) {
         $total_left -= $val;
         if ( !$median && $total_left <= $mid ) {
            $median = (($cutoff % 2) || ($val > 1)) ? $buck_vals[$bucket]
                    : ($buck_vals[$bucket] + $buck_vals[$prev]) / 2;
         }
         $sum    += $buck_vals[$bucket] * $val;
         $sumsq  += ($buck_vals[$bucket]**2) * $val;
         $prev   =  $bucket;
      }
   }

   my $stddev   = sqrt (($sumsq - (($sum**2) / $cutoff)) / $cutoff);
   my $maxstdev = (($args->{max} || 0) - ($args->{min} || 0)) / 2;
   $stddev      = $stddev > $maxstdev ? $maxstdev : $stddev;

   MKDEBUG && _d('sum:', $sum, 'sumsq:', $sumsq, 'stddev:', $stddev,
      'mid:', $mid, 'median:', $median, 'prev bucket:', $prev,
      'total left:', $total_left);

   $statistical_metrics->{stddev} = $stddev;
   $statistical_metrics->{pct_95} = $buck_vals[$bucket_95];
   $statistical_metrics->{median} = $median;

   return $statistical_metrics;
}

# Find the top N or top % event keys, in sorted order, optionally including
# outliers (ol_...) that are notable for some reason.  %args looks like this:
#
#  attrib      order-by attribute (usually Query_time)
#  orderby     order-by aggregate expression (should be numeric, usually sum)
#  total       include events whose summed attribs are <= this number...
#  count       ...or this many events, whichever is less...
#  ol_attrib   ...or events where the 95th percentile of this attribute...
#  ol_limit    ...is greater than this value, AND...
#  ol_freq     ...the event occurred at least this many times.
# The return value is a list of arrayrefs.  Each arrayref is the event key and
# an explanation of why it was included (top|outlier).
sub top_events {
   my ( $self, %args ) = @_;
   my $classes = $self->{result_class};
   my @sorted = reverse sort { # Sorted list of $groupby values
      $classes->{$a}->{$args{attrib}}->{$args{orderby}}
         <=> $classes->{$b}->{$args{attrib}}->{$args{orderby}}
      } grep {
         # Defensive programming
         defined $classes->{$_}->{$args{attrib}}->{$args{orderby}}
      } keys %$classes;
   my @chosen;
   my ($total, $count) = (0, 0);
   foreach my $groupby ( @sorted ) {
      # Events that fall into the top criterion for some reason
      if ( 
         (!$args{total} || $total < $args{total} )
         && ( !$args{count} || $count < $args{count} )
      ) {
         push @chosen, [$groupby, 'top'];
      }

      # Events that are notable outliers
      elsif ( $args{ol_attrib} && (!$args{ol_freq}
         || $classes->{$groupby}->{$args{ol_attrib}}->{cnt} >= $args{ol_freq})
      ) {
         # Calculate the 95th percentile of this event's specified attribute.
         MKDEBUG && _d('Calculating statistical_metrics');
         my $stats = $self->calculate_statistical_metrics(
            $classes->{$groupby}->{$args{ol_attrib}}->{all},
            $classes->{$groupby}->{$args{ol_attrib}}
         );
         if ( $stats->{pct_95} >= $args{ol_limit} ) {
            push @chosen, [$groupby, 'outlier'];
         }
      }

      $total += $classes->{$groupby}->{$args{attrib}}->{$args{orderby}};
      $count++;
   }
   return @chosen;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;

# ###########################################################################
# End EventAggregator package
# ###########################################################################
