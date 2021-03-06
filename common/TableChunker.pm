# This program is copyright 2007-2010 Baron Schwartz.
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
# TableChunker package $Revision$
# ###########################################################################

# Package: TableChunker
# TableChunker helps determine how to "chunk" a table.  Chunk are
# pre-determined ranges of rows defined by boundary values (sometimes also
# called endpoints) on numeric or numeric-like columns, including date/time
# types.  Any numeric column type that MySQL can do positional comparisons
# (<, <=, >, >=) on works.  Chunking on character data is not supported yet
# (but see <issue 568 at http://code.google.com/p/maatkit/issues/detail?id=568>).
# 
# Usually chunks range over all rows in a table but sometimes they only
# range over a subset of rows if an optional where arg is passed to various
# subs.  In either case a chunk is like "`col` >= 5 AND `col` < 10".  If
# col is of type int and is unique, then that chunk ranges over up to 5 rows.
#
# Chunks are included in WHERE clauses by various tools to do work on discrete
# chunks of the table instead of trying to work on the entire table at once.
# Chunks do not overlap and their size is configurable via the chunk_size arg
# passed to several subs.  The chunk_size can be a number of rows or a size
# like 1M, in which case it's in estimated bytes of data.  Real chunk sizes
# are usually close to the requested chunk_size but unless the optional exact
# arg is assed the real chunk sizes are approximate.  Sometimes the
# distribution of values on the chunk colun can skew chunking.  If, for
# example, col has values 0, 100, 101, ... then the zero value skews chunking.
# The zero_chunk arg handles this.
package TableChunker;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);

use POSIX qw(ceil);
use List::Util qw(min max);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use constant MKDEBUG => $ENV{MKDEBUG} || 0;

my $EPOCH      = '1970-01-01';
my %int_types  = map { $_ => 1 }
   qw(bigint date datetime int mediumint smallint time timestamp tinyint year);
my %real_types = map { $_ => 1 }
   qw(decimal double float);

# Sub: new
#
# Parameters:
#   $class - TableChunker (automatic)
#   %args  - Arguments
#
# Required Arguments:
#   Quoter    - <Quoter> object
#   MySQLDump - <MySQLDump> object
sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(Quoter MySQLDump) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $self = { %args };
   return bless $self, $class;
}

# Sub: find_chunk_columns
#   Find chunkable columns.
#
# Parameters:
#   %args - Arguments
#
# Required Arguments:
#   table_struct - Hashref returned from <TableParser::parse()>
#
# Optional Arguments:
#   exact - bool: Try to support exact chunk sizes (may still chunk fuzzily)
#
# Returns:
#   Array: whether the table can be chunked exactly if requested (zero
#   otherwise), arrayref of columns that support chunking.  Example:
#   (start code)
#   1,
#   [
#     { column => 'id', index => 'PRIMARY' },
#     { column => 'i',  index => 'i_idx'   },
#   ]
#   (end code)
sub find_chunk_columns {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(tbl_struct) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $tbl_struct = $args{tbl_struct};

   # See if there's an index that will support chunking.
   my @possible_indexes;
   foreach my $index ( values %{ $tbl_struct->{keys} } ) {

      # Accept only BTREE indexes.
      next unless $index->{type} eq 'BTREE';

      # Reject indexes with prefixed columns.
      defined $_ && next for @{ $index->{col_prefixes} };

      # If exact, accept only unique, single-column indexes.
      if ( $args{exact} ) {
         next unless $index->{is_unique} && @{$index->{cols}} == 1;
      }

      push @possible_indexes, $index;
   }
   MKDEBUG && _d('Possible chunk indexes in order:',
      join(', ', map { $_->{name} } @possible_indexes));

   # Build list of candidate chunk columns.   
   my $can_chunk_exact = 0;
   my @candidate_cols;
   foreach my $index ( @possible_indexes ) { 
      my $col = $index->{cols}->[0];

      # Accept only integer or real number type columns.
      next unless ( $int_types{$tbl_struct->{type_for}->{$col}}
                    || $real_types{$tbl_struct->{type_for}->{$col}} );

      # Save the candidate column and its index.
      push @candidate_cols, { column => $col, index => $index->{name} };
   }

   $can_chunk_exact = 1 if $args{exact} && scalar @candidate_cols;

   if ( MKDEBUG ) {
      my $chunk_type = $args{exact} ? 'Exact' : 'Inexact';
      _d($chunk_type, 'chunkable:',
         join(', ', map { "$_->{column} on $_->{index}" } @candidate_cols));
   }

   # Order the candidates by their original column order.
   # Put the PK's first column first, if it's a candidate.
   my @result;
   MKDEBUG && _d('Ordering columns by order in tbl, PK first');
   if ( $tbl_struct->{keys}->{PRIMARY} ) {
      my $pk_first_col = $tbl_struct->{keys}->{PRIMARY}->{cols}->[0];
      @result          = grep { $_->{column} eq $pk_first_col } @candidate_cols;
      @candidate_cols  = grep { $_->{column} ne $pk_first_col } @candidate_cols;
   }
   my $i = 0;
   my %col_pos = map { $_ => $i++ } @{$tbl_struct->{cols}};
   push @result, sort { $col_pos{$a->{column}} <=> $col_pos{$b->{column}} }
                    @candidate_cols;

   if ( MKDEBUG ) {
      _d('Chunkable columns:',
         join(', ', map { "$_->{column} on $_->{index}" } @result));
      _d('Can chunk exactly:', $can_chunk_exact);
   }

   return ($can_chunk_exact, @result);
}

# Sub: calculate_chunks
#   Calculate chunks for the given range statistics.  Args min, max and
#   rows_in_range are returned from get_range_statistics() which is usually
#   called before this sub.  Min and max are expected to be valid values
#   (NULL is valid).
#
# Parameters:
#   %args - Arguments
#
# Required Arguments:
#   dbh           - dbh
#   db            - database name
#   tbl           - table name
#   tbl_struct    - retval of <TableParser::parse()>
#   chunk_col     - column name to chunk on
#   min           - min col value, from <TableChunker::get_range_statistics()>
#   max           - max col value, from <TableChunker::get_range_statistics()>
#   rows_in_range - number of rows to chunk, from
#                   <TableChunker::get_range_statistics()>
#   chunk_size    - requested size of each chunk
#   zero_chunk    - add an extra chunk for zero values? (0, 00:00, etc.)
#
# Optional Arguments:
#   exact - Use exact chunk_size? Use approximates is not.
#   tries - Fetch up to this many rows to find a non-zero value
#
# Returns:
#   Array of WHERE predicates like "`col` >= '10' AND `col` < '20'",
#   one for each chunk.  All values are single-quoted due to <issue 1002 at
#   http://code.google.com/p/maatkit/issues/detail?id=1002>.  Example:
#   (start code)
#   `film_id` < '30',
#   `film_id` >= '30' AND `film_id` < '60',
#   `film_id` >= '60' AND `film_id` < '90',
#   `film_id` >= '90',
#   (end code)
sub calculate_chunks {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db tbl tbl_struct chunk_col rows_in_range chunk_size);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   MKDEBUG && _d('Calculate chunks for',
      join(", ", map {"$_=".(defined $args{$_} ? $args{$_} : "undef")}
         qw(db tbl chunk_col min max rows_in_range chunk_size zero_chunk exact)
      ));

   if ( !$args{rows_in_range} ) {
      MKDEBUG && _d("Empty table");
      return '1=1';
   }

   # http://code.google.com/p/maatkit/issues/detail?id=1084
   if ( $args{rows_in_range} < $args{chunk_size} ) {
      MKDEBUG && _d("Chunk size larger than rows in range");
      return '1=1';
   }

   my ($dbh, $db, $tbl) = @args{@required_args};
   my $q        = $self->{Quoter};
   my $db_tbl   = $q->quote($db, $tbl);
   my $col_type = $args{tbl_struct}->{type_for}->{$args{chunk_col}};
   MKDEBUG && _d('chunk col type:', $col_type);

   # Convert the given MySQL values to (Perl) numbers using some MySQL function.
   # E.g.: SELECT TIME_TO_SEC('12:34') == 45240.  
   my $range_func = $self->range_func_for($col_type);
   my ($start_point, $end_point);
   eval {
      $start_point = $self->value_to_number(
         value       => $args{min},
         column_type => $col_type,
         dbh         => $dbh,
      );
      $end_point  = $self->value_to_number(
         value       => $args{max},
         column_type => $col_type,
         dbh         => $dbh,
      );
   };
   if ( $EVAL_ERROR ) {
      if ( $EVAL_ERROR =~ m/don't know how to chunk/ ) {
         # Special kind of error doesn't make sense with the more verbose
         # description below.
         die $EVAL_ERROR;
      }
      else {
         die "Error calculating chunk start and end points for table "
            . "`$args{tbl_struct}->{name}` on column `$args{chunk_col}` "
            . "with min/max values "
            . join('/',
                  map { defined $args{$_} ? $args{$_} : 'undef' } qw(min max))
            . ":\n\n"
            . $EVAL_ERROR
            . "\nVerify that the min and max values are valid for the column.  "
            . "If they are valid, this error could be caused by a bug in the "
            . "tool.";
      }
   }

   # The end points might be NULL in the pathological case that the table
   # has nothing but NULL values.  If there's at least one non-NULL value
   # then MIN() and MAX() will return it.  Otherwise, the only thing to do
   # is make NULL end points zero to make the code below work and any NULL
   # values will be handled by the special "IS NULL" chunk.
   if ( !defined $start_point ) {
      MKDEBUG && _d('Start point is undefined');
      $start_point = 0;
   }
   if ( !defined $end_point || $end_point < $start_point ) {
      MKDEBUG && _d('End point is undefined or before start point');
      $end_point = 0;
   }
   MKDEBUG && _d("Actual chunk range:", $start_point, "to", $end_point);

   # Determine if we can include a zero chunk (col = 0).  If yes, then
   # make sure the start point is non-zero.  $start_point and $end_point
   # should be numbers (converted from MySQL values earlier).  The purpose
   # of the zero chunk is to capture a potentially large number of zero
   # values that might imbalance the size of the first chunk.  E.g. if a
   # lot of invalid times were inserted and stored as 00:00:00, these
   # zero (equivalent) values are captured by the zero chunk instead of
   # the first chunk + all the non-zero values in the first chunk.
   my $have_zero_chunk = 0;
   if ( $args{zero_chunk} ) {
      if ( $start_point != $end_point && $start_point >= 0 ) {
         MKDEBUG && _d('Zero chunking');
         my $nonzero_val = $self->get_nonzero_value(
            %args,
            db_tbl   => $db_tbl,
            col      => $args{chunk_col},
            col_type => $col_type,
            val      => $args{min}
         );
         # Since we called value_to_number() before with this column type
         # we shouldn't have to worry about it dying here--it would have
         # died earlier if we can't chunk the column type.
         $start_point = $self->value_to_number(
            value       => $nonzero_val,
            column_type => $col_type,
            dbh         => $dbh,
         );
         $have_zero_chunk = 1;
      }
      else {
         MKDEBUG && _d("Cannot zero chunk");
      }
   }
   MKDEBUG && _d("Using chunk range:", $start_point, "to", $end_point);

   # Calculate the chunk size in terms of "distance between endpoints"
   # that will give approximately the right number of rows between the
   # endpoints.  If possible and requested, forbid chunks from being any
   # bigger than specified.
   my $interval = $args{chunk_size}
                * ($end_point - $start_point)
                / $args{rows_in_range};
   if ( $int_types{$col_type} ) {
      $interval = ceil($interval);
   }
   $interval ||= $args{chunk_size};
   if ( $args{exact} ) {
      $interval = $args{chunk_size};
   }
   MKDEBUG && _d('Chunk interval:', $interval, 'units');

   # Generate a list of chunk boundaries.  The first and last chunks are
   # inclusive, and will catch any rows before or after the end of the
   # supposed range.  So 1-100 divided into chunks of 30 should actually end
   # up with chunks like this:
   #           < 30
   # >= 30 AND < 60
   # >= 60 AND < 90
   # >= 90
   # If zero_chunk was specified and zero chunking was possible, the first
   # chunk will be = 0 to catch any zero or zero-equivalent (e.g. 00:00:00)
   # rows.
   my @chunks;
   my $col = $q->quote($args{chunk_col});
   if ( $start_point < $end_point ) {

      # The zero chunk, if there is one.  It doesn't have to be the first
      # chunk.  The 0 cannot be quoted because if d='0000-00-00' then
      # d=0 will work but d='0' will cause warning 1292: Incorrect date
      # value: '0' for column 'd'.  This might have to column-specific in
      # future when we chunk on more exotic column types.
      push @chunks, "$col = 0" if $have_zero_chunk;

      my ( $beg, $end );
      my $iter = 0;
      for ( my $i = $start_point; $i < $end_point; $i += $interval ) {
         ( $beg, $end ) = $self->$range_func($dbh, $i, $interval, $end_point);

         # The first chunk.
         if ( $iter++ == 0 ) {
            push @chunks,
               ($have_zero_chunk ? "$col > 0 AND " : "")
               ."$col < " . $q->quote_val($end);
         }
         else {
            # The normal case is a chunk in the middle of the range somewhere.
            push @chunks, "$col >= " . $q->quote_val($beg) . " AND $col < " . $q->quote_val($end);
         }
      }

      # Remove the last chunk and replace it with one that matches everything
      # from the beginning of the last chunk to infinity.  If the chunk column
      # is nullable, do NULL separately.
      my $nullable = $args{tbl_struct}->{is_nullable}->{$args{chunk_col}};
      pop @chunks;
      if ( @chunks ) {
         push @chunks, "$col >= " . $q->quote_val($beg);
      }
      else {
         push @chunks, $nullable ? "$col IS NOT NULL" : '1=1';
      }
      if ( $nullable ) {
         push @chunks, "$col IS NULL";
      }
   }
   else {
      # There are no chunks; just do the whole table in one chunk.
      MKDEBUG && _d('No chunks; using single chunk 1=1');
      push @chunks, '1=1';
   }

   return @chunks;
}

# Arguments:
#   * tbl_struct  hashref: return val from TableParser::parse()
# Optional arguments:
#   * chunk_column  scalar: preferred chunkable column name
#   * chunk_index   scalar: preferred chunkable column index name
#   * exact         bool: passed to find_chunk_columns()
# Returns the first sane chunkable column and index.  "Sane" means that
# the first auto-detected chunk col/index are used if any combination of
# preferred chunk col or index would be really bad, like chunk col=x
# and chunk index=some index over (y, z).  That's bad because the index
# doesn't include the column; it would also be bad if the column wasn't
# a left-most prefix of the index.
sub get_first_chunkable_column {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(tbl_struct) ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   # First auto-detected chunk col/index.  If any combination of preferred 
   # chunk col or index are specified and are sane, they will overwrite
   # these defaults.  Else, these defaults will be returned.
   my ($exact, @cols) = $self->find_chunk_columns(%args);
   my $col = $cols[0]->{column};
   my $idx = $cols[0]->{index};

   # Wanted/preferred chunk column and index.  Caller only gets what
   # they want, though, if it results in a sane col/index pair.
   my $wanted_col = $args{chunk_column};
   my $wanted_idx = $args{chunk_index};
   MKDEBUG && _d("Preferred chunk col/idx:", $wanted_col, $wanted_idx);

   if ( $wanted_col && $wanted_idx ) {
      # Preferred column and index: check that the pair is sane.
      foreach my $chunkable_col ( @cols ) {
         if (    $wanted_col eq $chunkable_col->{column}
              && $wanted_idx eq $chunkable_col->{index} ) {
            # The wanted column is chunkable with the wanted index.
            $col = $wanted_col;
            $idx = $wanted_idx;
            last;
         }
      }
   }
   elsif ( $wanted_col ) {
      # Preferred column, no index: check if column is chunkable, if yes
      # then use its index, else fall back to default col/index.
      foreach my $chunkable_col ( @cols ) {
         if ( $wanted_col eq $chunkable_col->{column} ) {
            # The wanted column is chunkable, so use its index and overwrite
            # the defaults.
            $col = $wanted_col;
            $idx = $chunkable_col->{index};
            last;
         }
      }
   }
   elsif ( $wanted_idx ) {
      # Preferred index, no column: check if index's left-most column is
      # chunkable, if yes then use its column, else fall back to auto-detected
      # col/index.
      foreach my $chunkable_col ( @cols ) {
         if ( $wanted_idx eq $chunkable_col->{index} ) {
            # The wanted index has a chunkable column, so use it and overwrite
            # the defaults.
            $col = $chunkable_col->{column};
            $idx = $wanted_idx;
            last;
         }
      }
   }

   MKDEBUG && _d('First chunkable col/index:', $col, $idx);
   return $col, $idx;
}

# Convert a size in rows or bytes to a number of rows in the table, using SHOW
# TABLE STATUS.  If the size is a string with a suffix of M/G/k, interpret it as
# mebibytes, gibibytes, or kibibytes respectively.  If it's just a number, treat
# it as a number of rows and return right away.
# Returns an array: number of rows, average row size.
sub size_to_rows {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db tbl chunk_size);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db, $tbl, $chunk_size) = @args{@required_args};
   my $q  = $self->{Quoter};
   my $du = $self->{MySQLDump};

   my ($n_rows, $avg_row_length);

   my ( $num, $suffix ) = $chunk_size =~ m/^(\d+)([MGk])?$/;
   if ( $suffix ) { # Convert to bytes.
      $chunk_size = $suffix eq 'k' ? $num * 1_024
                  : $suffix eq 'M' ? $num * 1_024 * 1_024
                  :                  $num * 1_024 * 1_024 * 1_024;
   }
   elsif ( $num ) {
      $n_rows = $num;
   }
   else {
      die "Invalid chunk size $chunk_size; must be an integer "
         . "with optional suffix kMG";
   }

   if ( $suffix || $args{avg_row_length} ) {
      my ($status) = $du->get_table_status($dbh, $q, $db, $tbl);
      $avg_row_length = $status->{avg_row_length};
      if ( !defined $n_rows ) {
         $n_rows = $avg_row_length ? ceil($chunk_size / $avg_row_length) : undef;
      }
   }

   return $n_rows, $avg_row_length;
}

# Determine the range of values for the chunk_col column on this table.
# Arguments:
#   * dbh        dbh
#   * db         scalar: database name
#   * tbl        scalar: table name
#   * chunk_col  scalar: column name to chunk on
#   * tbl_struct hashref: retval of TableParser::parse()
# Optional arguments:
#   * where      scalar: WHERE clause without "WHERE" to restrict range
#   * index_hint scalar: "FORCE INDEX (...)" clause
#   * tries      scalar: fetch up to this many rows to find a valid value
# Returns an array:
#   * min row value
#   * max row values
#   * rows in range (given optional where)
sub get_range_statistics {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db tbl chunk_col tbl_struct);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db, $tbl, $col) = @args{@required_args};
   my $where = $args{where};
   my $q     = $self->{Quoter};

   my $col_type       = $args{tbl_struct}->{type_for}->{$col};
   my $col_is_numeric = $args{tbl_struct}->{is_numeric}->{$col};

   # Quote these once so we don't have to do it again. 
   my $db_tbl = $q->quote($db, $tbl);
   $col       = $q->quote($col);

   my ($min, $max);
   eval {
      # First get the actual end points, whatever MySQL considers the
      # min and max values to be for this column.
      my $sql = "SELECT MIN($col), MAX($col) FROM $db_tbl"
              . ($args{index_hint} ? " $args{index_hint}" : "")
              . ($where ? " WHERE ($where)" : '');
      MKDEBUG && _d($dbh, $sql);
      ($min, $max) = $dbh->selectrow_array($sql);
      MKDEBUG && _d("Actual end points:", $min, $max);

      # Now, for two reasons, get the valid end points.  For one, an
      # end point may be 0 or some zero-equivalent and the user doesn't
      # want that because it skews the range.  Or two, an end point may
      # be an invalid value like date 2010-00-00 and we can't use that.
      ($min, $max) = $self->get_valid_end_points(
         %args,
         dbh      => $dbh,
         db_tbl   => $db_tbl,
         col      => $col,
         col_type => $col_type,
         min      => $min,
         max      => $max,
      );
      MKDEBUG && _d("Valid end points:", $min, $max);
   };
   if ( $EVAL_ERROR ) {
      die "Error getting min and max values for table $db_tbl "
         . "on column $col: $EVAL_ERROR";
   }

   # Finally get the total number of rows in range, usually the whole
   # table unless there's a where arg restricting the range.
   my $sql = "EXPLAIN SELECT * FROM $db_tbl"
           . ($args{index_hint} ? " $args{index_hint}" : "")
           . ($where ? " WHERE $where" : '');
   MKDEBUG && _d($sql);
   my $expl = $dbh->selectrow_hashref($sql);

   return (
      min           => $min,
      max           => $max,
      rows_in_range => $expl->{rows},
   );
}

# Takes a query prototype and fills in placeholders.  The 'where' arg should be
# an arrayref of WHERE clauses that will be joined with AND.
sub inject_chunks {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(database table chunks chunk_num query) ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   MKDEBUG && _d('Injecting chunk', $args{chunk_num});
   my $query   = $args{query};
   my $comment = sprintf("/*%s.%s:%d/%d*/",
      $args{database}, $args{table},
      $args{chunk_num} + 1, scalar @{$args{chunks}});
   $query =~ s!/\*PROGRESS_COMMENT\*/!$comment!;
   my $where = "WHERE (" . $args{chunks}->[$args{chunk_num}] . ')';
   if ( $args{where} && grep { $_ } @{$args{where}} ) {
      $where .= " AND ("
         . join(" AND ", map { "($_)" } grep { $_ } @{$args{where}} )
         . ")";
   }
   my $db_tbl     = $self->{Quoter}->quote(@args{qw(database table)});
   my $index_hint = $args{index_hint} || '';

   MKDEBUG && _d('Parameters:',
      Dumper({WHERE => $where, DB_TBL => $db_tbl, INDEX_HINT => $index_hint}));
   $query =~ s!/\*WHERE\*/! $where!;
   $query =~ s!/\*DB_TBL\*/!$db_tbl!;
   $query =~ s!/\*INDEX_HINT\*/! $index_hint!;
   $query =~ s!/\*CHUNK_NUM\*/! $args{chunk_num} AS chunk_num,!;

   return $query;
}

# #############################################################################
# MySQL value to Perl number conversion.
# #############################################################################

# Convert a MySQL column value to a Perl integer.
# Arguments:
#   * value       scalar: MySQL value to convert
#   * column_type scalar: MySQL column type of the value
#   * dbh         dbh
# Returns an integer or undef if the value isn't convertible
# (e.g. date 0000-00-00 is not convertible).
sub value_to_number {
   my ( $self, %args ) = @_;
   my @required_args = qw(column_type dbh);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   my $val = $args{value};
   my ($col_type, $dbh) = @args{@required_args};
   MKDEBUG && _d('Converting MySQL', $col_type, $val);

   return unless defined $val;  # value is NULL

   # MySQL functions to convert a non-numeric value to a number
   # so we can do basic math on it in Perl.  Right now we just
   # convert temporal values but later we'll need to convert char
   # and hex values.
   my %mysql_conv_func_for = (
      timestamp => 'UNIX_TIMESTAMP',
      date      => 'TO_DAYS',
      time      => 'TIME_TO_SEC',
      datetime  => 'TO_DAYS',
   );

   # Convert the value to a number that Perl can do arithmetic with.
   my $num;
   if ( $col_type =~ m/(?:int|year|float|double|decimal)$/ ) {
      # These types are already numbers.
      $num = $val;
   }
   elsif ( $col_type =~ m/^(?:timestamp|date|time)$/ ) {
      # These are temporal values.  Convert them using a MySQL func.
      my $func = $mysql_conv_func_for{$col_type};
      my $sql = "SELECT $func(?)";
      MKDEBUG && _d($dbh, $sql, $val);
      my $sth = $dbh->prepare($sql);
      $sth->execute($val);
      ($num) = $sth->fetchrow_array();
   }
   elsif ( $col_type eq 'datetime' ) {
      # This type is temporal, too, but needs special handling.
      # Newer versions of MySQL could use TIMESTAMPDIFF, but it's easier
      # to maintain just one kind of code, so I do it all with DATE_ADD().
      $num = $self->timestampdiff($dbh, $val);
   }
   else {
      die "I don't know how to chunk $col_type\n";
   }
   MKDEBUG && _d('Converts to', $num);
   return $num;
}

sub range_func_for {
   my ( $self, $col_type ) = @_;
   return unless $col_type;
   my $range_func;
   if ( $col_type =~ m/(?:int|year|float|double|decimal)$/ ) {
      $range_func  = 'range_num';
   }
   elsif ( $col_type =~ m/^(?:timestamp|date|time)$/ ) {
      $range_func  = "range_$col_type";
   }
   elsif ( $col_type eq 'datetime' ) {
      $range_func  = 'range_datetime';
   }
   return $range_func;
}

# ###########################################################################
# Range functions.
# ###########################################################################
sub range_num {
   my ( $self, $dbh, $start, $interval, $max ) = @_;
   my $end = min($max, $start + $interval);


   # "Remove" scientific notation so the regex below does not make
   # 6.123456e+18 into 6.12345.
   $start = sprintf('%.17f', $start) if $start =~ /e/;
   $end   = sprintf('%.17f', $end)   if $end   =~ /e/;

   # Trim decimal places, if needed.  This helps avoid issues with float
   # precision differing on different platforms.
   $start =~ s/\.(\d{5}).*$/.$1/;
   $end   =~ s/\.(\d{5}).*$/.$1/;

   if ( $end > $start ) {
      return ( $start, $end );
   }
   else {
      die "Chunk size is too small: $end !> $start\n";
   }
}

sub range_time {
   my ( $self, $dbh, $start, $interval, $max ) = @_;
   my $sql = "SELECT SEC_TO_TIME($start), SEC_TO_TIME(LEAST($max, $start + $interval))";
   MKDEBUG && _d($sql);
   return $dbh->selectrow_array($sql);
}

sub range_date {
   my ( $self, $dbh, $start, $interval, $max ) = @_;
   my $sql = "SELECT FROM_DAYS($start), FROM_DAYS(LEAST($max, $start + $interval))";
   MKDEBUG && _d($sql);
   return $dbh->selectrow_array($sql);
}

sub range_datetime {
   my ( $self, $dbh, $start, $interval, $max ) = @_;
   my $sql = "SELECT DATE_ADD('$EPOCH', INTERVAL $start SECOND), "
       . "DATE_ADD('$EPOCH', INTERVAL LEAST($max, $start + $interval) SECOND)";
   MKDEBUG && _d($sql);
   return $dbh->selectrow_array($sql);
}

sub range_timestamp {
   my ( $self, $dbh, $start, $interval, $max ) = @_;
   my $sql = "SELECT FROM_UNIXTIME($start), FROM_UNIXTIME(LEAST($max, $start + $interval))";
   MKDEBUG && _d($sql);
   return $dbh->selectrow_array($sql);
}

# Returns the number of seconds between $EPOCH and the value, according to
# the MySQL server.  (The server can do no wrong).  I believe this code is right
# after looking at the source of sql/time.cc but I am paranoid and add in an
# extra check just to make sure.  Earlier versions overflow on large interval
# values, such as on 3.23.58, '1970-01-01' - interval 58000000000 second is
# 2037-06-25 11:29:04.  I know of no workaround.  TO_DAYS('0000-....') is NULL,
# so we treat it as 0.
sub timestampdiff {
   my ( $self, $dbh, $time ) = @_;
   my $sql = "SELECT (COALESCE(TO_DAYS('$time'), 0) * 86400 + TIME_TO_SEC('$time')) "
      . "- TO_DAYS('$EPOCH 00:00:00') * 86400";
   MKDEBUG && _d($sql);
   my ( $diff ) = $dbh->selectrow_array($sql);
   $sql = "SELECT DATE_ADD('$EPOCH', INTERVAL $diff SECOND)";
   MKDEBUG && _d($sql);
   my ( $check ) = $dbh->selectrow_array($sql);
   die <<"   EOF"
   Incorrect datetime math: given $time, calculated $diff but checked to $check.
   This could be due to a version of MySQL that overflows on large interval
   values to DATE_ADD(), or the given datetime is not a valid date.  If not,
   please report this as a bug.
   EOF
      unless $check eq $time;
   return $diff;
}


# #############################################################################
# End point validation.
# #############################################################################

# These sub require val (or min and max) args which usually aren't NULL
# but could be zero so the usual "die ... unless $args{$arg}" check does
# not work.

# Returns valid min and max values.  A valid val evaluates to a non-NULL value.
# Arguments:
#   * dbh       dbh
#   * db_tbl    scalar: quoted `db`.`tbl`
#   * col       scalar: quoted `column`
#   * col_type  scalar: column type of the value
#   * min       scalar: any scalar value
#   * max       scalar: any scalar value
# Optional arguments:
#   * index_hint scalar: "FORCE INDEX (...)" hint
#   * where      scalar: WHERE clause without "WHERE"
#   * tries      scalar: fetch up to this many rows to find a valid value
#   * zero_chunk bool: do a separate chunk for zero values
# Some column types can store invalid values, like most of the temporal
# types.  When evaluated, invalid values return NULL.  If the value is
# NULL to begin with, then it is not invalid because NULL is valid.
# For example, TO_DAYS('2009-00-00') evalues to NULL because that date
# is invalid, even though it's storable.
sub get_valid_end_points {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db_tbl col col_type);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db_tbl, $col, $col_type) = @args{@required_args};
   my ($real_min, $real_max)           = @args{qw(min max)};

   # Common error message format in case there's a problem with
   # finding a valid min or max value.
   my $err_fmt = "Error finding a valid %s value for table $db_tbl on "
               . "column $col. The real %s value %s is invalid and "
               . "no other valid values were found.  Verify that the table "
               . "has at least one valid value for this column"
               . ($args{where} ? " where $args{where}." : ".");

   # Validate min value if it's not NULL.  NULL is valid.
   my $valid_min = $real_min;
   if ( defined $valid_min ) {
      # Get a valid min end point.
      MKDEBUG && _d("Validating min end point:", $real_min);
      $valid_min = $self->_get_valid_end_point(
         %args,
         val      => $real_min,
         endpoint => 'min',
      );
      die sprintf($err_fmt, 'minimum', 'minimum',
         (defined $real_min ? $real_min : "NULL"))
         unless defined $valid_min;
   }

   # Validate max value if it's not NULL.  NULL is valid.
   my $valid_max = $real_max;
   if ( defined $valid_max ) {
      # Get a valid max end point.  So far I've not found a case where
      # the actual max val is invalid, but check anyway just in case.
      MKDEBUG && _d("Validating max end point:", $real_min);
      $valid_max = $self->_get_valid_end_point(
         %args,
         val      => $real_max,
         endpoint => 'max',
      );
      die sprintf($err_fmt, 'maximum', 'maximum',
         (defined $real_max ? $real_max : "NULL"))
         unless defined $valid_max;
   }

   return $valid_min, $valid_max;
}

# Does the actual work for get_valid_end_points() for each end point.
sub _get_valid_end_point {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db_tbl col col_type);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db_tbl, $col, $col_type) = @args{@required_args};
   my $val = $args{val};

   # NULL is valid.
   return $val unless defined $val;

   # Right now we only validate temporal types, but when we begin
   # chunking char and hex columns we'll need to validate those.
   # E.g. HEX('abcdefg') is invalid and we'll probably find some
   # combination of char val + charset/collation that's invalid.
   my $validate = $col_type =~ m/time|date/ ? \&_validate_temporal_value
                :                             undef;

   # If we cannot validate the value, assume it's valid.
   if ( !$validate ) {
      MKDEBUG && _d("No validator for", $col_type, "values");
      return $val;
   }

   # Return the value if it's already valid.
   return $val if defined $validate->($dbh, $val);

   # The value is not valid so find the first one in the table that is.
   MKDEBUG && _d("Value is invalid, getting first valid value");
   $val = $self->get_first_valid_value(
      %args,
      val      => $val,
      validate => $validate,
   );

   return $val;
}

# Arguments:
#   * dbh       dbh
#   * db_tbl    scalar: quoted `db`.`tbl`
#   * col       scalar: quoted `column` name
#   * val       scalar: the current value, may be real, maybe not
#   * validate  coderef: returns a defined value if the given value is valid
#   * endpoint  scalar: "min" or "max", i.e. find first endpoint() real val
# Optional arguments:
#   * tries      scalar: fetch up to this many rows to find a valid value
#   * index_hint scalar: "FORCE INDEX (...)" hint
#   * where      scalar: WHERE clause without "WHERE"
# Returns the first column value from the given db_tbl that does *not*
# evaluate to NULL.  This is used mostly to eliminate unreal temporal
# values which MySQL allows to be stored, like "2010-00-00".  Returns
# undef if no real value is found.
sub get_first_valid_value {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db_tbl col validate endpoint);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db_tbl, $col, $validate, $endpoint) = @args{@required_args};
   my $tries = defined $args{tries} ? $args{tries} : 5;
   my $val   = $args{val};

   # NULL values are valid and shouldn't be passed to us.
   return unless defined $val;

   # Prep a sth for fetching the next col val.
   my $cmp = $endpoint =~ m/min/i ? '>'
           : $endpoint =~ m/max/i ? '<'
           :                        die "Invalid endpoint arg: $endpoint";
   my $sql = "SELECT $col FROM $db_tbl "
           . ($args{index_hint} ? "$args{index_hint} " : "")
           . "WHERE $col $cmp ? AND $col IS NOT NULL "
           . ($args{where} ? "AND ($args{where}) " : "")
           . "ORDER BY $col LIMIT 1";
   MKDEBUG && _d($dbh, $sql);
   my $sth = $dbh->prepare($sql);

   # Fetch the next col val from the db.tbl until we find a valid one
   # or run out of rows.  Only try a limited number of next rows.
   my $last_val = $val;
   while ( $tries-- ) {
      $sth->execute($last_val);
      my ($next_val) = $sth->fetchrow_array();
      MKDEBUG && _d('Next value:', $next_val, '; tries left:', $tries);
      if ( !defined $next_val ) {
         MKDEBUG && _d('No more rows in table');
         last;
      }
      if ( defined $validate->($dbh, $next_val) ) {
         MKDEBUG && _d('First valid value:', $next_val);
         $sth->finish();
         return $next_val;
      }
      $last_val = $next_val;
   }
   $sth->finish();
   $val = undef;  # no valid value found

   return $val;
}

# Evalutes any temporal value, returns NULL if it's invalid, else returns
# a value (possibly zero). It's magical but tested.  See also,
# http://hackmysql.com/blog/2010/05/26/detecting-invalid-and-zero-temporal-values/
sub _validate_temporal_value {
   my ( $dbh, $val ) = @_;
   my $sql = "SELECT IF(TIME_FORMAT(?,'%H:%i:%s')=?, TIME_TO_SEC(?), TO_DAYS(?))";
   my $res;
   eval {
      MKDEBUG && _d($dbh, $sql, $val);
      my $sth = $dbh->prepare($sql);
      $sth->execute($val, $val, $val, $val);
      ($res) = $sth->fetchrow_array();
      $sth->finish();
   };
   if ( $EVAL_ERROR ) {
      MKDEBUG && _d($EVAL_ERROR);
   }
   return $res;
}

sub get_nonzero_value {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db_tbl col col_type);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db_tbl, $col, $col_type) = @args{@required_args};
   my $tries = defined $args{tries} ? $args{tries} : 5;
   my $val   = $args{val};

   # Right now we only need a special check for temporal values.
   # _validate_temporal_value() does double-duty for this.  The
   # default anonymous sub handles ints.
   my $is_nonzero = $col_type =~ m/time|date/ ? \&_validate_temporal_value
                  :                             sub { return $_[1]; };

   if ( !$is_nonzero->($dbh, $val) ) {  # quasi-double-negative, sorry
      MKDEBUG && _d('Discarding zero value:', $val);
      my $sql = "SELECT $col FROM $db_tbl "
              . ($args{index_hint} ? "$args{index_hint} " : "")
              . "WHERE $col > ? AND $col IS NOT NULL "
              . ($args{where} ? "AND ($args{where}) " : '')
              . "ORDER BY $col LIMIT 1";
      MKDEBUG && _d($sql);
      my $sth = $dbh->prepare($sql);

      my $last_val = $val;
      while ( $tries-- ) {
         $sth->execute($last_val);
         my ($next_val) = $sth->fetchrow_array();
         if ( $is_nonzero->($dbh, $next_val) ) {
            MKDEBUG && _d('First non-zero value:', $next_val);
            $sth->finish();
            return $next_val;
         }
         $last_val = $next_val;
      }
      $sth->finish();
      $val = undef;  # no non-zero value found
   }

   return $val;
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
# End TableChunker package
# ###########################################################################
