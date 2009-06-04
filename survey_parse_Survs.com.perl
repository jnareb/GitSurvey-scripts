#!/usr/bin/perl

# survey_parse - parse results of survey from Survs.com in CSV format
#
# (C) 2008, Jakub Narebski
#
# This program is licensed under the GPLv2 or later
#
# Parse result of exporting individual respondends (individual replies)
# in CSV format (Surveys > {survey} > Analyze > Export) from Survs.com.
# It is intendend to parse results of "Git User's Survey 2008"

use strict;
use warnings;

use Encode;
use Text::CSV;
use Text::Wrap;
use Date::Manip;
use Getopt::Long;

use constant DEBUG => 0;
use Data::Dumper;

binmode STDOUT, ':utf8';

# ======================================================================
# ----------------------------------------------------------------------
# Parse data (files from command line)
sub parse_data {
	my ($hist, $datehist, $survinfo) = @_;
	#my $filename = shift;

	my $csv = Text::CSV->new();
	my ($line, $full_line);
	my @columns = ();


	#$survinfo->{'filename'} = $filename;

	# ........................................
	# CSV header
	HEADER_LINE:
	while ($line = <>) {
		last HEADER_LINE unless defined $line;
		chomp $line;
		last HEADER_LINE unless ($line);

		$csv->parse($line);
		@columns = $csv->fields();

		if (@columns > 1) {
			$survinfo->{$columns[0]} = $columns[1];
		} else {
			# Survey title (first line of file)
			$survinfo->{'Title'} = $columns[0];
		}
	}

	# ........................................
	# CSV column headers
	$full_line = '';
	do {
		$line = <>;
		chomp($line);
		$full_line .= $line;
	} while ($line !~ /"$/);

	$csv->parse($full_line);
	@columns = $csv->fields();
	$survinfo->{'columns'} = [ @columns ];

	splice(@columns,0,3); # remove "Respondent Number","Date","Time"
	$survinfo->{'questions'} = [ grep { $_ } @columns ];

	# ........................................
	# Rows for "matrix view" questions

	#TODO !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

	# ........................................
	# Parsing data
 LINE:
	while ($line = <>) {
		chomp $line;
		next LINE unless $line;
		print "$.:line=$line\n";
		# line continues if it doesn't end in '"'
		if ($line !~ /"$/) {
			$line .= <>;
			print "$.:cont=$line\n";
			redo LINE unless eof();
		}

		# process line
		utf8::decode($line) if utf8::valid($line);
		print "$.:utf8=$line\n";
		unless ($csv->parse($line)) {
			my $err = $csv->error_input();

			print STDERR "$.: parse() failed on argument: $err\n";
			next LINE;
		}

		@columns = $csv->fields();
		unless (@columns > 0) {
			print STDERR "$.: no columns in $line\n";
			next LINE;
		}

		my @questions = ();
		for (my $i = 0; $i < @columns; $i++) {
			push @questions, $columns[$i] if $survinfo->{'columns'}[$i];
		}
		splice(@questions,0,3); # remove "Respondent Number","Date","Time"
		$survinfo->{'_tmp'} = [ @questions ];

		print "$.:n=$columns[0]\n" if defined($columns[0]);
	}
}

# ----------------------------------------------------------------------
# Create histogram

# add_to_hist(HASHREF, LIST)
sub add_to_hist {
	my ($hist, @values) = @_;

	foreach my $val (@values) {
		if (exists $hist->{$val}) {
			$hist->{$val}++;
		} else {
			$hist->{$val} = 1;
		}
	}
}

# remove duplicated entries in sorted array
sub uniq (@) {
	my @in  = @_;
	my @out = ();

	$out[0] = $in[0] if @in > 0;
	for (my $i = 1; $i <= $#in; ++$i) {
		if ($in[$i] ne $in[$i-1]) {
			push @out, $in[$i];
		}
	}

	return @out;
}

# ----------------------------------------------------------------------
# Normalize input data

sub normalize_country {
}

# returns ARRAY
sub normalize_language {
}

sub normalize_age {
}

# ----------------------------------------------------------------------
# Format output

# ======================================================================
# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# DATA
my @sections =
	({'title' => 'About you',
	  'start' => 1}, # number of first question in section
	 {'title' => 'Getting started with Git',
	  'start' => 4},
	 {'title' => 'Other SCMs (Software Control Management systems)',
	  'start' => 12},
	 {'title' => 'How you use Git',
	  'start' => 16},
	 {'title' => 'What you think of Git',
	  'start' => 32},
	 {'title' => 'Changes in Git'.
	             ' (since year ago, or since you started using it)',
	  'start' => 36},
	 {'title' => 'Documentation',
	  'start' => 38},
	 {'title' => 'Translating Git',
	  'start' => 45},
	 {'title' => 'Getting help, staying in touch',
	  'start' => 47},
	 {'title' => 'Open forum',
	  'start' => 58});


# ======================================================================
# ======================================================================
# ======================================================================
# MAIN

my %hist       = ();
my %datehist   = ();
my %surveyinfo = ();

$surveyinfo{'testing'} =
	[1..20, 946];

parse_data(\%hist, \%datehist, \%surveyinfo);

#print Data::Dumper->Dump(
#	[\@sections, \%hist, \%datehist, \%surveyinfo],
#	[qw(\@sections \%hist \%datehist \%surveyinfo)]
#);

__END__
