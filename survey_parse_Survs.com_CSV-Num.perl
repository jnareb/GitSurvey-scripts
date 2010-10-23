#!/usr/bin/perl

# survey_parse - parse results of survey from Survs.com in CSV format
#
# (C) 2008-2010, Jakub Narebski
#
# This program is licensed under the GPLv2 or later
#
# Parse result of exporting individual respondends (individual replies)
# in CSV format (Surveys > {survey} > Analyze > Export) from Survs.com,
# using 'Numeric' (shorter) format for responses
#
# It is intendend to parse results of "Git User's Survey 20xx"

use strict;
use warnings;

use Encode;
use PerlIO::gzip;
use Text::CSV;
use Text::Wrap;
use Getopt::Long;
use Pod::Usage;
use List::Util qw(max maxstr min minstr sum);
use List::MoreUtils qw(uniq);
use Text::LevenshteinXS qw(distance);
use Term::ReadLine;
#use Term::ReadKey;
#use Term::ANSIColor;
use File::Spec;
use File::Basename;

use Date::Manip;
use Locale::Country;
use Locale::Object::Country;
use Statistics::Descriptive;

use constant DEBUG => 0;

# Storable uses *.storable, YAML uses *.yml
use Data::Dumper;
use Storable qw(store retrieve);
# YAML::Tiny has strange "'" escaping
#use YAML::Tiny qw(DumpFile LoadFile);
use YAML::Any qw(DumpFile LoadFile);

binmode STDOUT, ':utf8';

# ======================================================================
# ----------------------------------------------------------------------
my $survinfo_file = 'GitSurvey2010_questions.yml';
my $filename = 'Survey results Oct 16, 10.csv';
my $respfile = 'GitSurvey2010.responses.storable';
my $statfile = 'GitSurvey2010.stats.storable';
my $otherfile = 'GitSurvey2010.other_repl.yml'; # user-editable

my ($reparse, $restat);

my $resp_tz = "CET"; # timezone of responses date and time
my @special_columns = ( # are not about answers to questions
	"Respondent Number",
	"Date",
	"Time",
	"Channel"
);
my $nskip = scalar @special_columns;

# ask for categorizing even those response that match some rule
my $ask_categorized = 0;

my @country_names = all_country_names();

# 'text' or 'wiki' (actually anything or 'wiki')
my $format = 'text'; # default output format
# wiki table style
my $tablestyle = ' border="1" cellpadding="3" cellspacing="0"';
my %rowstyle =
	('th'  => 'font-weight: bold; background-color: #ffffcc;',
	 'row' => undef,
	 'footer' => 'font-weight: bold; font-style: italic; background-color: #ccffff;'
	);
# default (minimum) width of column with answer
my $min_width = 30;
my $width = $min_width;

# vertical graphical histogram for 'wiki' format
my $show_graph = 1;
my $graph_color = '#ff0f0f';
my $graph_width = 200;
my $graph_units = 'px';

my @survey_data = ();
my %survey_data = @survey_data;
my @sections = ();

# ----------------------------------------------------------------------

# Extract column headers from CSV file, from first row
sub extract_headers_csv {
	my ($csv, $fh) = @_;

	seek $fh, 0, 0; # 0=SEEK_START; # rewind to start, just in case

	my $row = $csv->getline($fh);
	unless (defined $row) {
		my $err = $csv->error_input();

		print STDERR "$.: getline() failed on argument: $err\n" .
		             $csv->error_diag();
		return;
	}

	return wantarray ? @$row : $row;
}

# Calculate staring column for each question
sub process_headers_csv {
	my ($survinfo, $headers) = @_;
	my @columns = @{$headers}[$nskip..$#$headers];

	# calculate question to starting column number
	my $qno = 0;
 CSV_COLUMN:
	for (my $i = 0; $i < @columns; $i++) {
		my $colname = $columns[$i];
		next unless ($colname =~ m/^Q(\d+)/);
		if ($qno != $1) {
			$qno = $1;
			$survinfo->{"Q$qno"}{'col'} = $i;
		}
	}
}

# Handle special columns (number of response, date and time, channel)
sub responder_info_from_response {
	my ($survinfo, $row) = @_;

	my ($respno, $respdate, $resptime, $channel) = @$row;

	my ($year, $day, $month) = split("/", $respdate);
	$respdate = "$year-$month-$day"; # ISO format

	my %info = (
		'respondent number' => $respno,
		'date' => $respdate,
		'time' => $resptime,
		'parsed_date' => ParseDate("$respdate $resptime $resp_tz"),
		'channel' => $channel
	);
	return \%info;
}

# Extract info about given question from response
sub question_results_from_response {
	my ($qinfo, $row) = @_;
	my $col = $qinfo->{'col'} + $nskip; # column or starting column

	# this if-elsif-else chain should be probably converted
	# to dispatch table (might be not possible) or a switch statement
	my %resp;
	if ($qinfo->{'freeform'} ||
	    !exists $qinfo->{'codes'}) {
		# free-form essay, single value or
		# free-form text, single value
		my $contents = $row->[$col];
		%resp = (
			'type' => $qinfo->{'freeform'} ? 'essay' : 'oneline',
			'contents' => $contents
		);
		$resp{'skipped'} = 1
			if ($contents eq '');

		# free-form text, single value can be tabularized
		# if it is not skipped
		if (!exists $qinfo->{'codes'}       &&
		    ref($qinfo->{'hist'}) eq 'CODE' &&
		    $contents ne '') {
			%resp = (
				%resp,
				'original' => $contents,
				'contents' => $qinfo->{'hist'}->($contents)
			);
		}

	} elsif (!$qinfo->{'multi'} && !$qinfo->{'columns'}) {
		# single choice
		my $contents = $row->[$col];
		my $other;
		%resp = (
			'type' => 'single-choice',
			'contents' => $contents
		);
		if ($qinfo->{'other'}) {
			$other = $row->[$col+1];
			$resp{'other'} = $other
				unless ($other eq '');
		}
		$resp{'skipped'} = 1
			if ($contents eq '' &&
			    (!$qinfo->{'other'} || $other eq ''));

	} elsif ($qinfo->{'multi'} && !$qinfo->{'columns'}) {
		# multiple choice
		my $skipped = 1;
		%resp = (
			'type' => 'multiple-choice',
			'contents' => []
		);
		for (my $j = 0; $j < @{$qinfo->{'codes'}}; $j++) {
			my $value = $row->[$col+$j];
			next unless (defined $value && $value ne '');
			if ($qinfo->{'other'} && $j == $#{$qinfo->{'codes'}}) {
				$value = "".($j+1); # number stringified, not value !!!
			}
			push @{$resp{'contents'}}, $value;
			$skipped = 0;
		}
		# multiple choice with other
		if ($qinfo->{'other'}) {
			my $other = $row->[$col+$#{$qinfo->{'codes'}}];
			$resp{'other'} = $other if ($other ne '');
		}
		$resp{'skipped'} = 1 if ($skipped);

	} elsif ($qinfo->{'columns'}) {
		# matrix
		my $skipped = 1;
		%resp = (
			'type' => 'matrix',
			'contents' => []
		);
		for (my $j = 0; $j < @{$qinfo->{'codes'}}; $j++) {
			my $value = $row->[$col+$j];
			next unless (defined $value && $value ne '');
			push @{$resp{'contents'}}, $value;
			$skipped = 0;
		}
		$resp{'skipped'} = 1 if ($skipped);

	} # end if-elsif ...

	return \%resp;
}

# ......................................................................

# Parse data (given $filename CSV file)
sub parse_data {
	my ($survinfo, $responses) = @_;

	my $csv = Text::CSV->new({
		binary => 1, eol => $/,
		escape_char => "\\",
		allow_loose_escapes => 1
	}) or die "Could not create Text::CSV object: ".
	          Text::CSV->error_diag();

	open my $fh, '<', $filename
		or die "Could not open file '$filename': $!";
	if ($filename =~ m/\.gz$/) {
		binmode $fh, ':gzip'
			or die "Could not set up gzip decompression on '$filename': $!";
	}

	# ........................................
	# CSV column headers
	my @headers = extract_headers_csv($csv, $fh);
	process_headers_csv($survinfo, \@headers);
	my $nfields = scalar(@headers);

	# ........................................
	# CSV lines
 RESPONSE:
	while (1) {
		my $row = $csv->getline($fh);
		last RESPONSE if (!defined $row && $csv->eof());

		unless (defined $row) {
			my $err = $csv->error_input();

			print STDERR "$.: getline() failed on argument: $err\n";
			$csv->error_diag(); # void context: print to STDERR
			last RESPONSE; # error would usually be not recoverable
		}

		unless ($nfields == scalar(@$row)) {
			print STDERR "$.: number of columns doesn't match: ".
			             "$nfields != ".(scalar @$row)."\n";
			last RESPONSE; # error would usually be not recoverable
		}

		my $resp = [];
		$resp->[0] = responder_info_from_response($survinfo, $row);

	QUESTION:
		for (my $qno = 1; $qno <= $survinfo->{'nquestions'}; $qno++) {
			my $qinfo = $survinfo->{"Q$qno"};
			next unless (defined $qinfo);

			$resp->[$qno] = question_results_from_response($qinfo, $row);
		} # end for QUESTION

		#$responses->[$respno] = $resp
		push @$responses, $resp
			if (defined $resp && ref($resp) eq 'ARRAY' && @{$resp} > 0);

	} # end while RESPONSE

	return $responses;
}

# Parse CSV file, or retrieve serialized parsed data from file
sub parse_or_retrieve_data {
	my $survey_data = shift;
	my $responses = [];
	my $what = 'responses';
	local $| = 1; # autoflush

	if (! -f $respfile) {
		$filename .= '.gz'
			unless -r $filename;

		print STDERR "parsing '$filename'... ";
		parse_data($survey_data, $responses);
		print STDERR "(done)\n";

		print STDERR "storing $what in '$respfile'... ";
		store($responses, $respfile);
		print STDERR "(done)\n";
	} else {
		print STDERR "retrieving $what from '$respfile'... ";
		$responses = retrieve($respfile);
		print STDERR "(done)\n";
	}
	return wantarray ? @$responses : $responses;
}

# ----------------------------------------------------------------------
# Make statistics

# Initialize structures for histograms of answers
sub prepare_hist {
	my $survey_data = shift;

	Locale::Country::alias_code('uk' => 'gb');

 QUESTION:
	for (my $qno = 1; $qno <= $survey_data->{'nquestions'}; $qno++) {
		my $q = $survey_data->{"Q$qno"};
		next unless (defined $q);
		next if (exists $q->{'histogram'});

		if (exists $q->{'columns'}) {
			# matrix
			my $ncols = scalar @{$q->{'columns'}};
			$q->{'histogram'} = {
				map { $_ => [ (0) x $ncols ] }
				@{$q->{'codes'}}
			};
			$q->{'matrix'} = {
				map { $_ => { 'count' => 0, 'score' => 0 } }
				@{$q->{'codes'}}
			};
		} elsif (exists $q->{'codes'}) {
			$q->{'histogram'} = {
				map { $_ => 0 } @{$q->{'codes'}}
			}
		} elsif (ref($q->{'hist'}) eq 'CODE') {
			$q->{'histogram'} = {};
		}
	}
}

# Generate histograms of answers and responses
sub make_hist {
	my ($survey_data, $responses) = @_;
	my $nquestions = $survey_data->{'nquestions'};

	# ...........................................
	# Generate histograms of answers
 RESPONSE:
	foreach my $resp (@$responses) {

	QUESTION:
		for (my $qno = 1; $qno <= $nquestions; $qno++) {
			my $qinfo = $survey_data->{"Q$qno"};
			next unless (defined $qinfo);

			my $qresp = $resp->[$qno];

			# count non-empty / skipped responses
			if ($qresp->{'skipped'}) {
				add_to_hist($qinfo, 'skipped');
			} else {
				add_to_hist($qinfo, 'base');
			}

			# skip non-histogrammed questions, and skipped responses
			next unless (exists $qinfo->{'histogram'});
			next if ($qresp->{'skipped'});

			# (perhaps replace this if-elsif chain by dispatch)
			if ($qresp->{'type'} eq 'single-choice') {
				add_to_hist($qinfo->{'histogram'},
										$qinfo->{'codes'}[$qresp->{'contents'}-1]);
				# something to do with other, if it is present, and used
				# ...
			} elsif ($qresp->{'type'} eq 'multiple-choice') {
				add_to_hist($qinfo->{'histogram'},
										map { $qinfo->{'codes'}[$_-1] } @{$qresp->{'contents'}});
				# something to do with other, if it is present, and used
				# ...
			} elsif ($qresp->{'type'} eq 'matrix') {
				for (my $i = 0; $i < @{$qresp->{'contents'}}; $i++) {
					my $rowname = $qinfo->{'codes'}[$i];
					my $column  = $qresp->{'contents'}[$i];
					$qinfo->{'histogram'}{$rowname}[$column-1]++;
					# row score (columns as 1..N grade)
					$qinfo->{'matrix'}{$rowname}{'count'} += 1;
					$qinfo->{'matrix'}{$rowname}{'score'} += $column;
				}
			} elsif ($qresp->{'type'} eq 'oneline') {
				add_to_hist($qinfo->{'histogram'}, $qresp->{'contents'});
			}

		} # end for $qno

	} # end for $resp


	# ...........................................
	# Generate histogram of responsers (responses)
	$survey_data->{'histogram'}{'skipped'} =
		{ map { $_ => 0 } 0..$nquestions };
	$survey_data->{'histogram'}{'date'} = {};

 RESPONSE:
	foreach my $resp (@$responses) {
		my $nskipped = scalar grep { $_->{'skipped'} } @{$resp};
		$resp->[0]{'nskipped'} = $nskipped; # !!!
		#print "$resp->[0]{'respondent number'} skipped all questions\n"
		#	if $nskipped == $survey_data{'nquestions'};
		add_to_hist($survey_data->{'histogram'}{'skipped'}, $nskipped);
		add_to_hist($survey_data->{'histogram'}{'date'}, $resp->[0]{'date'})
			if (defined $resp->[0]{'date'});
	}

}

# Generate histograms of number of skipped questions
sub make_nskipped_stat {
	my ($survey_data, $responses, $stat) = @_;

 RESPONSE:
	foreach my $resp (@$responses) {
		my $nskipped =
			defined $resp->[0]{'nskipped'} ? $resp->[0]{'nskipped'} :
			scalar grep { $_->{'skipped'} } @{$resp};

		$stat->add_data($nskipped);
	}
}

# Generate histograms of answers, or retrieve it serialized from file
sub make_or_retrieve_hist {
	my ($survey_data, $responses) = @_;
	my $what = 'survey statistics';
	local $| = 1; # autoflush

	if (! -f $statfile) {
		print STDERR "generating statistics... ";
		prepare_hist($survey_data);
		make_hist($survey_data, $responses);
		print STDERR "(done)\n";

		print STDERR "storing $what in '$statfile'... ";
		store(extract_hist($survey_data), $statfile);
		print STDERR "(done)\n";
	} else {
		print STDERR "retrieving $what from '$statfile'... ";
		my $survey_hist = retrieve($statfile);
		union_hash($survey_data, $survey_hist);
		print STDERR "(done)\n";
	}
	return wantarray ? %$survey_data : $survey_data;

}

# extract histogram part of survey data (survey info)
# to store it in $statfile
sub extract_hist {
	my $src = shift;
	my $dst = {};

	foreach my $key (keys %$src) {
		my $val = $src->{$key};

		if ($key =~ m/^(?: col | skipped | base | matrix | histogram )/x) {
			$dst->{$key} = $val;
		} elsif (ref($val) eq 'HASH') {
			$val = extract_hist($val);
			$dst->{$key} = $val if (%$val);
		}
	}

	return $dst;
}

# overlay second hash over first, deeply (recursively)
# for putting retrieved histogram info in survey data structure
sub union_hash {
	my ($base, $overlay) = @_;

	foreach my $key (keys %$overlay) {
		my $val = $overlay->{$key};

		if (ref($val) eq 'HASH'  &&
		    exists $base->{$key} &&
		    ref($base->{$key}) eq 'HASH') {
			union_hash($base->{$key}, $val);
		} else {
			$base->{$key} = $val;
		}
	}
}

# ----------------------------------------------------------------------
# Analysis of 'other, please specify' responses

# Initialize / prepare data structure for storing information
# about 'other, please specify' answers and their categorization
sub init_other {
	my ($survey_data) = @_;
	my $nquestions = $survey_data->{'nquestions'};
	my %other_repl;

 QUESTION:
	for (my $qno = 1; $qno <= $nquestions; $qno++) {
		my $qinfo = $survey_data->{"Q$qno"};
		next unless (defined $qinfo && $qinfo->{'other'});

		my $ncols = 1;
		$ncols = @{$qinfo->{'codes'}}
			if (exists $qinfo->{'codes'} && $qinfo->{'multi'});
		#print "Q$qno: col=$qinfo->{'col'}; ncols=$ncols\n";
		$other_repl{"Q$qno"} = {
			'title' => $qinfo->{'title'},
			'col' => $qinfo->{'col'} + $ncols,
			'repl' => [],
		};
	}

	return wantarray ? %other_repl : \%other_repl;
}

# Initialize structure for analyzing 'other, please specify' answers,
# or retrieve it, serialized, from $otherfile
sub init_or_retrieve_other {
	my ($survey_data) = @_;
	my %other_repl;

	my $what = "analysis of 'other' resp.";
	local $| = 1; # autoflush

	if (! -f $otherfile) {
		print STDERR "initializing data for analysis of 'other' responses... ";
		%other_repl = init_other($survey_data);
		print STDERR "(done)\n";

		print STDERR "storing $what in '$otherfile'... ";
		DumpFile($otherfile, \%other_repl);
		print STDERR "(done)\n";
	} else {
		print STDERR "retrieving $what from '$otherfile'... ";
		my @entries = LoadFile($otherfile);
		%other_repl = %{$entries[0]};
		print STDERR "(done)\n";
	}
	return wantarray ? %other_repl : \%other_repl;
}

# Analyze (create categories) 'other, please specify' answers, interactively
sub make_other_hist {
	my ($survey_data, $responses, $other_repl, $qno) = @_;

	return unless -t STDOUT; # we need terminal for interactivity

	if (!$qno || !$other_repl->{"Q$qno"}) {
		#print Dumper($other_repl);

	} else {
		#print Dumper($other_repl->{"Q$qno"});

		my $qinfo = $survey_data->{"Q$qno"};
		my $orepl = $other_repl->{"Q$qno"};

		my $term = Term::ReadLine->new('survey_parse');
		$term->addhistory($_)
			foreach (@{$qinfo->{'codes'}});
		$term->MinLine(undef); # do not include anthing in history

		my $respno = $orepl->{'last'} || 0;
		my $nresponses = scalar @$responses;
		my $new_rules = 0;
		my $other_categorized = 0;
		my $other_passed = 0;
		my $other_skipped = 0;

		# 'other, please specify' is always last code
		my $other_all = $qinfo->{'histogram'}{$qinfo->{'codes'}[-1]};

		$orepl->{'skipped'} = 0
			if (exists $orepl->{'skipped'} && !$orepl->{'last'});

		if ($respno < $nresponses) {
			print fmt_question_title($qinfo->{'title'});
			print question_type_description($qinfo)."\n\n";
		}

		my $skip_asking = 0;

	RESPONSE:
		for ( ; $respno < $nresponses; $respno++) {
			my $resp = $responses->[$respno];
			my $qresp = $resp->[$qno];

			next if ($qresp->{'skipped'});
			next unless ($qresp->{'other'});

			my $other = $qresp->{'other'};
			$other_passed++;

			print "----- [$resp->[0]{'date'}] $respno / $nresponses ".
			      "$other_passed / $other_all\n";
			if ($qresp->{'contents'}) {
				if (ref($qresp->{'contents'}) eq 'ARRAY') {
					# multiple-choice
					print ">>".$qinfo->{'codes'}[$_-1]."\n"
						foreach (@{$qresp->{'contents'}});
				} else {
					# single choice
					print "#>".$qinfo->{'codes'}[$qresp->{'contents'}-1]."\n";
				}
			}
			print "$other\n";

			my @categories =
				categorize_response($orepl->{'repl'}, $respno, $other);
			my $matched = scalar @categories;

			$other_categorized++ if $matched;
			if ($matched && !$ask_categorized) {
				update_other_hist($orepl, $qinfo, $qresp, @categories);
				next RESPONSE;
			}
			if ($matched && $ask_categorized) {
				print "c>$_\n" foreach (@categories);
			}

			my $rule = ''; # default is skip response
			$rule = ask_rules($term, $respno, $other)
				unless $skip_asking;
			if (!defined $rule) {
				$other_skipped = "all from $respno";
				last RESPONSE;
			}
			if (!$rule) {
				$other_skipped++;
				next RESPONSE;
			}
			if ($rule eq 'passthrough') {
				$other_skipped++;
				$skip_asking = 1;
				next RESPONSE;
			}
			$other_categorized++;

			push @{$orepl->{'repl'}}, $rule;
			push @categories, $rule->{'category'}
				if exists $rule->{'category'};
			$new_rules++;

			update_other_hist($orepl, $qinfo, $qresp, @categories);

		} # RESPONSE

		$orepl->{'last'} = $respno;
		$orepl->{'skipped'} ||= $other_skipped
			if ($other_skipped);
		print "Finished at response $respno of $nresponses\n"
			if ($respno < $nresponses);
		print "There were ".(scalar @{$orepl->{'repl'}})." rules ".
		      "(including $new_rules new rules)\n"
			if (scalar @{$orepl->{'repl'}});
		print "There were $other_categorized categorized out of ".
		      "$other_passed passed, out of $other_all together\n";
		print "Skipped $other_skipped responses\n"
			if $other_skipped;

		#print Dumper($orepl);

		# if there were new rules, or we updated histogram
		# if ($new_rules)
		{
			local $! = 1; # autoflush
			print STDERR "storing new rules and histogram in '$otherfile'... ";
			DumpFile($otherfile, $other_repl);
			print STDERR "(done)\n";
		}
	}
}

# given REPLACEMENTS (rules), RESPONSE_NUMBER and ANSWER,
# return list of categories ANSWER belongs to
sub categorize_response {
	my ($repl_rules, $respno, $answer) = @_;
	my @categories;

 RULE:
	for (my $i = 0; $i < @$repl_rules; $i++) {
		my $rule = $repl_rules->[$i];
		my ($regex, $val) = @$rule{'match','category'};

		if (defined $regex && $answer =~ /$regex/) {
			print "* /$regex/ matched => '$val'\n";
			push @categories, $val;

		} elsif (defined($rule->{'respno'}) &&
		         $rule->{'respno'} == $respno) {
			print "* response number [$respno] => '$val'\n";
			push @categories, $val;

		}
	} # end RULE

	return @categories;
}

# interactive, returns a rule
# return values:
#  * () / undef - skip all
#  * ''         - skip response
#  * one of the following kind of rules:
#    - { 'match' =>regexp, 'category'=>category }
#    - { 'respno'=>number, 'category'=>category }
sub ask_rules {
	my ($term, $respno, $answer) = @_;
	my ($matched, $rule);

	print "Give regexp ".
	      "(or '.' to match line,".
	      " or RET to skip reply,". # " or / to autoskip,".
	      " or ^D to skip all):\n";

 TRY: {
		do {
			$rule = $term->readline('INPUT> ');

			if (!defined $rule) {
				# ^D = EOF to skip all
				print "\n. stop analysis (skip all)\n";
				return;
			}
			if ($rule eq '') {
				# RET to skip response
				print "+ skipping '$answer'\n";
				return '';
			}
			if ($rule eq '/') {
				# RET to skip response
				print "+ skipping all answers\n";
				return 'passthrough';
			}

			if ($rule eq '.') {
				#print "+ [$respno] is '$answer'\n";
				$rule = $respno;
				$matched = 'respno';
			} elsif ($answer =~ /$rule/) {
				#print "+ /$regex/ matched '$answer'\n";
				$matched = 'match';
			} else {
				print "- /$rule/ didn't match '$answer'\n";
			}

		} while (!$matched);
	} # TRY:

	print "Give value (category):\n";
	my $val = $term->readline('INPUT> ');

	if ($val) {
		$term->addhistory($val);
		print "+ $matched: $rule => '$val'\n";
		return { $matched => $rule, 'category' => $val };
	}
	print "\n. skipping all\n";
	return;
}

# Update histogram of responses with categorization of
# 'other, please specify' answers
sub update_other_hist {
	my ($orepl, $qinfo, $response, @categories) = @_;
	return unless @categories;

	if (!exists $orepl->{'histogram'}) {
		$orepl->{'histogram'} = {};
	}
	my @answers =
		map { $qinfo->{'codes'}[$_-1] }
		grep { defined && /^\d+$/ }
		(ref($response->{'contents'}) ?
		   @{$response->{'contents'}} : $response->{'contents'});

	# rules:
	# - if category matches answer (for multiple-choice)
	#   it is an explanation, and do not add to histogram
	# - if category matches pre-defined answer, but answer was not
	#   selected, it is correction, and should be added to histogram
	# - if category is new, it should be added to histogram

	my $has_explanation = 0;
	foreach my $category (uniq @categories) {
		if (grep { $_ eq $category } @answers) {
			$has_explanation = 1;
		} else {
			add_to_hist($orepl->{'histogram'}, $category);
		}
	}
	add_to_hist($orepl->{'histogram'}, 'EXPLANATION')
		if $has_explanation;
}

# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
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

# ----------------------------------------------------------------------
# Normalize input data

sub normalize_country {
	my $country = shift;

	# strip leading and trailing whitespace
	$country =~ s/^\s+//;
	$country =~ s/\s+$//;
	# strip quotes
	$country =~ s/^'(.*)'$/$1/;

	my $original = $country;

	# strip prefix
	$country =~ s/^The //i;

	# strip extra info
	$country =~ s/, Europe\b//i;
	$country =~ s/ \(Central Europe\)//;
	$country =~ s/, but .*$//i;
	$country =~ s/, UK\b//i;
	$country =~ s/, the\b//i;
	$country =~ s/ \. shanghai\b//i;
	$country =~ s/^Kharkiv, //i;
	$country =~ s/^Flanders, //i;
	$country =~ s/^Tokyo, //i;
	$country =~ s/^Victoria, //i;
	$country =~ s/ \(Holland\)//i;
	$country =~ s/ R\.O\.C\.//i;
	$country =~ s/^\.([a-z][a-z])$/$1/i;
	$country =~ s/[!?]+$//;
	$country =~ s/\bMotherfucking\b //i;
	$country =~ s/, bitch\.//;
	$country =~ s/ \(fuck yea\)//;
	$country =~ s/^China[, ]PRC?$/China/i;
	$country =~ s/^(?:P\.R\.|PRC? )China$/China/i;
	$country =~ s/^Hong Kong.*/Hong Kong/i;
	$country =~ s/^.* - Brazil$/Brazil/i;
	$country =~ s/^just south of //i;

	# correct (or normalize) spelling
	$country =~ s/\brep\.(?:\b|$)/Republic/i;
	$country =~ s/\b(?:Amerrica|Ameircia)\b/America/i;
	$country =~ s/\bBrasil\b/Brazil/i;
	$country =~ s/\bBrazul\b/Brazil/i;
	$country =~ s/\bChezh Republic\b/Czech Republic/i;
	$country =~ s/\bCzechia\b/Czech Republic/i;
	$country =~ s/^Czech$/Czech Republic/i;
	$country =~ s/\bChinese\b/China/i;
	$country =~ s/\bChinease\b/China/i;
	$country =~ s/\bEnglang\b/England/i;
	$country =~ s/\bEngkand\b/England/i;
	$country =~ s/\bFinnland\b/Finland/i;
	$country =~ s/\bFrench\b/France/i;
	$country =~ s/\bFederal Republic of Germany\b/Germany/i;
	$country =~ s/\bGerman[u]?\b/Germany/i;
	$country =~ s/\bGernany\b/Germany/i;
	$country =~ s/\bKyrgyzstab\b/Kyrgyzstan/i;
	$country =~ s/\bLithuani\b/Lithuania/i;
	$country =~ s/\bMacedoni\b/Macedonia/i;
	$country =~ s/\bM.*xico\b/Mexico/i;
	$country =~ s/\bMolodva\b/Moldova/i;
	$country =~ s/\bSapin\b/Spain/i;
	#$country =~ s/^Serbia$/Serbia and Montenegro/i; # outdated info
	#$country =~ s/^Montenegro$/Serbia and Montenegro/i; # outdated info (?)
	$country =~ s/\b(?:Swiss|Sitzerland|Swtzerland)\b/Switzerland/i;
	$country =~ s/\bSwedeb\b/Sweden/i;
	$country =~ s/\bUnited Kindom\b/United Kingdom/i;
	$country =~ s/\bViet Nam\b/Vietnam/i;
	$country =~ s/\bZealandd\b/Zealand/i;
	$country =~ s/\bUSUnited States\b/United States/i;
	$country =~ s/\bUni?ted? States?\b/United States/i;
	# many names of United States of America
	$country =~ s/^U\.S(?:|\.|\.A|\.A\.)$/USA/;
	$country =~ s/^U\. S\. A\.$/USA/;
	$country =~ s/^US of A$/USA/;
	$country =~ s/^USofA$/USA/;
	$country =~ s/^US&A$/USA/;
	$country =~ s/^YS$/USA/;
	# many names of United Kingdom
	$country =~ s/^Britain$/United Kingdom/i;
	$country =~ s/^British$/United Kingdom/i;

	# local name to English
	$country =~ s/\bDeutschland\b/Germany/i;

	# other fixes and expansions
	$country =~ s/^PRC$/China/i; # People's Republic of China
	$country =~ s/^U[Kk]$/United Kingdom/;
	$country =~ s/\bUK\b/United Kingdom/i;
	$country =~ s/ \(Rep\. of\)/, Republic of/;
	$country =~ s/\b(?:Unites|Unitered)\b/United/i;
	$country =~ s/\bStatus\b/States/i;
	$country =~ s/\bState2\b/States/i;
	$country =~ s/^Russian$/Russian Federation/i;
	$country =~ s/^America$/USA/i;

	# fix accidental fuzzy matches
	$country =~ s/^Mike$/unknown/i;

	# province, state or city to country
	$country =~ s/^.*(?:England|Scotland|Wales).*$/United Kingdom/i;
	$country =~ s/^Northern Ireland$/United Kingdom/i;
	$country =~ s/\bTexas\b/USA/i;
	$country =~ s/\bCalgary\b/Canada/i;
	$country =~ s/\bAdelaide\b/Australia/i;
	$country =~ s/\bAmsterdam\b/Netherlands/i;
	$country =~ s/\bBasque country\b/Spain/i;
	$country =~ s/\bBeijing\b/China/i;
	$country =~ s/\bBerlin\b/Germany/i;
	$country =~ s/\bCatalonia\b/Spain/i;
	$country =~ s/^Catalunya \/ Spain$/Spain/i;
	$country =~ s/\bOttawa\b/Canada/i;
	$country =~ s/\bReunion Island\b/France/i;

	# choose only one country if there are more than one provided
	$country =~ s/ <-> .*$//;
	#$country =~ s/ and .*$//; # false positives in country names
	$country =~ s!/.*$!!;
	$country =~ s!, .*$!!;

	# convert to code and back to country, normalizing country name
	# (or going from code to country)
	my $code = country2code($country) || $country;
	$country = code2country($code)    || $country;

	unless (scalar grep { $_ eq $country } @country_names) {
		# 2/3 of Schwartzian transform
		my @countries_sorted =
			sort { $a->[1] <=> $b->[1] }
			map  { [$_, distance($_, $country)] }
			@country_names;

		if ($countries_sorted[0][1] <= 2) {
			$country = $countries_sorted[0][0];
		} else {
			#$country .= " ($countries_sorted[0][0],$countries_sorted[0][1])";
			$country .= '?';
			if ($original ne $country) {
				$country .= " [$original]";
			}
		}
	}

	return ucfirst($country);
}

sub normalize_age {
	my $age = shift;

	# extract
	unless ($age =~ s/^[^0-9]*([0-9]+).*$/$1/) {
		return 'NaN';
	}

	#return $age;

	if ($age < 18) {
		return ' < 18';
	} elsif ($age < 22) {
		return '18-21';
	} elsif ($age < 26) {
		return '22-25';
	} elsif ($age < 31) {
		return '26-30';
	} elsif ($age < 41) {
		return '31-40';
	} elsif ($age < 51) {
		return '41-50';
	} elsif ($age < 76) {
		return '51-75';
	} else {
		return '76+  ';
	}
}

# ......................................................................

sub country2continent {
	my $country_name = shift;

	#return "Unknown"
	#	unless (scalar grep { $_ eq $country_name } @country_names);

	# silence warnings for nonexistent countries (invalid names)
	no warnings;
	local $SIG{__WARN__} = sub {};

	my $country = Locale::Object::Country->new(
		name => $country_name
	);
	return $country->continent->name
		if ($country);
	return "Unknown";
}

# syntactic sugar for iterators, from "Higher Order Perl"
sub NEXTVAL { return $_[0]->() }
sub Iterator (&) { return $_[0] }

# start: response_number, time, delta_time
# step: time += delta_time, response_number[time] >= time
sub iresptime {
	my ($responses, $respno, $time, $delta) = @_;
	#$time  = ParseDate($time);
	#$delta = ParseDateDelta($delta);

	return Iterator {
		while (defined $responses->[$respno] &&
		       Date_Cmp($responses->[$respno][0]{'parsed_date'}, $time) < 0) {
			$respno++;
		}
		$time = DateCalc($time,$delta);
		return defined $responses->[$respno] ? $respno : undef;
	}
}

sub i2resptime {
	my ($responses, $respno, $time, $delta) = @_;
	#$time  = ParseDate($time);
	#$delta = ParseDateDelta($delta);

	if (!defined $time) {
		$time = $responses->[0][0]{'parsed_date'};
	}

	my $tlo = DateCalc($time, "-12 hours");
	my $thi = DateCalc($time, "+12 hours");
	my $itlo = iresptime($responses, $respno, $tlo, $delta);
	my $ithi = iresptime($responses, $respno, $thi, $delta);

	return Iterator {
		my ($lo, $hi) = (NEXTVAL($itlo), NEXTVAL($ithi));
		return
			unless (defined $lo || defined $hi);
		return ($lo, $hi);
	}
}

sub ifloating_resp_per_day_avg {
	my ($responses, $respno, $time, $delta) = @_;
	my $iter = i2resptime(@_);
	my $nresponses = scalar @$responses;

	if (!defined $time) {
		$time = $responses->[0][0]{'parsed_date'};
	}

	return Iterator {
		my ($lo, $hi) = NEXTVAL($iter);
		return
			unless (defined $lo || defined $hi);
		$lo = 0 unless defined $lo;
		$hi = $nresponses-1 unless defined $hi;

		my ($frac_lo, $frac_hi) = (0.0, 0.0);
		my ($t1, $t2);
		if (defined $lo && $lo-1 >= 0) {
			$t1 = $responses->[$lo-1][0]{'parsed_date'};
			$t2 = $responses->[$lo  ][0]{'parsed_date'};
			$frac_lo = time_duration_frac($t1, $t2, DateCalc($time, "-12 hours"));
			$frac_lo = defined $frac_lo ? 1.0 - $frac_lo : 0.0;
		}
		if (defined $hi && $hi-1 >= 0) {
			$t1 = $responses->[$hi-1][0]{'parsed_date'};
			$t2 = $responses->[$hi  ][0]{'parsed_date'};
			$frac_hi = time_duration_frac($t1, $t2, DateCalc($time, "+12 hours"));
			$frac_hi = defined $frac_hi ? 1.0 - $frac_hi : 0.0;
		}

		my @result = ($time, $hi-$lo, $hi-$lo + $frac_lo - $frac_hi);
		$time = DateCalc($time,$delta);

		return @result;
	}
}

# find alpha such that MID = alpha*[LO, HI]
sub time_duration_frac {
	my ($lo, $hi, $mid) = map { UnixDate($_, '%s') } @_;

	# MID = alpha*[LO, HI]  <=>  MID = LO + alpha*(HI - LO)
	# solution: alpha = (mid - lo)/(hi - lo)
	return ($mid - $lo)/($hi - $lo);
}

# ----------------------------------------------------------------------
# Auxiliary functions for formatting output
sub fmt_matrix_maxlen {
	my $columns = shift;

	return max(
		map(length, @$columns),
		$format eq 'wiki' ?
			0 :
			length('9999 (99%)')
	);
}

sub matrix_colors {
	my $columns = shift;
	my $ncolors = scalar @$columns;
	my (%colors, $skip_first);

	if (is_NA($columns->[0])) {
		$colors{$columns->[0]} = '#606060' ; # gray (lighter version is '#a6a6a6')
		$skip_first = 1;
		$ncolors--;
	}

	for (my $i = 0; $i < $ncolors; $i++) {
		$colors{$columns->[$i + !!$skip_first]} =
			get_color_from_gradient($i / ($ncolors-1));
	}

	return %colors;
}

sub is_NA {
	my $answer = shift;

	return ($answer eq "don't care" || $answer eq 'never used');
}

# based on C Source for the "standard" cold-to-hot colour ramp
# from http://local.wasp.uwa.edu.au/~pbourke/texture_colour/colourramp/
sub get_color_from_gradient {
	my $fraction = shift;

	$fraction = 0.0 if ($fraction < 0.0);
	$fraction = 1.0 if ($fraction > 1.0);

	my %rgb_color = ( R => 1.0, G => 1.0, B => 1.0 );
	if ($fraction < 0.25) {
		$rgb_color{R} = 0.0;
		$rgb_color{G} = 4.0*$fraction;
	} elsif ($fraction < 0.5) {
		$rgb_color{R} = 0.0;
		$rgb_color{B} = 1.0 - 4*($fraction - 0.25);
	} elsif ($fraction < 0.75) {
		$rgb_color{R} = 4.0*($fraction - 0.5);
		$rgb_color{B} = 0.0;
	} else { # $fraction <= 1.0
		$rgb_color{G} = 1.0 - 4*($fraction - 0.75);
		$rgb_color{B} = 0.0;
	}

	return rgb_to_hex(@rgb_color{qw(R G B)});
}

sub rgb_to_hex {
	my @rgb = @_;
	my $result = '#';
	foreach my $c (@rgb) {
		$result .= sprintf('%02x', $c*255);
	}
	return $result;
}

# ----------------------------------------------------------------------
# Format output

sub fmt_section_header {
	my $title = shift;

	if ($format eq 'wiki') {
		return "\n\n== $title ==\n";
	}
	return "\n\n$title\n" .
	       '~' x length($title) . "\n";
}

sub fmt_question_title {
	my $title = shift;

	if ($format eq 'wiki') {
		if ($title =~ m/^([^\n]*)\n(.*)$/s) {
			return "\n=== $1 ===\n'''$2'''\n\n";
		}
		return "\n=== $title ===\n";
	}
	if ($title =~ m/\n/) {
		return "\n$title\n";
	} else {
		return "\n".wrap('', '    ', $title)."\n";
	}
}

sub fmt_todo {
	my @lines = @_;
	my $result = '';

	$result .= "\n";
	foreach my $line (@lines) {
		$result .= "  $line\n";
	}
	$result .= "\n";

	return $result;
}

sub fmt_th_percent {
	my $title = shift || "Answer";

	if ($format eq 'wiki') {
		my $style = defined($rowstyle{'th'}) ?
		            " style=\"$rowstyle{'th'}\"" : '';
		my $graph = !$show_graph ? '' :
		            qq(\n! style="width: $graph_width$graph_units;" |);

		return "{|$tablestyle\n|-$style\n" .
		       sprintf("! %-${width}s !! %5s !! %-5s $graph\n",
		               $title, "Count", "Perc.");
	}

	return sprintf("  %-${width}s | %5s | %-5s\n", $title, "Count", "Perc.") .
	               "  " . ('-' x ($width + 17)) . "\n";
}

sub fmt_th_matrix {
	my ($title, $columns, $show_avg) = @_;
	$title ||= "Answer";

	my $maxlen = fmt_matrix_maxlen($columns);
	my $th;

	if ($format eq 'wiki') {
		#my $style = join(' ', grep { defined $_ && $_ ne '' }
		#                 $tablestyle, $rowstyle{'th'});
		my $style = defined($rowstyle{'th'}) ?
		            " style=\"$rowstyle{'th'}\"" : '';
		my %colors = $show_graph ? matrix_colors($columns) : ();

		foreach my $col (@$columns) {
			my $colstyle = '';
			$colstyle = qq(style="background-color: $colors{$col};" )
				if $show_graph;
			$th .= qq(! colspan="2" $colstyle| $col \n);
		}
		$th .= "! Avg. / Count \n" if ($show_avg);
		$th .= qq(! style="width: $graph_width$graph_units;" | &nbsp;\n)
			if ($show_graph);
		return "{|$tablestyle\n" .
		       sprintf("|-$style\n! %s\n$th",
		               $title);
	}

	my @fmtcol = map { sprintf("%-${maxlen}s", $_) } @$columns;

	$th = join('|', map { " $_ " } @fmtcol);
	$th .= "|| Avg." if ($show_avg);
	$th = sprintf("%-${width}s |$th\n", $title);
	return "  $th".
	       "  " . ('-' x (length($th)-1)) . "\n";
}

sub fmt_row_percent {
	my ($name, $count, $perc, $base) = @_;

	if ($format eq 'wiki') {
		# CamelCase -> !CamelCase to avoid accidental wiki links
		#$name =~ s/\b([A-Z][a-z]+[A-Z][a-z]+)\b/!$1/g;
		my $style = defined($rowstyle{'row'}) ?
		            " style=\"$rowstyle{'row'}\"" : '';
		my $graph = !$show_graph ? '' :
		            sprintf qq(\n| <div style="width: %3.0f%s; background-color: %s;">&nbsp;</div>),
		                    1.0*$graph_width*$count/$base, $graph_units, $graph_color;

		return sprintf("|-%s\n| %-${width}s || %5d || %4.1f%% $graph\n",
		               $style, $name, $count, $perc);
	}

	return sprintf("  %-${width}s | %-5d | %4.1f%%\n",
	               $name, $count, $perc);
}

sub fmt_row_matrix {
	my ($name, $hist, $base, $columns, $score, $count) = @_;

	# CamelCase -> !CamelCase to avoid accidental wiki links
	#$name =~ s/\b([A-Z][a-z]+[A-Z][a-z]+)\b/!$1/g
	#	if ($format eq 'wiki');

	# format row name (answer)
	my $result;
	if ($format eq 'wiki') {
		my $style = defined($rowstyle{'row'}) ?
		            " style=\"$rowstyle{'row'}\"" : '';
		$result = sprintf("|-%s\n| %-${width}s", $style, $name);
	} else {
		$result = sprintf("  %-${width}s", $name);
	}

	my $maxlen = fmt_matrix_maxlen($columns);
	my ($sep, $doublesep);
	if ($format eq 'wiki') {
		$sep = "\n";
		$doublesep = "\n| ";
	} else {
		$sep = ' | ';
		$doublesep = ' || ';
	}
	my $graph  = $show_graph ? '' : undef;
	my %colors = $show_graph ? matrix_colors($columns) : ();
	for (my $i = 0; $i < @$hist; $i++) {
		my $entry = $hist->[$i];
		my $perc = 100.0*$entry / $base;
		my $col;
		if ($format eq 'wiki') {
			$col = sprintf("| %-5d || %4.1f%% ", $entry, $perc);
			if ($show_graph) {
				$graph .= sprintf qq(\n<div style="width: %3d%s; background-color: %s; float: left;">&nbsp;</div>),
				          1.0*$graph_width*$entry/$base, $graph_units, $colors{$columns->[$i]};
			}
		} else {
			$col = sprintf("%4d (%.0f%%)", $entry, $perc);
			$col = sprintf("%-${maxlen}s", $col);
		}
		$result .= "$sep$col";
	}
	if ($score) {
		$result .= $doublesep . sprintf("%3.1f", $score);
		$result .= ' ('.scalar(@$hist).')'
			if ($format eq 'wiki');
		$result .= ' / ' . sprintf("%-4d", $count)
			if (defined $count && $format eq 'wiki');
		# or alternatively
		#$result .= ' / ' . sprintf("%-4d", sum(@$hist))
		#	if ($format eq 'wiki');
	}
	if ($format eq 'wiki' && $show_graph) {
		$result .= "\n| $graph";
	}

	return $result . "\n";
}

sub fmt_footer_percent {
	my ($base, $responses) = @_;

	if (!defined($base) && $format ne 'wiki') {
		return "  " . ('-' x ($width + 17)) . "\n";
	}

	if ($format eq 'wiki') {
		return "|}\n\n" unless defined($base);

		my $style = defined($rowstyle{'footer'}) ?
		            " style=\"$rowstyle{'footer'}\"" : '';
		my $graph = !$show_graph ? '' : '||';

		return sprintf("|-%s\n| %-${width}s \n| colspan=\"2\" | %5d / %-5d $graph\n",
		               $style, "Base", $base, $responses) .
		       "|}\n\n";
	}

	return "  " . ('-' x ($width + 17)) . "\n" .
	       sprintf("  %-${width}s | %5d / %-5d\n", "Base",
	               $base, $responses) .
	       "\n";
}

sub fmt_footer_matrix {
	my ($base, $responses, $columns, $show_avg) = @_;
	my $ncol = scalar @$columns;
	my $maxlen = fmt_matrix_maxlen($columns);
	my ($sep, $doublesep);
	if ($format eq 'wiki') {
		$sep = "\n";
		$doublesep = "\n| ";
	} else {
		$sep = ' | ';
		$doublesep = ' || ';
	}
	my ($seplen, $doubleseplen) = map(length, $sep, $doublesep);
	my $table_width =
		$width +                   # code
		$ncol*($seplen + $maxlen); # columns
	$table_width +=
		($doubleseplen + length('9.9'))*(!!$show_avg);

	my $result = '';
	if ($format ne 'wiki') {
		$result .= '  '.('-' x $table_width)."-\n";
	}
	if ($base) {
		if ($format eq 'wiki') {
			my $style = defined($rowstyle{'footer'}) ?
			            " style=\"$rowstyle{'footer'}\"" : '';
			$result .= sprintf("|-%s\n| %-${width}s \n|colspan=\"%d\" | %5d / %-5d \n",
			                   $style, "Base", $ncol*2 + 1*!!$show_avg,
			                   $base, $responses);
			$result .= "| \n" if ($show_graph);
		} else {
			$result .= sprintf("  %-${width}s | %5d / %-5d\n", "Base",
			                   $base, $responses);
		}
	}
	if ($format eq 'wiki') {
		$result .= "|}\n\n";
	}
	return $result;
}

# . . . . . . . . . . . . . . . . . . . . . . . . . . . 

# return description of a type of given question
sub question_type_description {
	my $q = shift;

	if ($q->{'freeform'}) {
		return '(free-form essay)';
	} elsif (exists $q->{'columns'}) {
		return '(matrix)';
	} elsif (exists $q->{'codes'}) {
		my $str = '';
		if ($q->{'multi'}) {
			$str  = '(multiple choice';
		} else {
			$str  = '(single choice';
		}
		if ($q->{'other'}) {
			$str .= ', with other';
		}
		$str .= ')';
		return $str;
	} elsif (ref($q->{'hist'}) eq 'CODE') {
		return '(tabularized free-form single line)';
	} else {
		return '(free-form single line)';
	}
}

# ======================================================================
# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# DATA

# Read information about survey structure from $survinfo_file
sub read_survinfo {
	my $survinfo_file = shift;

	-f $survinfo_file
		or die "File with questions definitions '$survinfo_file' does not exist: $!";

	local $| = 1; # autoflush
	print STDERR "retrieving survey structure from '$survinfo_file'... ";
	my $survinfo = LoadFile($survinfo_file);
	print STDERR "(done)\n";

	return @$survinfo;
}

# Extract information about sections from survey info structure
sub make_sections {
	my $survinfo = shift;
	my @sections = ();

	for (my $i = 0, my $qno = 0; $i < @$survinfo; $i += 2) {
		my ($key, $val) = @{$survinfo}[$i,$i+1];
		if ($key =~ m/^(Q(\d+))$/) {
			$qno = $2;
			next;
		}
		next unless ($key =~ m/^(S(\d+))$/);
		push @sections, {'title' => $val->{'section_title'}, 'start' => $qno+1};
	}

	return @sections;
}

# Delete (extracted) information about sections from survey info structure
sub delete_sections {
	my $survhash = shift;

	foreach my $key (keys %$survhash) {
		delete $survhash->{$key}
			if ($key =~ m/^S\d+$/);
	}
}

# Add code references to survey structure infor retrieved from file
# (storing data references in data serialization file is not good idea)
sub add_coderefs {
	my $survinfo = shift;
	my %surv_coderef = (
		'age' => {
			'hist' => \&normalize_age,
			'post' => \&post_print_age_hist,
		},
		'country' => {
			'hist' => \&normalize_country,
			'post' => \&post_print_continents_stats,
		},
		'survey_announcement' => {
			'post' => \&post_print_date_divided_announce_hist,
		},
	);

	for (my $i = 0; $i < @$survinfo; $i += 2) {
		my ($key, $value) = @{$survinfo}[$i, $i+1];
		next unless (ref($value) eq 'HASH' && $value->{'type'});

		my $type = $value->{'type'};
		if (exists $surv_coderef{$type}) {
			$survinfo->[$i+1] = {
				%$value,
				%{$surv_coderef{$type}}
			};
		}
	}
}

# ======================================================================
# ----------------------------------------------------------------------

# format time delta, in days hours minutes seconds format
sub fmt_reltime {
	my $seconds = shift;

	if ($seconds < 60) {
		return Delta_Format($seconds, 0, '%sh s');
	} elsif ($seconds < 60*60) {
		return Delta_Format($seconds, 0, '%mh m %sv s');
	} elsif ($seconds < 60*60*24) {
		return Delta_Format($seconds, 0, '%hh h %mv m %sv s');
	} else {
		return Delta_Format($seconds, 0, '%dh d %hv h %mv m %sv s');
	}
}

# print histogram of date of response,
# in format suitable for datafile e.g for gnuplot
sub print_date_hist {
	my ($survey_data, $responses) = @_;


	print "# 1:date 2:'12:00:00'(noon)  3:responses\n";
	my $num = 0;
 DATE:
	foreach my $date (sort keys %{$survey_data->{'histogram'}{'date'}}) {
		print "$date 12:00:00  $survey_data{'histogram'}{'date'}{$date}\n";
		$num += $survey_data{'histogram'}{'date'}{$date};
	}
	print "# responses with date field: $num\n\n\n";


	print "# 1:date 2:time  3:avg_resp_per_day 4:avg_resp_per_day(fract)\n";
	my $dt = ParseDateDelta("+1 hour");
	my $iter = ifloating_resp_per_day_avg($responses, 0, undef, $dt);
	my $date_fmt = '%Y-%m-%d %H:%M:%S';
	while (my ($time, $count, $count_adj) = NEXTVAL($iter)) {
		last unless (defined $time && defined $count);
		print UnixDate($time, $date_fmt)."  $count $count_adj\n";
	}
}

# print histogram of number of responses per question,
# in format suitable for datafile e.g for gnuplot
sub print_resp_hist {
	my ($survey_data, $nresponses) = @_;

	if ($format eq 'wiki') {
		print fmt_th_percent('Question');
	} else {
		print "# 1:question_number 2:responses\n";
	}

	$width = max
		map { $_->{'title'} =~ /\A(.*?)$/m; length($1) }
		map { $survey_data{"Q$_"} }
		1..$survey_data->{'nquestions'};
	$width = max($width, $min_width);

	my $nextsect = 0;
	my $c = $show_graph ? 4 : 3; # number of columns in table
 QUESTION:
	for (my $qno = 1; $qno <= $survey_data->{'nquestions'}; $qno++) {

		# section header
		if (exists $sections[$nextsect] &&
		    $sections[$nextsect]{'start'} <= $qno) {
			my $section_title = $sections[$nextsect]{'title'};
			$section_title =~ s/\n.*$//; # only first line

			if ($format eq 'wiki') {
				print "|-\n";
				print qq(| colspan="$c" style="font-size: 80%; text-align: center" |).
				      qq($section_title\n);
			} else {
				print "#$section_title\n";
			}

			$nextsect++;
		}


		my $q = $survey_data{"Q$qno"};
		next unless (defined $q);

		if ($format eq 'wiki') {
			my $question_title = $q->{'title'};
			$question_title =~ s/\n.*$//; # only first line
			print fmt_row_percent($question_title,
			                      $q->{'base'}, 100.0*$q->{'base'}/$nresponses,
			                      $nresponses);
		} else {
			printf("%-2d %d\n", $qno, $q->{'base'});
		}
	}

	if ($format eq 'wiki') {
		print "|}\n"; # close table
	}
	print "\n";
}

# Print some base statistics
sub print_base_stats {
	my ($survey_data, $responses) = @_;

	my $stat = Statistics::Descriptive::Sparse->new();
	#my $stat = Statistics::Descriptive::Full->new();

	$stat->add_data(
		map { $survey_data->{$_}{'base'} }
		sort { substr($a,1) <=> substr($b,1) }
		grep { $_ =~ m/^Q\d+$/ }
		sort keys %$survey_data
	);
	print "\n'base' (number of replies per question)\n".
	      "- count:  ".$stat->count()." (questions)\n".
	      "- mean:   ".$stat->mean()." (responders)\n".
	      "- stddev: ".$stat->standard_deviation()."\n".
	      "- max:    ".$stat->max()." for question ".($stat->maxdex()+1)."\n".
	      "- min:    ".$stat->min()." for question ".($stat->mindex()+1)."\n";
	$Text::Wrap::columns = 80;
	print wrap('', '    ', 
	           $survey_data->{'Q'.($stat->maxdex()+1)}{'title'} . "\n");
	print wrap('', '    ', 
	           $survey_data->{'Q'.($stat->mindex()+1)}{'title'} . "\n");
	$stat->clear();

	$stat->add_data(
		map { $survey_data->{$_}{'skipped'} }
		sort { substr($a,1) <=> substr($b,1) }
		grep { $_ =~ m/^Q\d+$/ }
		sort keys %$survey_data
	);
	print "\n'skipped' (number of people who skipped question)\n".
	      "- count:  ".$stat->count()." (questions)\n".
	      "- mean:   ".$stat->mean()." (responders)\n".
	      "- stddev: ".$stat->standard_deviation()."\n\n";
	$stat->clear();

	make_nskipped_stat($survey_data, $responses, $stat);
	print "\nresponses skipped by user\n".
	      "- count:  ".$stat->count()." (responders / users)\n".
	      "- mean:   ".$stat->mean()." (questions skipped)\n".
	      "- stddev: ".$stat->standard_deviation()."\n".
	      "- max:    ".$stat->max().
	        " ($survey_data->{'nquestions'} means no question answered)\n".
	      "- min:    ".$stat->min().
	        " (0 means all questions answered)\n\n";
	$stat->clear();

	for (my $respno = 1; $respno < @$responses; $respno++) {
		my $date_prev = $responses->[$respno-1][0]{'parsed_date'};
		my $date_curr = $responses->[$respno  ][0]{'parsed_date'};
		my $delta = DateCalc($date_prev, $date_curr);
		my $delta_secs = Delta_Format($delta, 0, '%sh');
		$stat->add_data($delta_secs);
	}
	print "\ndate of response stats\n".
	      "- count:  ".$stat->count()." (deltas)\n".
	      "- min dist: ".fmt_reltime($stat->min()).
	      " = ".$stat->min()." seconds\n".
	      "- max dist: ".fmt_reltime($stat->max()).
	      " = ".$stat->max()." seconds\n".
	      "- avg dist: ".$stat->mean().
	      " +/- ".$stat->standard_deviation()." seconds\n".
	      "            ".fmt_reltime(int($stat->mean()+0.5)).
	      " +/- ".fmt_reltime(int($stat->standard_deviation()+0.5))."\n\n";
	$stat->clear();
}

# Print results (statistics) for given question
sub print_question_stats {
	my ($q, $nresponses, $sort) = @_;

	print fmt_question_title($q->{'title'}).
	      ($format eq 'wiki' ? "''" : "").
	      question_type_description($q).
	      ($format eq 'wiki' ? "''" : "").
	      "\n";

	# if there are no histogram
	if (!exists $q->{'histogram'}) {
		print fmt_todo('TO TABULARIZE',
		               "$q->{'base'} / $nresponses non-empty responses");
		return;
	}

	# find width of widest element
	$width = $min_width;
	if (exists $q->{'codes'}) {
		$width = max(map(length, @{$q->{'codes'}}));
	} else {
		$width = max(map(length, keys %{$q->{'histogram'}}));
	}
	$width = $min_width if ($width < $min_width);

	# table header
	print "\n";
	if (exists $q->{'columns'}) {
		print fmt_th_matrix($q->{'colname'}, $q->{'columns'},
		                    exists $q->{'matrix'});
	} else {
		print fmt_th_percent($q->{'colname'});
	}

	# table contents
	my @rows = ();
	if (exists $q->{'codes'}) {
		@rows = @{$q->{'codes'}};
	} else {
		@rows = sort keys %{$q->{'histogram'}};
	}

	if ($sort) {
		if (!exists $q->{'columns'}) {

			@rows =
				map { $_->[0] }
				sort { $b->[1] <=> $a->[1] } # descending
				map { [ $_, $q->{'histogram'}{$_} ] }
				@rows;
		} else {

			# matrix form questions have to be sorted by specific column

			# ...
		}
	}

	# table body
	my $base = $q->{'base'};
	foreach my $row (@rows) {
		if (exists $q->{'columns'}) {
			my ($score, $count);
			if (exists $q->{'matrix'} && exists $q->{'matrix'}{$row} &&
			    defined $q->{'matrix'}{$row}{'score'} &&
			    defined $q->{'matrix'}{$row}{'count'} &&
			    $q->{'matrix'}{$row}{'count'} != 0) {
				$score = $q->{'matrix'}{$row}{'score'}
				       / $q->{'matrix'}{$row}{'count'};
				$count = $q->{'matrix'}{$row}{'count'};
			}
			print fmt_row_matrix($row, $q->{'histogram'}{$row}, $base,
			                     $q->{'columns'}, $score, $count);
		} else {
			print fmt_row_percent($row, $q->{'histogram'}{$row},
			                      100.0*$q->{'histogram'}{$row} / $base, $base);
		}
	}

	# table footer
	if (exists $q->{'columns'}) {
		print fmt_footer_matrix($q->{'base'}, $nresponses,
		                        $q->{'columns'}, exists $q->{'matrix'});
	} else {
		print fmt_footer_percent($q->{'base'}, $nresponses);
	}
}

sub print_extra_info {
	my $q = shift;

	if ($q->{'description'}) {
		printf "\n";
		#print "~-\n" if ($format eq 'wiki'); # start of smaller
		if ($format eq 'wiki') {
			print "'''Description:'''<BR>\n";
		} else {
			print "Description:\n".
			      "~~~~~~~~~~~~\n\n";
		}
		print $q->{'description'};
		#print "-~"   if ($format eq 'wiki'); # end of smaller
		printf "\n";
		#if ($format eq 'wiki') {
		#	print "'''Analysis:'''<BR>\n";
		#} else {
		#	print "Analysis:\n".
		#	      "~~~~~~~~~\n\n";
		#}
	}
}

sub print_other_stats {
	my ($question_info, $other_info, $nresponses, $sort) = @_;

	# return early if there iare no 'other' responses parsed
	return unless exists $other_info->{'last'};

	# find width of widest element, starting with $width from the
	# histogram of answers
	$width = max($min_width, $width,
		map(length, keys %{$other_info->{'histogram'}}));

	# table header; 'other, please specify' answer can be present only
	# for single-choice and multiple-choice questions
	print "\n";
	print fmt_th_percent($question_info->{'colname'});

	# sorting is not implemented yet (!!!)

	# table body
	my $base = $question_info->{'base'};
	my $other_name = $question_info->{'codes'}[-1];
	my $nother = $question_info->{'histogram'}{$other_name};

	# sorting: first display corrections, i.e. categories which are
	# pre-defined answers, then 'explanation' meta-category, then
	# categories sorted aplhabetically (or by number of answers)
	my %cat_used = map { $_ => 0 } keys %{$other_info->{'histogram'}};
	my @categories = ();
	push @categories,
		grep { exists $other_info->{'histogram'}{$_} and $cat_used{$_} = 1 }
		@{$question_info->{'codes'}};
	push @categories, 'EXPLANATION'
		if exists $other_info->{'histogram'}{'EXPLANATION'};
	push @categories,
		grep { $cat_used{$_} == 0 && $_ ne 'EXPLANATION' }
		sort keys %{$other_info->{'histogram'}};

	foreach my $cat (@categories) {
		my $n = $other_info->{'histogram'}{$cat};
		print fmt_row_percent($cat, $n, 100.0*$n / $base, $base);
	}

	# footer
	print fmt_footer_percent($base, $nresponses);

	# extra information
	print "Last 'other' response parsed: $other_info->{'last'} / $nresponses\n"
		if ($other_info->{'last'} < $nresponses);
	print "'Other' responses skipped: $other_info->{'skipped'} / $nother\n"
		if ($other_info->{'skipped'});
}

sub print_original_responses {
	my ($survey_data, $responses, $qno) = @_;

	foreach my $resp (@$responses) {
		my $qresp = $resp->[$qno];
		next unless defined $qresp;

		print "-\n".
		      (defined $qresp->{'original'} ?
		               $qresp->{'original'} :
		               $qresp->{'contents'}).
		      "\n";
	}
}

# ......................................................................

sub post_print_continents_stats {
	my ($survey_data, $responses, $qno, $nresponses, $sort) = @_;
	my $q = $survey_data->{"Q$qno"};
	my %continent_hist = (
		# http://www.worldatlas.com/cntycont.htm
		'Africa' => 0,
		'Asia' => 0,
		'Europe' => 0,
		'North America' => 0,
		'South America' => 0,
		'Oceania' => 0,
		# catch for malformed country names
		'Unknown' => 0,
	);

	for my $country (keys %{$q->{'histogram'}}) {
		my $continent = country2continent($country);
		next unless exists $continent_hist{$continent};

		$continent_hist{$continent} += $q->{'histogram'}{$country};
	}

	print fmt_th_percent('Continent');
	my $base = $q->{'base'};
	for my $continent (sort keys %continent_hist) {
		my $data = $continent_hist{$continent};
		print fmt_row_percent($continent, $data, 100.0*$data / $base, $base);
	}
}

sub post_print_age_hist {
	my ($survey_data, $responses, $qno, $nresponses, $sort) = @_;
	my $q = $survey_data->{"Q$qno"};
	my %age_hist;

 RESPONSE:
	foreach my $r (@$responses) {
		my $age = $r->[$qno]{'original'};
		next RESPONSE
			unless (defined $age && $age =~ m/(\d+)/);
		$age = $1;

		if (exists $age_hist{$age}) {
			$age_hist{$age}++;
		} else {
			$age_hist{$age} = 1;
		}
	}

	print "# 1:age 2:count\n";
	my @ages = sort { $a <=> $b } keys %age_hist;
	my ($min_age, $max_age) = (0, min($ages[-1],99));
	for (my $age = $min_age; $age <= $max_age; $age++) {
		my $count = $age_hist{$age} || 0;
		printf("%-2d %d\n", $age, $count);
	}
	print "# min=$ages[0]; max=$ages[-1]\n";
}

# print histogram of number of responses per date,
# divided per survey announcement (how heard about survey)
sub post_print_date_divided_announce_hist {
	my ($survey_data, $responses, $qno, $nresponses, $sort) = @_;
	my $q = $survey_data->{"Q$qno"};
	my %dates_hist;
	my %heard_hist;

 RESPONSE:
	foreach my $r (@$responses) {
		my $date  = $r->[0]{'date'};
		my $cont  = $r->[$qno]{'contents'};
		my $heard = 'unknown';
		if (defined $cont && $cont =~ /^\d+$/ &&
		    exists $q->{'codes'}[$cont-1]) {
			$heard = $q->{'codes'}[$cont-1];
		}
		$dates_hist{$date} ||= {};
		add_to_hist($dates_hist{$date}, $heard);
		add_to_hist(\%heard_hist, $heard);
	}


	print "\n";
	print "# 1:date 2:'12:00:00'(noon)\n";
	for (my $i = 0; $i < @{$q->{'codes'}}; $i++) {
		print "#  ".($i+3).":$q->{'codes'}[$i]\n";
	}
	print "#  ".(@{$q->{'codes'}}+3).":unknown\n";

 DATE:
	foreach my $date (sort keys %dates_hist) {
		print "$date 12:00:00 ";
		for (my $i = 0; $i < @{$q->{'codes'}}; $i++) {
			my $heard = $q->{'codes'}[$i];
			if (defined $dates_hist{$date}{$heard}) {
				printf(" %3d", $dates_hist{$date}{$heard});
			} else {
				print "   0";
			}
		}
		printf("  %3d", $dates_hist{$date}{'unknown'} || 0);
		print "\n";
	}

	print "# total             ";
	foreach my $heard (@{$q->{'codes'}}, 'unknown') {
		if (defined $heard_hist{$heard}) {
			printf(" %3d", $heard_hist{$heard});
		} else {
			print "   0";
		}
	}
	print "\n";
}

# ======================================================================
# ======================================================================
# ======================================================================
# MAIN

# program options
my $help = 0;
my ($resp_only, $sort, $hist, $reanalyse, $show_orig);

GetOptions(
	'help|?' => \$help,
	'format=s' => \$format,
	'wiki' => sub { $format = 'wiki' },
	'text' => sub { $format = 'text' },
	'min-width|width|w=i' => \$min_width,
	'only|o=i' => \$resp_only,
	'show-orig|show-original' => \$show_orig,
	'resp-hist' => sub { $hist = 'resp' },
	'date-hist' => sub { $hist = 'date' },
	'sort!' => \$sort,
	'sorted' => sub { $sort = 1 },
	'graph!' => \$show_graph,
	'survinfo=s' => \$survinfo_file,
	'file=s'     => \$filename,
	'respfile=s' => \$respfile,
	'statfile=s' => \$statfile,
	'otherfile=s' => \$otherfile,
	'reparse!' => \$reparse,
	'restat!' => \$restat,
	'reanalyse|reanalyze!' => \$reanalyse,
	'ask|ask-categorized!' => \$ask_categorized,
) or pod2usage(1);
pod2usage(1) if $help;

@survey_data = read_survinfo($survinfo_file);
add_coderefs(\@survey_data);

%survey_data = @survey_data;
delete_sections(\%survey_data);

@sections = make_sections(\@survey_data);

# number of questions is hardcoded here to allow faster fail
unless (!defined $resp_only ||
        (0 <= $resp_only && $resp_only <= 30)) {
	print STDERR "Response number $resp_only is not between 0 and 30\n";
	exit 1;
}

=head1 NAME

survey_parse_Survs.com_CSV-Num.com - Parse data from "Git User's Survey"

=head1 SYNOPSIS

./survey_parse_Survs.com_CSV-Num.perl [options]

 Options:
   --help                      brief help message

   --format=wiki|text          set output format
   --wiki                      set 'wiki' (Mediawiki) output format
   --text                      set 'text' output format
   -w,--min-width=<width>      minimum width of first column
   --no-graph                  do not generate graphical histogram
                               (using HTML, only for 'wiki' format)

   --date-hist                 print only histogram of dates
   --resp-hist                 print only histogram of responses

   --only=<question number>    display only results for given question
   --show-original             show original responses, untabularized
                               (works only with --only=<number>)
   --sort                      sort tables by number of responses
                               (requires --only=<number>)

   --survinfo=<YAML file>      file with data about survey structure
   --file=<CSV file>           input file, in CSV format
   --respfile=<filename>       file to save parsed responses
   --statfile=<filename>       file to save generated statistics
   --otherfile=<filename>      human-readable file to save analysis of
                               'other, please specify' answers

   --reparse                   reparse CSV file even if cache exists
   --restat                    regenerate statistics even if cache exists
   --reanalyse                 reanalyse 'other, please specify' answers
   --ask-categorized           ask for a new rules also for categorized
                               'other, please specify' answers

=head1 DESCRIPTION

B<survey_parse_Survs_CSV(num).com.perl> is used to parse data from
CSV export (numeric) from "Git User's Survey 20xx" from Survs.com

=cut

Date_Init("TZ=$resp_tz", "ConvTZ=$resp_tz", "Language=English");

if ((my $basedir = dirname($0))) {
	foreach my $nameref ( \$filename, \$respfile, \$statfile, \$otherfile ) {
		next if (-f $$nameref);
		next if File::Spec->file_name_is_absolute($$nameref);
		$$nameref = File::Spec->canonpath("$basedir/".basename($$nameref));

		#print "$$nameref\n";
	}
}

if (-f $respfile && $reparse) {
	unlink($respfile);
	unlink($statfile) if (-f $statfile);
}
if (-f $statfile && $restat) {
	unlink($statfile);
}

my @responses = parse_or_retrieve_data(\%survey_data);
make_or_retrieve_hist(\%survey_data, \@responses);
my %other_repl = init_or_retrieve_other(\%survey_data);

my $nquestions = $survey_data{'nquestions'};
my $nresponses = scalar @responses;

if (defined $hist) {
	if ($hist eq 'date') {
		print_date_hist(\%survey_data, \@responses);
		exit 0;
	} elsif ($hist eq 'resp') {
		print_resp_hist(\%survey_data, $nresponses);
		exit 0;
	}
}

unless ($resp_only) {
	print "There were $nresponses individual responses\n\n";
	if ($survey_data{'survey_stats'}) {
		print $survey_data{'survey_stats'}."\n";
	}

	print_base_stats(\%survey_data, \@responses);
}


unless ($resp_only) {
	print fmt_th_percent('Answered questions');
 SKIPPED:
	for (my $i = 0; $i <= $survey_data{'nquestions'}; $i++) {
		my $nskipped = $survey_data{'histogram'}{'skipped'}{$i};
		print fmt_row_percent($survey_data{'nquestions'} - $i,
		                      $nskipped,
		                      100.0*$nskipped/$nresponses, $nresponses);
	}
	if ($format ne 'wiki') {
		print "  " . ('-' x ($width + 17)) . "\n";
	} else {
		print "|}\n\n";
	}
}

if (defined $resp_only && $resp_only == 0) {
	exit 0;
}

#$other_repl{$_}{'title'} = $survey_data{$_}{'title'}
#	foreach (grep /^Q[0-9]+$/, keys %other_repl);

if ($reanalyse) {
	if ($resp_only) {
		$other_repl{"Q$resp_only"}{'last'} = 0;
	} else {
		$other_repl{$_}{'last'} = 0
			foreach (keys %other_repl);
	}
}
make_other_hist(\%survey_data, \@responses,
                \%other_repl, $resp_only);

# ===========================================================
# Print results
my $nextsect = 0;

if ($resp_only) {
	my $q = $survey_data{"Q$resp_only"};

	print_question_stats($q, $nresponses, $sort);
	print_other_stats($q, $other_repl{"Q$resp_only"}, $nresponses)
		if ($q->{'other'});
	print_extra_info($q);
	if ($show_orig) {
		print_original_responses(\%survey_data, \@responses, $resp_only);
	}

	if (ref($q->{'post'}) eq 'CODE') {
		# \@responses are needed if post sub wants to re-analyze data
		$q->{'post'}(\%survey_data, \@responses, $resp_only,
		             $nresponses, $sort);
	}

} else {

	print STDERR "printing results... \n";
 QUESTION:
	for (my $qno = 1; $qno <= $nquestions; $qno++) {
		my $q = $survey_data{"Q$qno"};
		next unless (defined $q);

		# section header
		if (exists $sections[$nextsect] &&
		    $sections[$nextsect]{'start'} <= $qno) {
			print fmt_section_header($sections[$nextsect]{'title'});
			$nextsect++;
		}

		# question
		print_question_stats($q, $nresponses);
		print_other_stats($q, $other_repl{"Q$qno"}, $nresponses)
			if ($q->{'other'});
		print_extra_info($q);
	}
	print STDERR "done printing\n";
}

#print Data::Dumper->Dump(
#	[   \@sections],
#	[qw(\@sections)]
#);

__END__
