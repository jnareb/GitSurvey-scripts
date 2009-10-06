#!/usr/bin/perl

# survey_parse - parse results of survey from Survs.com in CSV format
#
# (C) 2008-2009, Jakub Narebski
#
# This program is licensed under the GPLv2 or later
#
# Parse result of exporting individual respondends (individual replies)
# in CSV format (Surveys > {survey} > Analyze > Export) from Survs.com,
# using 'Numeric' (shorter) format for responses
#
# It is intendend to parse results of "Git User's Survey 2009"

use strict;
use warnings;

use Encode;
use PerlIO::gzip;
use Text::CSV;
use Text::Wrap;
use Getopt::Long;
use Pod::Usage;
use List::Util qw(max maxstr min minstr sum);
#use File::Basename;

use Date::Manip;
use Locale::Country;
use Locale::Object::Country;
use Statistics::Descriptive;

use constant DEBUG => 0;

# Storable uses *.storable, YAML uses *.yml
use Data::Dumper;
use Storable qw(store retrieve);
#use YAML::Tiny qw(Dump Load);
#use YAML;

binmode STDOUT, ':utf8';

# ======================================================================
# ----------------------------------------------------------------------
my $filename = 'Survey results Sep 16, 09.csv';
my $respfile = 'GitSurvey2009.responses.storable';
my $statfile = 'GitSurvey2009.stats.storable';

my ($reparse, $restat);

my $resp_tz = "CET"; # timezone of responses date and time


# Parse data (given hardcoded file)
sub parse_data {
	my ($survinfo, $responses) = @_;

	my $csv = Text::CSV->new({
		binary => 1, eol => $/,
		escape_char => "\\",
		allow_loose_escapes => 1
	}) or die "Could not create Text::CSV object: ".
	          Text::CSV->error_diag();

	my $line;
	my @columns = ();

	open my $fh, '<', $filename
		or die "Could not open file '$filename': $!";
	if ($filename =~ m/\.gz$/) {
		binmode $fh, ':gzip'
			or die "Could not set up gzip decompression on '$filename': $!";
	}

	# ........................................
	# CSV column headers
	$line = <$fh>;
	chomp $line;
	unless ($csv->parse($line)) {
		print STDERR "$.: parse() on CSV header failed\n";
		print STDERR $csv->error_input()."\n";
		$csv->error_diag(); # void context: print to STDERR
	}
	@columns = $csv->fields();
	splice(@columns,0,4); # first 4 columns are informational
	my $nfields = @columns;

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


	# ........................................
	# CSV lines
	#my $responses = [];
	my ($respno, $respdate, $resptime, $channel);

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

		unless ($nfields == (scalar(@$row) - 4)) {
			print STDERR "$.: number of columns doesn't match: ".
			             "$nfields != ".(scalar @$row)."\n";
			last RESPONSE; # error would usually be not recoverable
		}

		my $resp = [];
		my @columns = @$row;

		# handle special columns, normalize date
		($respno, $respdate, $resptime, $channel) =
			splice(@columns,0,4);
		my ($year, $day, $month) = split("/", $respdate);
		$respdate = "$year-$month-$day"; # ISO format

		$resp->[0] = {
			'respondent number' => $respno,
			'date' => $respdate,
			'time' => $resptime,
			'parsed_date' => ParseDate("$respdate $resptime $resp_tz"),
			'channel' => $channel
		};

	QUESTION:
		for (my $qno = 1; $qno <= $survinfo->{'nquestions'}; $qno++) {
			my $qinfo = $survinfo->{"Q$qno"};
			next unless (defined $qinfo);
			my $col = $qinfo->{'col'};

			# this if-elsif-else chain should be probably converted
			# to dispatch table or a switch statement
			if ($qinfo->{'freeform'}) {
				# free-form essay, single value
				$resp->[$qno] = {
					'type' => 'essay',
					'contents' => $columns[$col]
				};
				$resp->[$qno]{'skipped'} = 1
					if ($columns[$col] eq '');

			} elsif (!exists $qinfo->{'codes'}) {
				# free-form, single value
				$resp->[$qno] = {
					'type' => 'oneline',
					'contents' => $columns[$col]
				};
				if (ref($qinfo->{'hist'}) eq 'CODE' &&
				    $columns[$col] ne '') {
					$resp->[$qno]{'original'} = $columns[$col];
					$resp->[$qno]{'contents'} = $qinfo->{'hist'}->($columns[$col]);
				}
				$resp->[$qno]{'skipped'} = 1
					if ($columns[$col] eq '');

			} elsif (!$qinfo->{'multi'} && !$qinfo->{'columns'}) {
				# single choice
				$resp->[$qno] = {
					'type' => 'single-choice',
					'contents' => $columns[$col]
				};
				# single choice with other
				if ($qinfo->{'other'} && $columns[$col+1] ne '') {
					$resp->[$qno]{'contents'} = $#{$qinfo->{'codes'}};
					$resp->[$qno]{'other'} = $columns[$col+1];
				}
				$resp->[$qno]{'skipped'} = 1
					if ($columns[$col] eq '' &&
					    (!$qinfo->{'other'} || $columns[$col+1] eq ''));

			} elsif ($qinfo->{'multi'} && !$qinfo->{'columns'}) {
				# multiple choice
				my $skipped = 1;
				$resp->[$qno] = {
					'type' => 'multiple-choice',
					'contents' => []
				};
				for (my $j = 0; $j < @{$qinfo->{'codes'}}; $j++) {
					my $value = $columns[$col+$j];
					next unless (defined $value && $value ne '');
					if ($qinfo->{'other'} && $j == $#{$qinfo->{'codes'}}) {
						$value = "".($j+1); # number stringified, not value !!!
					}
					push @{$resp->[$qno]{'contents'}}, $value;
					$skipped = 0;
				}
				# multiple choice with other
				if ($qinfo->{'other'} &&
				    $columns[$col+$#{$qinfo->{'codes'}}] ne '') {
					$resp->[$qno]{'other'} =
						$columns[$col+$#{$qinfo->{'codes'}}];
				}
				$resp->[$qno]{'skipped'} = 1 if ($skipped);

			} elsif ($qinfo->{'columns'}) {
				# matrix
				my $skipped = 1;
				$resp->[$qno] = {
					'type' => 'matrix',
					'contents' => []
				};
				for (my $j = 0; $j < @{$qinfo->{'codes'}}; $j++) {
					my $value = $columns[$col+$j];
					next unless (defined $value && $value ne '');
					push @{$resp->[$qno]{'contents'}}, $value;
					$skipped = 0;
				}
				$resp->[$qno]{'skipped'} = 1 if ($skipped);

			} # end if-elsif ...

		} # end for QUESTION

		#$responses->[$respno] = $resp
		push @$responses, $resp
			if (defined $resp && ref($resp) eq 'ARRAY' && @{$resp} > 0);

	} # end while RESPONSE

	return $responses;
}

sub parse_or_retrieve_data {
	my $survey_data = shift;
	my $responses = [];
	local $| = 1; # autoflush

	if (! -f $respfile || $reparse) {
		$filename .= '.gz'
			unless -r $filename;

		print STDERR "parsing '$filename'... ";
		parse_data($survey_data, $responses);
		print STDERR "(done)\n";

		print STDERR "storing in '$respfile'... ";
		store($responses, $respfile);
		print STDERR "(done)\n";
	} else {
		print STDERR "retrieving from '$respfile'... ";
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

sub make_or_retrieve_hist {
	my ($survey_data, $responses) = @_;
	local $| = 1; # autoflush

	if (! -f $statfile || $restat) {
		print STDERR "generating statistics... ";
		prepare_hist($survey_data);
		make_hist($survey_data, $responses);
		print STDERR "(done)\n";

		print STDERR "storing in '$statfile'... ";
		store(extract_hist($survey_data), $statfile);
		print STDERR "(done)\n";
	} else {
		print STDERR "retrieving from '$statfile'... ";
		my $survey_hist = retrieve($statfile);
		union_hash($survey_data, $survey_hist);
		print STDERR "(done)\n";
	}
	return wantarray ? %$survey_data : $survey_data;

}

# extract histogram part of survey data (survey info)
sub extract_hist {
	my $src = shift;
	my $dst = {};

	foreach my $key (keys %$src) {
		my $val = $src->{$key};

		if ($key =~ m/^(?: skipped | base | matrix | histogram )/x) {
			$dst->{$key} = $val;
		} elsif (ref($val) eq 'HASH') {
			$val = extract_hist($val);
			$dst->{$key} = $val if (%$val);
		}
	}

	return $dst;
}

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

my @country_names = all_country_names();
sub normalize_country {
	my $country = shift;

	# strip leading and trailing whitespace
	$country =~ s/^\s+//;
	$country =~ s/\s+$//;

	# strip prefix
	$country =~ s/^The //i;

	# strip extra info
	$country =~ s/, Europe\b//i;
	$country =~ s/, but .*$//i;
	$country =~ s/, UK\b//i;
	$country =~ s/, the\b//i;
	$country =~ s/ \. shanghai\b//i;
	$country =~ s/^Kharkiv, //i;
	$country =~ s/^Victoria, //i;
	$country =~ s/ \(Holland\)//i;
	$country =~ s/ R\.O\.C\.//i;
	$country =~ s/^\.([a-z][a-z])$/$1/i;
	$country =~ s/[!?]+$//;
	$country =~ s/\bMotherfucking\b //i;
	$country =~ s/, bitch\.//;

	# correct (or normalize) spelling
	$country =~ s/\b(?:Amerrica|Ameircia)\b/America/i;
	$country =~ s/\bBrasil\b/Brazil/i;
	$country =~ s/\bBrazul\b/Brazil/i;
	$country =~ s/\bChezh Republic\b/Czech Republic/i;
	$country =~ s/\bCzechia\b/Czech Republic/i;
	$country =~ s/\bChinese\b/China/i;
	$country =~ s/\bEnglang\b/England/i;
	$country =~ s/\bFinnland\b/Finland/i;
	$country =~ s/\bGerman[u]?\b/Germany/i;
	$country =~ s/\bGernany\b/Germany/i;
	$country =~ s/\bKyrgyzstab\b/Kyrgyzstan/i;
	$country =~ s/\bLithuani\b/Lithuania/i;
	$country =~ s/\bMacedoni\b/Macedonia/i;
	$country =~ s/\bM.*xico\b/Mexico/i;
	$country =~ s/\bMolodva\b/Moldova/i;
	$country =~ s/\bSapin\b/Spain/i;
	$country =~ s/^Serbia$/Serbia and Montenegro/i; # outdated info
	$country =~ s/\b(?:Sitzerland|Swtzerland)\b/Switzerland/i;
	$country =~ s/\bSwedeb\b/Sweden/i;
	$country =~ s/\bUnited Kindom\b/United Kingdom/i;
	$country =~ s/\bViet Nam\b/Vietnam/i;
	$country =~ s/\bZealandd\b/Zealand/i;
	$country =~ s/\bUSUnited States\b/United States/i;
	$country =~ s/\bUnited? States?\b/United States/i;
	# many names of United States of America
	$country =~ s/^U\.S(?:|\.|\.A|\.A\.)$/USA/;
	$country =~ s/^US of A$/USA/;
	$country =~ s/^USofA$/USA/;

	# local name to English
	$country =~ s/\bDeutschland\b/Germany/i;

	# other fixes and expansions
	$country =~ s/^PRC$/China/i; # People's Republic of China
	$country =~ s/^U[Kk]$/United Kingdom/;
	$country =~ s/\bUK\b/United Kingdom/i;
	$country =~ s/ \(Rep. of\)/, Republic of/;
	$country =~ s/\b(?:Unites|Unitered)\b/United/i;
	$country =~ s/\bStatus\b/States/i;

	# province, state or city to country
	$country =~ s/^.*(?:England|Scotland|Wales).*$/United Kingdom/i;
	$country =~ s/^Northern Ireland$/United Kingdom/i;
	$country =~ s/\bTexas\b/USA/i;
	$country =~ s/\bCalgary\b/Canada/i;
	$country =~ s/\bAdelaide\b/Australia/i;
	$country =~ s/\bAmsterdam\b/Netherlands/i;
	$country =~ s/\bBasque country\b/Spain/i;
	$country =~ s/\bCatalonia\b/Spain/i;

	# convert to code and back to country, normalizing country name
	# (or going from code to country)
	my $code = country2code($country) || $country;
	$country = code2country($code)    || $country;

	unless (scalar grep { $_ eq $country } @country_names) {
		$country .= '?';
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

# ----------------------------------------------------------------------
# Format output

# 'text' or 'wiki' (actually anything or 'wiki')
my $format = 'text'; # default output format

# MoinMoin wiki table style
my $tablestyle = '';
my %rowstyle =
	('th'  => 'font-weight: bold; background-color: #ffffcc;',
	 'row' => undef,
	 'footer' => 'font-weight: bold; font-style: italic; background-color: #ccffff;'
	);

my $min_width = 30; # default (minimum) width of column with answer


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

my $width = $min_width;
sub fmt_th_percent {
	my $title = shift || "Answer";

	if ($format eq 'wiki') {
		#my $style = join(' ', grep { defined $_ && $_ ne '' }
		#                 $tablestyle, $rowstyle{'th'});
		my $style = defined($rowstyle{'th'}) ?
		            "<rowstyle=\"$rowstyle{'th'}\">" : '';

		return "## table begin\n" .
		       sprintf("||$style %-${width}s || %5s || %-5s ||\n",
		               $title, "Count", "Perc.");
	}

	return sprintf("  %-${width}s | %5s | %-5s\n", $title, "Count", "Perc.") .
	               "  " . ('-' x ($width + 17)) . "\n";
}

sub fmt_matrix_maxlen {
	my $columns = shift;

	return max(
		map(length, @$columns),
		$format eq 'wiki' ?
			length(' 9999 ||  99.9%') - length('<-2> '):
			length('9999 (99%)')
	);
}

sub fmt_th_matrix {
	my ($title, $columns, $show_avg) = @_;
	$title ||= "Answer";

	my $maxlen = fmt_matrix_maxlen($columns);
	my @fmtcol = map { sprintf("%-${maxlen}s", $_) } @$columns;

	if ($format eq 'wiki') {
		#my $style = join(' ', grep { defined $_ && $_ ne '' }
		#                 $tablestyle, $rowstyle{'th'});
		my $style = defined($rowstyle{'th'}) ?
		            "<rowstyle=\"$rowstyle{'th'}\">" : '';

		my $th = join('||', map { "<-2> $_ " } @fmtcol);
		$th .= "|| || Avg. / Count " if ($show_avg);
		return "## table begin\n" .
		       sprintf("||$style %-${width}s ||$th||\n",
		               $title);
	}

	my $th = join('|', map { " $_ " } @fmtcol);
	$th .= "|| Avg." if ($show_avg);
	$th = sprintf("%-${width}s |$th\n", $title);
	return "  $th".
	       "  " . ('-' x (length($th)-1)) . "\n";
}

sub fmt_row_percent {
	my ($name, $count, $perc) = @_;

	if ($format eq 'wiki') {
		# CamelCase -> !CamelCase to avoid accidental wiki links
		$name =~ s/\b([A-Z][a-z]+[A-Z][a-z]+)\b/!$1/g;

		my $style = defined($rowstyle{'row'}) ?
		            "<rowstyle=\"$rowstyle{'row'}\">" : '';
		return sprintf("||%s %-${width}s || %5d || %4.1f%% ||\n",
		               $style, $name, $count, $perc);
	}

	return sprintf("  %-${width}s | %-5d | %4.1f%%\n",
	               $name, $count, $perc);
}

sub fmt_row_matrix {
	my ($name, $hist, $base, $columns, $score, $count) = @_;

	# CamelCase -> !CamelCase to avoid accidental wiki links
	$name =~ s/\b([A-Z][a-z]+[A-Z][a-z]+)\b/!$1/g
		if ($format eq 'wiki');

	# format row name (answer)
	my $result;
	if ($format eq 'wiki') {
		my $style = defined($rowstyle{'row'}) ?
		            "<rowstyle=\"$rowstyle{'row'}\">" : '';
		$result = sprintf("||%s %-${width}s", $style, $name);
	} else {
		$result = sprintf("  %-${width}s", $name);
	}

	my $maxlen = fmt_matrix_maxlen($columns);
	my ($sep, $doublesep);
	if ($format eq 'wiki') {
		$sep = ' || ';
		$doublesep = ' || || ';
	} else {
		$sep = ' | ';
		$doublesep = ' || ';
	}
	foreach my $entry (@$hist) {
		my $perc = 100.0*$entry / $base;
		my $col;
		if ($format eq 'wiki') {
			$col = sprintf("%-5d || %4.1f%%", $entry, $perc);
		} else {
			$col = sprintf("%4d (%.0f%%)", $entry, $perc);
		}
		$col = sprintf("%-${maxlen}s", $col);
		$result .= "$sep$col";
	}
	if ($score) {
		$result .= $doublesep . sprintf("%3.1f", $score);
		$result .= ' / ' . sprintf("%-4d", $count)
			if (defined $count && $format eq 'wiki');
		# or alternatively
		#$result .= ' / ' . sprintf("%-4d", sum(@$hist))
		#	if ($format eq 'wiki');
	}

	if ($format eq 'wiki') {
		$result .= ' ||';
	}

	return $result . "\n";
}

sub fmt_footer_percent {
	my ($base, $responses) = @_;

	if (!defined($base) && $format ne 'wiki') {
		return "  " . ('-' x ($width + 17)) . "\n";
	}

	if ($format eq 'wiki') {
		return "## table end\n\n" unless defined($base);

		my $style = defined($rowstyle{'footer'}) ?
		            "<rowstyle=\"$rowstyle{'footer'}\">" : '';

		return sprintf("||%s %-${width}s ||<-2> %5d / %-5d ||\n",
		               $style, "Base", $base, $responses) .
		       "## table end\n\n";
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
		$sep = ' || ';
		$doublesep = ' || || ';
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
			            "<rowstyle=\"$rowstyle{'footer'}\">" : '';
			$result .= sprintf("||%s %-${width}s ||<-%d> %5d / %-5d ||\n",
			                   $style, "Base", $ncol*2 + 2*!!$show_avg,
			                   $base, $responses);
		} else {
			$result .= sprintf("  %-${width}s | %5d / %-5d\n", "Base",
			                   $base, $responses);
		}
	}
	if ($format eq 'wiki') {
		$result .= "## table end\n\n";
	}
	return $result;
}

# . . . . . . . . . . . . . . . . . . . . . . . . . . . 

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
my @survey_data =
	('survey_title' => "Git User's Survey 2009",
	 'S1' => {'section_title' => "About you"},
	 'Q1' =>
	 {'title' => '01. What country do you live in?',
	  'colname' => 'Country',
	  'hist'  => \&normalize_country,
	  'post'  => \&print_continents_stats},
	 'Q2' =>
	 {'title' => '02. How old are you (in years)?',
	  'colname' => 'Age',
	  'hist' => \&normalize_age,
	  'histogram' =>
		{' < 18' => 0,
		 '18-21' => 0,
		 '22-25' => 0,
		 '26-30' => 0,
		 '31-40' => 0,
		 '41-50' => 0,
		 '51-75' => 0,
		 '76+  ' => 0}},
	 'S2' => {'section_title' => 'Getting started with Git'},
	 'Q3' =>
	 {'title' => '03. Have you found Git easy to learn?',
	  'codes' =>
		['Very easy',
		 'Easy',
		 'Reasonably easy',
		 'Hard',
		 'Very hard']},
	 'Q4' =>
	 {'title' => '04. Have you found Git easy to use?',
	  'codes' =>
		['Very easy',
		 'Easy',
		 'Reasonably easy',
		 'Hard',
		 'Very hard']},
	 'Q5' =>
	 {'title' => '05. Which Git version(s) are you using?',
	  'colname' => 'Version used',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['pre 1.3',
		 '1.3.x',
		 '1.4.x',
		 '1.5.x',
		 '1.6.x',
		 "minor (maintenance) release 1.x.y.z",
		 "'master' branch of official git repository",
		 "'next' branch of official git repository",
		 "other, please specify"],
	  'description' => <<'EOF'},
You can find git version by using "git --version" or "git version".

"Minor release" is additional specification, so if you for example use
git version 1.6.3.3, please check both "1.6.x" and "minor release".
EOF
	 'Q6' =>
	 {'title' => '06. Rate your own proficiency with Git:',
	  'codes' =>
		['1. novice',
		 '2. casual, needs advice',
		 '3. everyday use',
		 '4. can offer advice',
		 '5. know it very well'],
	  'description' =>
		"You can think of it as 1-5 numerical grade of your proficiency in Git."},
	 'S3' => {'section_title' => 'How you use Git'},
	 'Q7' =>
	 {'title' => '07. I use Git for (check all that apply):',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['work projects',
		 'unpaid projects',
		 'proprietary projects',
		 'OSS development',
		 'private (unpublished) code',
		 'code (programming)',
		 'personal data',
		 'documents',
		 'static website',
		 'web app',
		 'sharing data or sync',
		 'backup',
		 'backend for wiki, blog, or other web app',
		 'managing configuration files',
		 'frontend to other SCM (e.g. git-svn)',
		 'other (please specify)'],
	  'description' => <<'EOF'},
Note that above choices are neither orthogonal nor exclusive.
You might want to check multiple answers even for a single repository.
EOF
	 'Q8' =>
	 {'title' => '08. How do/did you obtain Git (install and/or upgrade)?',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['binary package',
		 'source package or script',
		 'source tarball',
		 'pull from (main) repository',
		 'preinstalled / sysadmin job',
		 'other - please specify'],
	  'description' => <<'EOF'},
Explanation: binary package covers pre-compiled binary (e.g. from rpm
or deb binary packages); source package covers things like deb-src and
SRPMS/*.src.rpm; source script is meant to cover installation in
source-based distributions, like 'emerge' in Gentoo.

Automatic update (apt, yum, etc.) in most cases means binary package
install; unless one uses source-based distribution like Gentoo, CRUX,
or SourceMage, where automatic update means using source package (or
source script).

The option named "preinstalled / sysadmin job" means that either you
didn't need to install git because it was preinstalled (and you didn't
upgrade); or that you have to ask system administrator to have git
installed or upgraded.

Note that this question is multiple choices question because one can
install Git in different ways on different machines or on different
operating systems.
EOF
	 'Q9' =>
	 {'title' => '09. On which operating system(s) do you use Git?',
	  'colname' => 'Operating System',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['Linux',
		 'FreeBSD, OpenBSD, NetBSD, etc.',
		 'MacOS X (Darwin)',
		 'MS Windows/Cygwin',
		 'MS Windows/msysGit (MINGW)',
		 'OpenSolaris',
		 'other Unix',
		 'Other, please specify'],
	  'description' => <<'EOF'},
On Unix-based operating system you can get the name of operation
system by running 'uname'.
EOF
	 'Q10' =>
	 {'title' =>
		"10. What do you use to edit contents under version control with Git?\n".
		"    What kind of editor, IDE or RAD you use working with Git?",
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['simple text editor',
		 'programmers editor',
		 'IDE or RAD',
		 'WYSIWYG tool',
		 'other kind'],
	  'description' => <<'EOF'},
* "simple text editor" option includes editors such as pico, nano,
  joe, Notepad,

* "programmets editor" option includes editors such as Emacs/XEmacs,
  Vim, TextMate, SciTE (syntax highlighting, autoindentation,
  integration with other programmers tools, etc.)

* "IDE (Integrated Development Environment) and RAD (Rapid Application
  Development)" option includes tools such as Eclipse, NetBeans IDE,
  IntelliJ IDE, MS Visual Studio, KDevelop, Anjuta, Xcode,
  Code::Blocks but also tools such as Quanta+, BlueFish or Screem (for
  editing HTML, CSS, PHP etc.), and Kile or LEd for LaTeX.

* "WYSIWYG tools" option includes word processors such as MS Office or
  OpenOffice.org, but also tools such as Adobe Acrobat (for PDF) or
  GIMP (for images), or WYSIWYG DTP tools such as QuarkXPress,
  PageMaker or Scribus, or WYSIWYG HTML editors such as FrontPage,
  Dreamweaver or KompoZer.
EOF
	 'Q11' =>
	 {'title' =>
		'11. What Git interfaces, implementations, frontends and tools do you use?',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['git (core) commandline',
		 'JGit (Java implementation)',
		 'library / language binding (e.g. Grit or Dulwich)',
		 'Cogito (DEPRECATED)',
		 'Easy Git',
		 'Pyrite',
		 'StGIT',
		 'Guilt',
		 'TopGit',
		 'pg aka Patchy Git (DEPRECATED)',
		 'gitk',
		 'git gui',
		 'QGit',
		 'GitView',
		 'Giggle',
		 'GitNub',
		 'GitX',
		 'git-cola',
		 'tig',
		 'TortoiseGit',
		 'Git Extensions',
		 'git-cheetah',
		 'git-instaweb',
		 'git-sh',
		 'Gitosis (as admin)',
		 'repo (to manage multiple repositories)',
		 'editor/IDE VC integration',
		 'filemanager integration / shell extension (any)',
		 'graphical history viewer/browser (any)',
		 'graphical commit tool (any)',
		 'graphical diff tool',
		 'graphical merge tool',
		 'graphical blame or pickaxe tool',
		 'my own scripts (for daily commandline use, porcelain)',
		 'my own scripts (for special tasks)',
		 'Other (please specify)'],
	  'description' => <<'EOF'},
Here graphics diff tool means tools such as Kompare, and graphical
merge tool means tools such as Meld and KDiff3. Those answers include
graphical merge and diff tools used by programmers editors and IDEs.

"graphical history browser (any)" covers tools such as gitk, QGit,
Giggle, tig etc., but also built-in git commands such as "git log
--graph" and "git show-branch". If you use one of mentioned tools _as_
history browser, mark both a tool and "graphical history browser
(any)"; if you use some graphical history viewer not listed here,
please both mark this answer and specify it in the "other tool"
answer.

Similarly for other answers marked "(any)".
EOF
	 'Q12' =>
	 {'title' =>
		"12. What tool (or kind of tool) would you like to have Git support in?\n".
		"    (e.g. IDE, RAD, editors, continuous integration, software hosting, bugtracker, merge tool...)\n".
		"    (this includes language bindings and Git (re)implementations)",
	  'freeform' => 1},
	 'Q13' =>
	 {'title' =>
		"13. Which git hosting site(s) do you use for your project(s)?\n".
		"    (Please check only hosting sites where you publish/push to)",
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['repo.or.cz',
		 'GitHub',
		 'Gitorious',
		 'Savannah',
		 'SourceForge',
		 'Assembla',
		 'Unfuddle',
		 'kernel.org',
		 'freedesktop.org',
		 'Alioth',
		 'Fedora Hosted',
		 'git hosting site for set of related projects (e.g. OLPC)',
		 'generic site without git support',
		 'self hosted',
		 'Other (please specify)']},
	 'Q14' =>
	 {'title' => '14. How do you fetch/get changes from upstream repositories?',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['git protocol',
		 'ssh',
		 'http',
		 'rsync (DEPRECATED)',
		 'filesystem',
		 'via git-bundle',
		 'foreign SCM (e.g. git-svn)',
		 'Other, please specify'],
	  'description' => <<'EOF'},
This question asks about how do you get changes (updates) from
projects you follow into your local repository. It is not about how do
you get latest version of Git.

Fetching (or rather cloning) via bundle could mean that project
publishes ready for download bundles to reduce traffic and load on
server (HTTP download [of bundle] can be resumed, git-clone currently
cannot; one can also distribute bundle using P2P).
EOF
	 'Q15' =>
	 {'title' => '15. How do you publish/propagate your changes?',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['push',
		 'pull request (+ any form of announcement / notification)',
		 'format-patch + email',
		 'format-patch + other (e.g. reviewboard, issue tracker or forum)',
		 'git bundle',
		 'git-svn (to Subversion repository)',
		 'git-p4 (to Perforce repository)',
		 'foreign SCM interface (other than mentioned above)',
		 'other - please specify'],
	  'description' => <<'EOF'},
Publishing via bundle could mean sending bundle via email, or posting
it on review board (or forum).
EOF
	 'Q16' =>
	 {'title' => 
		'16. How often do you use the following forms of git commands '.
		'or extra git tools?',
	  'columns' =>	[qw(never rarely sometimes often)],
	  'codes' =>
		['git add -i / -p',
		 'git add -u / -A',
		 'git am',
		 'git am -i',
		 'git apply',
		 'git apply --whitespace=fix',
		 'git archive',
		 'git bisect',
		 'git bisect run <cmd>',
		 'git annotate',
		 'git gui blame',
		 'git blame',
		 'git blame -L <start>,<end> etc.',
		 'git bundle',
		 'git cherry',
		 'git cherry-pick',
		 'git cherry-pick -n / --no-commit',
		 'git citool',
		 'git clean',
		 'git add + git commit',
		 'git commit -a',
		 'git commit <file>...',
		 'git commit -i <file>...',
		 'git commit --amend',
		 'git cvsexportcommit',
		 'git cvsserver',
		 'git daemon',
		 'git daemon (pushing enabled)',
		 'git difftool',
		 'git ... --dirstat',
		 'git fetch [<options>]',
		 'git filter-branch',
		 'git format-patch',
		 'git grep',
		 'git imap-send',
		 'git instaweb',
		 'git log --grep/--author/...',
		 'git log -S<string> (pickaxe search)',
		 'git log --graph',
		 'git merge',
		 'git merge with strategy',
		 'git merge --squash',
		 'git mergetool',
		 'git pull (no remote)',
		 'git pull --rebase [<options>]',
		 'git pull <remote>',
		 'git pull <URL> <ref>',
		 'git push'],
	  'description' =>
		'This question (and its continuation below) is entirely optional.'},
	 'Q17' =>
	 {'title' =>
		'17. How often do you use the following forms of git commands '.
		'or extra git tools? (continued)',
	  'columns' =>	[qw(never rarely sometimes often)],
	  'codes' =>
		['git relink',
		 'git rebase',
		 'git rebase -i',
		 'git reflog or git log -g',
		 'git remote',
		 'git remote update',
		 'git request-pull',
		 'git revert',
		 'git send-email',
		 'git show-branch',
		 'git shortlog',
		 'git shortlog -s',
		 'git stash',
		 'git stash --keep-index',
		 'git submodule',
		 'git subtree',
		 'git svn',
		 'git whatchanged',
		 'git gui',
		 'gitk'],
	  'description' => <<'EOF'},
Explanation: "Rarely" means that you use mentioned form of command
either rarely, or you have used it only a few times.

Questions 16 and 17 (its continuation) are purely optional (as are the
rest of questions in survey). If you don't feel like filling this
questions, please skip them.

Note: git-subtree is managed out of tree, as a separate project (not
in git.git repository, not even in contrib/ area). Originally
git-subtree was submitted for inclusion, and later was considered for
'contrib/', but it was decided that it would be better if it mature
out-of-tree, before resubmitting.
EOF
	 'Q18' =>
	 {'title' => '18. Which of the following features have you used?',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['git bundle (off-line transport)',
		 'eol conversion (crlf)',
		 'gitattributes',
		 'mergetool and/or difftool, or custom diff/merge driver',
		 'submodules (subprojects)',
		 'subtree merge (optionally git-subtree)',
		 'separate worktree / core.worktree',
		 'multiple worktrees (git-new-worktree)',
		 'alternates mechanism (sharing object database)',
		 'stash (optionally "git stash --keep-index")',
		 'shallow clone (e.g. "git clone --depth=<n>")',
		 'detaching HEAD (e.g. "git checkout HEAD^0")',
		 'interactive rebase (small scale history editing)',
		 'interactive commit / per-hunk comitting / partial commit',
		 'commit message templates',
		 'git-filter-branch or equivalent (large history rewriting)',
		 'bisect (optionally "git bisect run <script>")',
		 'committing with dirty tree (keeping some changes uncommitted)',
		 'non-default hooks (from contrib/hooks/ or other)',
		 'shell completion of commands',
		 'git-aware shell prompt',
		 'git aliases, shell aliases for git, or own git scripts',
		 'Other, please specify']},
	 'Q19' =>
	 {'title' =>
		"19. What features would you like implemented in Git?\n".
		"    What features are you missing?",
	  'freeform' => 1,
	  'description' => <<'EOF'},
EXAMPLES: partial / subtree checkout, commit annotations aka
git-notes, refs/replace/* mechanism, "smart" HTTP protocol (git via
HTTP), resumable clone/fetch, lazy clone (on demand downloading of
objects), wholesame directory rename detection, syntax highlighting
and/or side-by-side diffs in gitweb, graphical merge tool integrated
with git-gui, etc.
EOF
	 'S4' => {'section_title' => 'What you think of Git'},
	 'Q20' =>
	 {'title' => '20. Overall, how happy are you with Git?',
	  'codes' =>
		['unhappy',
		 'not so happy',
		 'happy',
		 'very happy',
		 'completely ecstatic']},
	 'Q21' =>
	 {'title' =>
		"21. In your opinion, which areas in Git need improvement?\n".
		"    Please state your preference.",
	  'columns' => ["don't need", "a little", "some", "much"],
	  'codes' =>
		['user-interface',
		 'documentation',
		 'performance',
		 'more features',
		 'tools (e.g. GUI)',
		 'localization (translation)']},
	 'S5' => {'section_title' =>
		'Changes in Git (since year ago, or since you started using it)'},
	 'Q22' =>
	 {'title' => '22. Did you participate in previous Git User\'s Surveys?',
	  'multi' => 1,
	  'codes' =>
		['in 2006',
		 'in 2007',
		 'in 2008']},
	 'Q23' =>
	 {'title' => '23. How do you compare the current version with the version from one year ago?',
	  'codes' =>
		['better',
		 'no changes',
		 'worse',
		 'cannot say'],
	  'description' => <<'EOF'},
The version from approximately one year ago is 1.5.6 from 18-06-2008,
the last version in 1.5.x series (except maintenance releases from
1.5.6.1 to 1.5.6.6). Major controversial change in 1.6.0 was
installing most of the programs outside your $PATH.

Other changes include:
* stash never expires by default
* git-branch got -v, --contains and --merged options
* fast-export / fast-import learned to export and import marks file
* "git stash save" learned --keep-index option; "git stash" learned "branch" subcommand
* when you mistype a command name, git can suggest what you might meant to say
* git add -N / --intent-to-add
* built in synonym "git stage" for "git add", and --staged for --cached
* improvements to "git bisect skip" (can take range, more aggresive)
* "git diff" can use varying mnemonic prefixes, learned "textconv" filter
* "git log" learned --simplify-merges, --source, --simplify-by-decoration
* "git send-email" can automatically run "git format-patch"
* unconfigured git-push issue now a big warning (preparing for the future incompatibile change)
* you can use @{-1} to refer to the last branch you were on
* "git diff" learned --inter-hunk-context and can be told to run --patience diff
* git-difftool can run graphical diff tool

(see individual RelNotes for more details)
EOF
	 'S6' => {'section_title' => 'Documentation. Getting help.'},
	 'Q24' =>
	 {'title' => '24. How useful have you found the following forms of Git documentation?',
	  'columns' => ['never used', 'not useful', 'somewhat', 'useful'],
	  'codes' =>
		['Git Wiki',
		 'on-line help',
		 'help distributed with git'],
	  'description' => <<'EOF'},
* Git Wiki can be found at http://git.or.cz/gitwiki
* on-line help includes, among others, Git Homepage (http://git-scm.com) and "Git Community Book" (http://book.git-scm.com)
* help distributed with git include manpages, manual, tutorials, HOWTO, release notes, technical documentation, contrib/examples/
EOF
	 'Q25' =>
	 {'title' => '25. Have you tried to get help regarding Git from other people?',
	  'codes' => ['Yes', 'No']},
	 'Q26' =>
	 {'title' => '26. If yes, did you get these problems resolved quickly and to your liking?',
	  'codes' =>
		['Yes',
		 'No',
		 'Somewhat']},
	 'Q27' =>
	 {'title' => '27. What channel(s) did you use to request help?',
	  'colname' => 'Channel',
	  'multi' => 1,
	  'other' => 1,
	  'codes' =>
		['git mailing list (git@vger.kernel.org)',
		 '"Git for Human Beings" Google Group',
		 'IRC (#git)',
		 'IRC (other git/SCM related, e.g. #github)',
		 'request in blog post or on wiki',
		 'asking git guru/colleague',
		 'project mailing list, or IRC, or forum',
		 'Twitter or other microblogging platform',
		 'instant messaging (IM) like XMPP/Jabber',
		 'StackOverflow',
		 'other (please specify)']},
	 'Q28' =>
	 {'title' =>
		"28. Which communication channel(s) do you use?\n".
		"    Do you read the mailing list, or watch IRC channel?",
	  'colname' => 'Channel',
	  'multi' => 1,
	  'codes' =>
		['git@vger.kernel.org (main)',
		 'Git for Human Beings (Google Group)',
		 'msysGit',
		 '#git IRC channel',
		 '#github or #gitorious IRC channel',
		 '#revctrl IRC channel']},
	 'S7' => {'section_title' => 'About this survey. Open forum.'},
	 'Q29' =>
	 {'title' => "29. How did you hear about this Git User's Survey?",
	  'other' => 1,
	  'codes' =>
		['git mailing list',
		 'git-related mailing list (msysGit, Git for Human Beings, ...)',
		 'mailing list or forum of some project',
		 '#git IRC channel topic',
		 'announcement on IRC channel',
		 'git homepage',
		 'git wiki',
		 'git hosting site',
		 'software-related web site',
		 'news web site or social news site (e.g. Digg, Reddit)',
		 'blog (or blog planet)',
		 'other kind of web site',
		 'Twitter or other microblogging platform',
		 'other - please specify']},
	 'Q30' =>
	 {'title' => '30. What other comments or suggestions do you have '.
	             'that are not covered by the questions above?',
	  'freeform' => 1},
	 'nquestions' => 30,
);

my %survey_data = @survey_data;
delete_sections(\%survey_data);

#my @sections = make_sections(\@survey_data);
my @sections =
	({'title' => 'About you',
		'start' => 1},
	 {'title' => 'Getting started with Git',
		'start' => 3},
	 {'title' => 'How you use Git',
		'start' => 7},
	 {'title' => 'What you think of Git',
		'start' => 20},
	 {'title' => 'Changes in Git'.
	             ' (since year ago, or since you started using it)',
		'start' => 22},
	 {'title' => 'Documentation. Getting help.',
		'start' => 24},
	 {'title' => 'About this survey. Open forum.',
		'start' => 29});

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

sub delete_sections {
	my $survhash = shift;

	foreach my $key (keys %$survhash) {
		delete $survhash->{$key}
			if ($key =~ m/^S\d+$/);
	}
}

# ======================================================================
# ----------------------------------------------------------------------

# print histogram of date of response,
# in format suitable for datafile e.g for gnuplot
sub print_date_hist {
	my $survey_data = shift;


	print "# 1:date 2:responses\n";
	my $num = 0;
 DATE:
	foreach my $date (sort keys %{$survey_data->{'histogram'}{'date'}}) {
		print "$date $survey_data{'histogram'}{'date'}{$date}\n";
		$num += $survey_data{'histogram'}{'date'}{$date};
	}
	print "\n";
	
	print "# responses with date field: $num\n\n";
}

# print histogram of number of responses per question,
# in format suitable for datafile e.g for gnuplot
sub print_resp_hist {
	my $survey_data = shift;

	print "# 1:question_number 2:responses\n";
 QUESTION:
	for (my $qno = 1; $qno <= $survey_data->{'nquestions'}; $qno++) {
		my $q = $survey_data{"Q$qno"};
		next unless (defined $q);

		printf("%-2d %d\n", $qno, $q->{'base'});
	}
	print "\n";
}

# Print info about survey (from Survs.com + some extra)
sub print_survey_info {
	my $responses = shift;
	my $nresponses = scalar @$responses;

	my $date_fmt = '%Y-%m-%d %H:%M %z';
	my $first_resp = UnixDate($responses->[ 0][0]{'parsed_date'}, $date_fmt);
	my $last_resp  = UnixDate($responses->[-1][0]{'parsed_date'}, $date_fmt);
	print <<"EOF"."\n";
Completion Rate:    100%
Total respondents:  3868 ($nresponses)
Survey created:     Jun 25, 2009 03:15 PM (for testing)
Opened on:          Jul 15, 2009 02:34 AM
Announced on:       2009-07-15 02:39:43 (git wiki: GitSurvey2009)
                    2009-07-15 02:54:00 (git wiki: MainPage)
                    Wed, 15 Jul 2009 09:22:32 +0200 (git\@vger.kernel.org)
First response:     Jul 15, 2009 ($first_resp)
Last response:      Sep 16, 2009 ($last_resp)
Closed on:          Sep 16, 2009 11:45 PM (GitSurvey2009 channel, auto)
Open during:        72 days
Average time:       49 minutes
EOF
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
}

# Print results (statistics) for given question
sub print_question_stats {
	my ($q, $nresponses, $sort) = @_;

	print fmt_question_title($q->{'title'});
	print question_type_description($q)."\n";

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
			                      100.0*$q->{'histogram'}{$row} / $base);
		}
	}

	# table footer
	if (exists $q->{'columns'}) {
		print fmt_footer_matrix($q->{'base'}, $nresponses,
		                        $q->{'columns'}, exists $q->{'matrix'});
	} else {
		print fmt_footer_percent($q->{'base'}, $nresponses);
	}

	if ($q->{'description'}) {
		printf "\n";
		print "~-\n" if ($format eq 'wiki'); # start of smaller
		if ($format eq 'wiki') {
			print "'''Description:'''<<BR>>\n";
		} else {
			print "Description:\n".
			      "~~~~~~~~~~~~\n\n";
		}
		print $q->{'description'};
		print "-~"   if ($format eq 'wiki'); # end of smaller
		printf "\n";
		if ($format eq 'wiki') {
			print "'''Analysis:'''<<BR>>\n";
		} else {
			print "Analysis:\n".
			      "~~~~~~~~~\n\n";
		}
	}
}

# ......................................................................

sub print_continents_stats {
	#my ($survey_data, $responses) = @_;
	my ($q, $nresponses, $sort) = @_;
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
		print fmt_row_percent($continent, $data, 100.0*$data / $base);
	}
}

# ======================================================================
# ======================================================================
# ======================================================================
# MAIN

my $help = 0;
my ($resp_only, $sort);

GetOptions(
	'help|?' => \$help,
	'format=s' => \$format,
	'wiki' => sub { $format = 'wiki' },
	'text' => sub { $format = 'text' },
	'min-width|width|w=i' => \$min_width,
	'only|o=i' => \$resp_only,
	'sort!' => \$sort,
	'file=s'     => \$filename,
	'respfile=s' => \$respfile,
	'statfile=s' => \$statfile,
	'reparse!' => \$reparse,
	'restat!' => \$restat,
);
pod2usage(1) if $help;

# number of questions is hardcoded here to allow faster fail
unless (!defined $resp_only ||
        (0 <= $resp_only && $resp_only <= 30)) {
	print STDERR "Response number $resp_only is not between 0 and 30\n";
	exit 1;
}

=head1 NAME

survey_parse_Survs_CSV(num).com - Parse data from "Git User's Survey 2009"

=head1 SYNOPSIS

./survey_parse_Survs_CSV(num).com.perl [options]

 Options:
   --help                      brief help message

   --format=wiki|text          set output format
   --wiki                      set 'wiki' (MoinMoin) output format
   --text                      set 'text' output format
   -w,--min-width=<width>      minimum width of first column

   --only=<question number>    display only results for given question
   --sort                      sort tables by number of responses
                               (requires --only=<number>)

   --filename=<CSV file>       input file, in CSV format
   --respfile=<filename>       file to save parsed responses
   --statfile=<filename>       file to save generated statistics

   --reparse                   reparse CSV file even if cache exists
   --restat                    regenerate statistics even if cache exists
=head1 DESCRIPTION

B<survey_parse_Survs_CSV(num).com.perl> is used to parse data from
CSV export (numeric) from "Git User's Survey 2009" from Survs.com

=cut

Date_Init("TZ=$resp_tz", "ConvTZ=$resp_tz", "Language=English");

my @responses = parse_or_retrieve_data(\%survey_data);
make_or_retrieve_hist(\%survey_data, \@responses);

my $nquestions = $survey_data{'nquestions'};
my $nresponses = scalar @responses;

unless ($resp_only) {
	print "There were $nresponses individual responses\n\n";
	print_survey_info(\@responses);

	print_base_stats(\%survey_data, \@responses);
}


unless ($resp_only) {
	print fmt_th_percent('Answered questions');
 SKIPPED:
	for (my $i = 0; $i <= $survey_data{'nquestions'}; $i++) {
		my $nskipped = $survey_data{'histogram'}{'skipped'}{$i};
		print fmt_row_percent($survey_data{'nquestions'} - $i,
		                      $nskipped,
		                      100.0*$nskipped/$nresponses);
	}
	if ($format ne 'wiki') {
		print "  " . ('-' x ($width + 17)) . "\n";
	} else {
		print "## table end\n\n";
	}
}

if (defined $resp_only && $resp_only == 0) {
	exit 0;
}

# ===========================================================
# Print results
my $nextsect = 0;

if ($resp_only) {
	my $q = $survey_data{"Q$resp_only"};

	print_question_stats($q, $nresponses, $sort);
	if (ref($q->{'post'}) eq 'CODE') {
		$q->{'post'}($q, $nresponses, $sort);
	}

} else {

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
	}
}

#print Data::Dumper->Dump(
#	[   \@sections],
#	[qw(\@sections)]
#);

__END__
