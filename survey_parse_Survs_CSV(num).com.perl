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
use Text::CSV;
use Text::Wrap;
use Date::Manip;
use Locale::Country;
use Getopt::Long;
#use File::Basename;

use constant DEBUG => 0;

# Storable uses *.storable, YAML uses *.yml
use Data::Dumper;
use Storable qw(store retrieve);
#use YAML::Tiny qw(Dump Load);
#use YAML;

binmode STDOUT, ':utf8';

# ======================================================================
# ----------------------------------------------------------------------
my $filename = '/tmp/jnareb/Survey results Sep 16, 09.csv';
my $resp_tz = "CET"; # timezone of responses date and time

# Parse data (given hardcoded file)
sub parse_data {
	my $survinfo = shift;

	my $csv = Text::CSV->new({
		binary => 1, eol => $/,
		escape_char => "\\",
		allow_loose_escapes => 1
	}) or die "Could not create Text::CSV object: ".
	          Text::CSV->error_diag();

	my $line;
	my @columns = ();

	open my $fh, '<', 
		or die "Could not open file '$filename': $!";

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
	my $responses = [];
	my ($respno, $respdate, $resptime, $channel);

 RESPONSE:
	while (my $row = $csv->getline($fh)) {
		unless (defined $row) {
			my $err = $csv->error_input();

			print STDERR "$.: getline() failed on argument: $err\n";
			$csv->error_diag(); # void context: print to STDERR
			next RESPONSE unless $csv->eof();
			last RESPONSE; #  if $csv->eof();
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
			#'date' => $respdate,
			#'time' => $resptime,
			'date' => ParseDate("$respdate $resptime $resp_tz"),
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
					next unless ($columns[$col+$j] ne '');
					push @{$resp->[$qno]{'contents'}}, $columns[$col+$j];
					$skipped = 0;
				}
				# multiple choice with other
				if ($qinfo->{'other'}) {
					$resp->[$qno]{'other'} =
						$columns[$col+$#{$qinfo->{'codes'}}];
				}

			} elsif ($qinfo->{'columns'}) {
				# matrix
				my $skipped = 1;
				$resp->[$qno] = {
					'type' => 'matrix',
					'contents' => []
				};
				for (my $j = 0; $j < @{$qinfo->{'codes'}}; $j++) {
					next unless ($columns[$col+$j] ne '');
					push @{$resp->[$qno]{'contents'}}, $columns[$col+$j];
					$skipped = 0;
				}
			} # end if-elsif ...

		} # end for QUESTION

		$responses->[$respno] = $resp;

	} # end while RESPONSE

	return $responses;
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
	my $country = shift;

	my $code = country2code($country) || $country;
	$country = code2country($code)    || $country;

	return ucfirst($country);
}

sub normalize_age {
	my $age = shift;

	# extract
	$age =~ s/^[^0-9]*([0-9]+).*$/$1/;

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

# ----------------------------------------------------------------------
# Format output

# ======================================================================
# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# DATA
my @survey_data =
	('survey_title' => "Git User's Survey 2009",
	 'S1' => {'section_title' => "About you"},
	 'Q1' =>
	 {'title' => '01. What country do you live in?',
	  'hist'  => \&normalize_country},
	 'Q2' =>
	 {'title' => '02. How old are you (in years)?',
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
my @sections = make_sections(\@survey_data);

sub make_sections {
	my $survinfo = shift;
	my @sections = ();

	for (my $i = 0, my $qno = 0; $i < @$survinfo; $i += 2) {
		my ($key, $val) = $survinfo->[$i,$i+1];
		if ($key =~ m/^(Q(\d+))$/) {
			$qno = $1;
			next;
		}
		next unless (exists $val->{'section_title'});
		push @sections, {'title' => $val->{'section_title'}, 'start' => $qno+1};
	}
}

# ======================================================================
# ======================================================================
# ======================================================================
# MAIN

my %hist       = ();
my %datehist   = ();
my %surveyinfo = ();

open my $fd, '<', '/tmp/jnareb/Survey results Sep 16, 09.csv'
	or die "Could not open file: $!";

my $csv = Text::CSV->new({
	binary => 1, eol => $/,
	escape_char => "\\",
	allow_loose_escapes => 1
}) or die Text::CSV->error_diag();

my ($line, $status);

# header line
$line = <$fd>;
chomp $line;
$status = $csv->parse($line);
my @colnames = $csv->fields();

my ($respno, $respdate, $resptime, $channel);


# $line = <$fd>;
# $line = <$fd>;
# $line = <$fd>;
# $line = <$fd>;
# chomp $line;

# #rely on the fact that last question is free-form essay question
# while ($line !~ m/"$/) {
# 	$line .= <$fd>;
# 	chomp $line;
# }

# unless ($csv->parse($line)) {
# 	my $err = $csv->error_input();

# 	print STDERR "$.: parse() failed on argument: $err\n";
# 	die $csv->error_diag(); # void context: print to STDERR
# }

# my @columns = $csv->fields();

$csv->getline($fd);
$csv->getline($fd);
$csv->getline($fd);
my $colref = $csv->getline($fd);

unless (defined $colref) {
	my $err = $csv->error_input();

	print STDERR "$.: getline() failed on argument: $err\n";
	die $csv->error_diag();
}

my @columns = @$colref;

($respno, $respdate, $resptime, $channel) =
	splice(@columns,0,4);
splice(@colnames, 0,4);

print "VERSION: ".Text::CSV->VERSION()."\n";
print "version: ".Text::CSV->version()."\n\n";

{
	my ($year, $day, $month) = split("/", $respdate);
	$respdate = "$year-$month-$day";
}

my @responses = ();
my $response = [];

print "respno:  $respno\n".
      "date:    $respdate $resptime\n".
      "channel: $channel\n";

$response->[0] = { 'date' => $respdate };

{
	my $qno = 0;
	for (my $i = 0; $i < @colnames; $i++) {
		my $colname = $colnames[$i];
		next unless ($colname =~ m/^Q(\d+)/);
		if ($qno != $1) {
			$qno = $1;
			$survey_data{"Q$qno"}{'col'} = $i;
		}
	}
}

SURVEY_DATA:
for (my $i = 0; $i < @survey_data; $i += 2) {
	my ($key, $val) = @survey_data[$i,$i+1];
	next unless $key =~ m/^(Q(\d+))$/;

	my $qno = $2;
	my $col = $survey_data{$1}{'col'};

	print "$val->{'title'}\n";
	#print "    $colnames[$col]\n";

	if ($val->{'freeform'}) {
		# free-form essay, single value
		if ($columns[$col] ne '') {
			#print "  (left for later)\n";
			print "\n$columns[$col]\n";
			$response->[$qno] = { 'type' => 'essay', 'contents' => $columns[$col] };
		} else {
			print ". skipped (freeform)\n";
		}

	} elsif (!exists $val->{'codes'}) {
		# free-form, single value
		if ($columns[$col] eq '') {
			print ". skipped (text)\n";
			next;
		}
		print "* $columns[$col]\n";
		if (ref($val->{'hist'}) eq 'CODE') {
			print "! ".$val->{'hist'}->($columns[$col])."\n";
			$response->[$qno] = { 'type' => 'oneline',
				'original' => $columns[$col],
				'contents' => $val->{'hist'}->($columns[$col]) };
		} else {
			$response->[$qno] = { 'type' => 'oneline',
				'contents' => $columns[$col] };
		}

	} elsif (!$val->{'multi'} && !$val->{'columns'}) {
		# single choice
		if ($columns[$col] ne '') {
			print "# [$columns[$col]] $val->{'codes'}[$columns[$col]-1]\n";
			$response->[$qno] = { 'type' => 'single-choice',
				'contents' => $columns[$col] };
		} else {
			print ". skipped (single)\n";
		}
		# single choice with other
		if ($val->{'other'} && $columns[$col+1] ne '') {
			print "o $columns[$col+1]\n";
			$response->[$qno]{'other'} = $columns[$col+1];
		}

	} elsif ($val->{'multi'} && !$val->{'columns'}) {
		# multiple choice
		my $skipped = 1;
		$response->[$qno] = { 'type' => 'multiple-choice',
			'contents' => [] };
		for (my $j = 0; $j < @{$val->{'codes'}}; $j++) {
			next unless ($columns[$col+$j] ne '');
			if ($j == $#{$val->{'codes'}} &&
			    $val->{'other'}) {
				print "o $columns[$col+$j]\n";
				$response->[$qno]{'other'} = $columns[$col+$j];
			} else {
				print "* [$columns[$col+$j]] ".
				      "$val->{'codes'}[$columns[$col+$j]-1]\n";
			}
			push @{$response->[$qno]{'contents'}}, $columns[$col+$j];
			$skipped = 0;
		}
		print ". skipped (multi)\n" if $skipped;

	} elsif ($val->{'columns'}) {
		# matrix
		my $skipped = 1;
		$response->[$qno] = { 'type' => 'matrix',
			'contents' => [] };
		for (my $j = 0; $j < @{$val->{'codes'}}; $j++) {
			next unless ($columns[$col+$j] ne '');
			printf("+ %-30s ", $val->{'codes'}[$j]);
			print "[$columns[$col+$j]]";
			print " $val->{'columns'}[$columns[$col+$j]-1]"
				if ($columns[$col+$j] =~ m/^\d+$/);
			print "\n";
			push @{$response->[$qno]{'contents'}}, $columns[$col+$j];
			$skipped = 0;
		}
		print ". skipped (matrix)\n" if $skipped;
	}

	print "\n";
}

print '-' x 40, "\n";

print Dumper($response);
store($response, "/tmp/jnareb/GitSurvey2009-response.storable");

close $fd
	or die "Could not close file: $!";

#parse_data(\%hist, \%datehist, \%surveyinfo);

#print Data::Dumper->Dump(
#	[\@sections, \%hist, \%datehist, \%surveyinfo],
#	[qw(\@sections \%hist \%datehist \%surveyinfo)]
#);

__END__