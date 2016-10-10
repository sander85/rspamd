#!/usr/bin/env perl

use warnings;
use strict;
use Pod::Usage;
use Getopt::Long;
use Time::HiRes qw(gettimeofday tv_interval);
use JSON::XS;
use String::ShellQuote;
use Data::Dumper;

my $spam_dir;
my $ham_dir;
my $parallel       = 1;
my $classifier     = "bayes";
my $spam_symbol    = "BAYES_SPAM";
my $ham_symbol     = "BAYES_HAM";
my $timeout        = 10;
my $rspamc         = $ENV{'RSPAMC'} || "rspamc";
my $train_fraction = 0.5;
my $man;
my $help;

GetOptions(
  "spam|s=s"       => \$spam_dir,
  "ham|h=s"        => \$ham_dir,
  "spam-symbol=s"  => \$spam_symbol,
  "ham-symbol=s"   => \$ham_symbol,
  "classifier|c=s" => \$classifier,
  "timeout|t=f"    => \$timeout,
  "parallel|p=i"   => \$parallel,
  "help|?"         => \$help,
  "man"            => \$man
) or pod2usage(2);

pod2usage(1) if $help;
pod2usage( -exitval => 0, -verbose => 2 ) if $man;

sub read_dir_files {
  my ( $dir, $target ) = @_;
  opendir( my $dh, $dir ) or die "cannot open dir $dir: $!";
  while ( my $file = readdir $dh ) {
    if ( -f "$dir/$file" ) {
      push @{$target}, "$dir/$file";
    }
  }
}

sub shuffle_array {
  my ($ar) = @_;

  for ( my $i = 0 ; $i < scalar @{$ar} ; $i++ ) {
    if ( $i > 1 ) {
      my $sel = int( rand( $i - 1 ) );
      ( @{$ar}[$i], @{$ar}[$sel] ) = ( @{$ar}[$sel], @{$ar}[$i] );
    }
  }
}

sub learn_samples {
  my ( $ar_ham, $ar_spam ) = @_;
  my $len;
  my $processed = 0;
  my $total     = 0;

  my @files_spam;
  my @files_ham;

  $len = int( scalar @{$ar_ham} * $train_fraction );
  my @cur_vec;

  # Shuffle spam and ham samples
  for ( my $i = 0 ; $i < $len ; $i++ ) {
    if ( $i > 0 && ( $i % $parallel == 0 || $i == $len - 1 ) ) {
      push @cur_vec, @{$ar_ham}[$i];
      push @files_ham, [@cur_vec];
      @cur_vec = ();
      $total++;
    }
    else {
      push @cur_vec, @{$ar_ham}[$i];
    }
  }

  $len     = int( scalar @{$ar_spam} * $train_fraction );
  @cur_vec = ();
  for ( my $i = 0 ; $i < $len ; $i++ ) {
    if ( $i > 0 && ( $i % $parallel == 0 || $i == $len - 1 ) ) {
      push @cur_vec, @{$ar_spam}[$i];
      push @files_spam, [@cur_vec];
      @cur_vec = ();
      $total++;
    }
    else {
      push @cur_vec, @{$ar_spam}[$i];
    }
  }

  for ( my $i = 0 ; $i < $total ; $i++ ) {
    my $args;
    my $cmd;

    if ( $i % 2 == 0 ) {
      $args = pop @files_spam;

      if ( !$args ) {
        $args = pop @files_ham;
        $cmd  = 'learn_ham';
      }
      else {
        $cmd = 'learn_spam';
      }
    }
    else {
      $args = pop @files_ham;
      if ( !$args ) {
        $args = pop @files_spam;
        $cmd  = 'learn_spam';
      }
      else {
        $cmd = 'learn_ham';
      }
    }

    my $args_quoted = shell_quote @{$args};
    open(
      my $p,
"$rspamc -t $timeout -c $classifier --compact -j -n $parallel $cmd $args_quoted |"
    ) or die "cannot spawn $rspamc: $!";

    while (<$p>) {
      my $res = eval('decode_json($_)');
      if ( $res && $res->{'success'} ) {
        $processed++;
      }
    }
  }

  return $processed;
}

sub cross_validate {
  my ($hr)          = @_;
  my $args          = "";
  my $processed     = 0;
  my $fp_spam       = 0;
  my $fn_spam       = 0;
  my $fp_ham        = 0;
  my $fn_ham        = 0;
  my $total_spam    = 0;
  my $total_ham     = 0;
  my $detected_spam = 0;
  my $detected_ham  = 0;
  my $i             = 0;
  my $len           = scalar keys %{$hr};
  my @files_spam;
  my @files_ham;
  my @cur_spam;
  my @cur_ham;

  while ( my ( $fn, $spam ) = each( %{$hr} ) ) {
    if ($spam) {
      if ( scalar @cur_spam >= $parallel || $i == $len - 1 ) {
        push @cur_spam, $fn;
        push @files_spam, [@cur_spam];
        @cur_spam = ();
      }
      else {
        push @cur_spam, $fn;
      }
    }
    else {
      if ( scalar @cur_ham >= $parallel || $i == $len - 1 ) {
        push @cur_ham, $fn;
        push @files_ham, [@cur_ham];
        @cur_ham = ();
      }
      else {
        push @cur_ham, $fn;
      }
    }
  }

  shuffle_array( \@files_spam );

  foreach my $fn (@files_spam) {
    my $args_quoted = shell_quote @{$fn};
    my $spam        = 1;

    open(
      my $p,
"$rspamc -t $timeout -n $parallel --header=\"Settings: {symbols_enabled=[BAYES_SPAM]}\" --compact -j $args_quoted |"
    ) or die "cannot spawn $rspamc: $!";

    while (<$p>) {
      my $res = eval('decode_json($_)');
      if ( $res && $res->{'default'} ) {
        $processed++;

        if ($spam) {
          $total_spam++;

          if ( $res->{'default'}->{$ham_symbol} ) {
            $fp_spam++;
          }
          elsif ( !$res->{'default'}->{$spam_symbol} ) {
            $fn_spam++;
          }
          else {
            $detected_spam++;
          }
        }
        else {
          $total_ham++;

          if ( $res->{'default'}->{$spam_symbol} ) {
            $fp_ham++;
          }
          elsif ( !$res->{'default'}->{$ham_symbol} ) {
            $fn_ham++;
          }
          else {
            $detected_ham++;
          }
        }
      }
    }
  }

  shuffle_array( \@files_ham );

  foreach my $fn (@files_ham) {
    my $args_quoted = shell_quote @{$fn};
    my $spam        = 0;

    open(
      my $p,
"$rspamc -t $timeout -n $parallel --header=\"Settings: {symbols_enabled=[BAYES_SPAM]}\" --compact -j $args_quoted |"
    ) or die "cannot spawn $rspamc: $!";

    while (<$p>) {
      my $res = eval('decode_json($_)');
      if ( $res && $res->{'default'} ) {
        $processed++;

        if ($spam) {
          $total_spam++;

          if ( $res->{'default'}->{$ham_symbol} ) {
            $fp_spam++;
          }
          elsif ( !$res->{'default'}->{$spam_symbol} ) {
            $fn_spam++;
          }
          else {
            $detected_spam++;
          }
        }
        else {
          $total_ham++;

          if ( $res->{'default'}->{$spam_symbol} ) {
            $fp_ham++;
          }
          elsif ( !$res->{'default'}->{$ham_symbol} ) {
            $fn_ham++;
          }
          else {
            $detected_ham++;
          }
        }
      }
    }
  }

  printf "Scanned %d messages
%d spam messages (%d detected)
%d ham messages (%d detected)\n",
    $processed, $total_spam, $detected_spam, $total_ham, $detected_ham;

  printf "\nHam FP rate: %.2f%% (%d messages)
Ham FN rate: %.2f%% (%d messages)\n",
    $fp_ham / $total_ham * 100.0, $fp_ham,
    $fn_ham / $total_ham * 100.0, $fn_ham;

  printf "\nSpam FP rate: %.2f%% (%d messages)
Spam FN rate: %.2f%% (%d messages)\n",
    $fp_spam / $total_spam * 100.0, $fp_spam,
    $fn_spam / $total_spam * 100.0, $fn_spam;
}

if ( !$spam_dir || !$ham_dir ) {
  die "spam or/and ham directories are not specified";
}

my @spam_samples;
my @ham_samples;

read_dir_files( $spam_dir, \@spam_samples );
read_dir_files( $ham_dir,  \@ham_samples );
shuffle_array( \@spam_samples );
shuffle_array( \@ham_samples );

my $learned = 0;
my $t0      = [gettimeofday];
$learned = learn_samples( \@ham_samples, \@spam_samples );
my $t1 = [gettimeofday];

printf "Learned classifier, %d items processed, %.2f seconds elapsed\n",
  $learned, tv_interval( $t0, $t1 );

my %validation_set;
my $len = int( scalar @spam_samples * $train_fraction );
for ( my $i = $len ; $i < scalar @spam_samples ; $i++ ) {
  $validation_set{ $spam_samples[$i] } = 1;
}

$len = int( scalar @ham_samples * $train_fraction );
for ( my $i = $len ; $i < scalar @spam_samples ; $i++ ) {
  $validation_set{ $ham_samples[$i] } = 0;
}

cross_validate( \%validation_set );

__END__

=head1 NAME

classifier_test.pl - test various parameters for a classifier

=head1 SYNOPSIS

classifier_test.pl [options]

 Options:
   --spam                 Directory with spam files
   --ham                  Directory with ham files
   --spam-symbol          Symbol for spam (default: BAYES_SPAM)
   --ham-symbol           Symbol for ham (default: BAYES_HAM)
   --classifier           Classifier to test (default: bayes)
   --timeout              Timeout for rspamc (default: 10)
   --parallel             Parallel execution (default: 1)
   --help                 Brief help message
   --man                  Full documentation

=head1 OPTIONS

=over 8

=item B<--spam>

Directory with spam files.

=item B<--ham>

Directory with ham files.

=item B<--classifier>

Specifies classifier name to test.

=item B<--help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=back

=head1 DESCRIPTION

B<classifier_test.pl> is intended to test Rspamd classifier for false positives,
false negatives and other parameters. It uses half of the corpus for training
and half for cross-validation.

=cut