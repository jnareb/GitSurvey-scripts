#!/usr/bin/perl

# survey_parse - parse results of syrvey.net.nz survey in CSV format
#
# (C) 2007, Jakub Narebski
#
# This program is licensed under the GPLv2 or later

use strict;
use warnings;

use Text::CSV;
use Text::Wrap;
use Date::Manip;
use Getopt::Long;

use constant DEBUG => 0;
use Data::Dumper;

# ======================================================================
# ----------------------------------------------------------------------

sub normalize_country {
	my $country = shift;

	# cleanup
	$country =~ s/^\s+//;
	$country =~ s/\s+$//;
	$country = ucfirst($country);
	$country =~ s/^The //;

	# corrections
	$country =~ s/^U[Kk]$/United Kingdom/;

	$country =~ s/^United States$/United States of America/;
	$country =~ s/^United States of American$/United States of America/;
	$country =~ s/^USA?$/United States of America/i;
	$country =~ s/^USA! USA! USA!$/United States of America/;

	# expand country code
	# see: /usr/share/zoneinfo/iso3166.tab
	$country =~ s/^NL$/Netherlands/i;
	$country =~ s/^CZ$/Czech Republic/i;
	$country =~ s/^CZE$/Czech Republic/i;
	$country =~ s/^DE$/Germany/i;
	$country =~ s/^AT$/Austria/i;

	# correct and normalize
	$country =~ s/\bSwitzerlang\b/Switzerland/;
	$country =~ s/\bAFrica\b/Africa/;
	$country =~ s/\bNederland\b/Netherlands/;
	$country =~ s/\bNew zealand\b/New Zealand/;
	$country =~ s/^German$/Germany/;
	$country =~ s/^Deutschland$/Germany/;
	$country =~ s/^Czech republic$/Czech Republic/;
	$country =~ s/^Brazil$/Brazil/i;
	$country =~ s/\bBrasil\b/Brazil/;
	$country =~ s/\bAustira\b/Austria/;
	$country =~ s/^German$/Germany/;
	$country =~ s/^Russia$/Russian Federation/;
	$country =~ s/^England$/United Kingdom/;
	$country =~ s/^Scotland$/United Kingdom/;

	return $country;
}

# returns ARRAY
sub normalize_language {
	my $lang = shift;

	# special case
	if ($lang =~ /^LSF/) {
		return ($lang, 'French');
	}

	# cleanup
	$lang =~ s/^\s+//;
	$lang =~ s/\s+$//;
	$lang =~ s/\.$//;
	$lang =~ s/[()]//g;
	$lang =~ s!/! !g;

	# remove "not understood"
	if ($lang =~ /^(What|WTF|Huh\?|human language)/) {
		return 'not understood';
	}

	# remove programming languages
	if ($lang =~ /^(Python|Ruby|XML|Logo|JavaScript|OCaml|Perl|maths?|erlang|C|C\+\+|AWK|bash|Java|C\+\+  perl|C  shell)$/i) {
		return 'invalid (computer language)';
	}

	# remove extra qualifiers
	$lang =~ s/USA\s+English/English/i;
	$lang =~ s/(British|American|US)\s+English/English/i;
	$lang =~ s/([a-z]{2})_[A-Z]{2}/$1/g;

	# strip comments
	$lang =~ s/Depends on who I'm talking to\.\.//;
	$lang =~ s/on the internet//;
	$lang =~ s/in everyday live though  except for Movies where it's english again ;//;
	$lang =~ s/for computer programs//;
	$lang =~ s/I think you mean 'natural language'\?//;
	$lang =~ s/when using computers|otherwise//;
	$lang =~ s/is fine  too//;
	$lang =~ s/I'm fine with git talking english//;
	$lang =~ s/my english is not very well  but would be OK  too//;
	$lang =~ s/\[Actually none\]//;
	$lang =~ s/All languages//;
	$lang =~ s/would be nice  not jeeded  though//;
	$lang =~ s/If not exist yet//;
	$lang =~ s/I speak english\. All translations available should be done//;
	$lang =~ s/personally  I don't\. But I think the most needed would be//;
	$lang =~ s/See answer to question 32//;
	$lang =~ s/My language is//;
	$lang =~ s/Does not apply//;
	$lang =~ s/^n[\/ ]?a$//i;
	$lang =~ s/^(no|none\??|no need|none  l10n stinks)$//i;
	$lang =~ s/not for me//;
	$lang =~ s/^Sanity$//;
	$lang =~ s/^You meant.*$//;
	$lang =~ s/^tlhIngan Hol$//;
	$lang =~ s/^ow$//; # ???
	#$lang =~ s/(^|\W|\s)no(\s|\W|$)//; # ???

	$lang =~ s/\b(and|but|equally|otherwise)\b//;
	$lang =~ s/\bnative\b//;
	$lang =~ s/\bequally\b//;
	$lang =~ s/\bEnglish\?/English/;
	$lang =~ s/:o//;
	$lang =~ s/-+//;
	$lang =~ s/\.+//;

	# corrections
	$lang =~ s/Englisch\b/English/;
	$lang =~ s/Engligh/English/;
	$lang =~ s/\bFrance\b/French/;
	$lang =~ s/\bGermany\b/German/;
	$lang =~ s/\bDeutsch\b/German/;
	$lang =~ s/\bUkrainain\b/Ukrainian/;
	$lang =~ s/\bJapan\b/Japanese/;
	$lang =~ s/\bBrazilian Portuguese\b/Portuguese/;

	# expand language codes
	# see (incomplete): /usr/share/locale/locale.alias
	$lang =~ s/(^|\W|\s)pt(\s|\W|$)/$1Portuguese$2/ig;
	$lang =~ s/(^|\W|\s)en(\s|\W|$)/$1English$2/ig;
	$lang =~ s/(^|\W|\s)de(\s|\W|$)/$1German$2/ig;
	$lang =~ s/(^|\W|\s)fr(\s|\W|$)/$1French$2/ig;
	$lang =~ s/(^|\W|\s)it(\s|\W|$)/$1Italian$2/ig;
	$lang =~ s/(^|\W|\s)sv(\s|\W|$)/$1Swedish$2/ig;
	$lang =~ s/(^|\W|\s)no(\s|\W|$)/$1Norwegian$2/ig; # ???

	# remove leading and trailing spaces after stripping comments
	$lang =~ s/^\s+//;
	$lang =~ s/\s+$//;

	# split multiple answers, normalize
	my @languages = map(ucfirst, split(' ', $lang));

	return @languages;
}

sub normalize_age {
	my $age = shift;

	# extract
	$age =~ s/^[^0-9]*([0-9]+).*$/$1/;

	return $age;

	# quantize
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
		return ' > 75';
	}

	#return $age;
}

# returns ARRAY
sub normalize_heard {
	my $source = shift;
	my @result = ();

	my $orig = $source;

	# cleanup
	$source =~ s/^\s+//;
	$source =~ s/\s+$//;

	# corrections
	$source =~ s/\bmailling\b/mailing/;
	$source =~ s/\bYou ?tube\b/YouTube/;
	$source =~ s/\bLKLM\b/LKML/i;
	$source =~ s/\binernet\b/Internet/;
	$source =~ s/\binternets\b/Internet/;
	$source =~ s/\bThorvalds\b/Torvalds/;
	$source =~ s/\bTorvold\b/Torvalds/;
	$source =~ s/\bco[ -]worker[s]?/coworker/i;
	$source =~ s/\bKernel Trap\b/KernelTrap/i;
	$source =~ s/\b(colligues|collegues)\b/colleagues/i;
	$source =~ s/\bfus\b/fuss/;
	$source =~ s/\brecomendation\b/recommendation/i;
	$source =~ s/\busnig\b/using/i;

	# remove comments
	$source =~ s/^from( the)?\s+//i;
	$source =~ s/^I read about (it )?//;
	$source =~ s/^It was announced in //;
	$source =~ s/^Because of //i;
	$source =~ s/^In a //i;
	$source =~ s/^Probably\s+//i;
	$source =~ s/[(]?I think[)]?/ /;
	$source =~ s/\s*(\?)\s*/ /;

	# categorization
	if ($source =~ s/\b(the )?BK( license withdrawal| fiasco)\b//i ||
	    $source =~ s/^.*\bdropping BK\b.*$//i ||
	    $source =~ s/^.*\bAfter the (BK|BitKeeper) 'breakup'.*$//i ||
	    $source =~ s/^.*\b(switch(ed)?|move) from (BK|BitKeeper) to git\b//i ||
	    $source =~ s/\b(During the |Follow(ing|ed) the .*)?BitKeeper(.*(aftermath|dispute|drama|fallout|fiasco|debacle|situation|media fuss|dropped|become paid|episode|thing|affair))\b//i) {
		push @result, 'BitKeeper news';
	}
	if ($source =~ s/Linux Kernel Developer List//i ||
	    $source =~ s/Linux Developers List//i ||
	    $source =~ s/\b(Linus'? )?(announce(ment)? )?(on )?LKML(\.org)?( announce)?\b//i ||
	    $source =~ s/\b(Linux[- ])?kernel(\.org)? (mailing list|mailing|ml)( archive| FAQ)?\b//i ||
	    $source =~ s/\bLinux([- ]kernel)?(\.org)? (mailing list|mailing|ml)( archive| FAQ)?\b//i ||
	    $source =~ s/\b(the )?kernel mailinglist\b//i ||
	    $source =~ s/^Linux[- ]Kernel list$//i ||
	    $source =~ s/^LKML mailing list$//i ||
	    $source =~ s/^LKML( when.*| mailing list.*)?[?]?$//i) {
		push @result, 'LKML';
	}
	if ($source =~ s/\bSlashdot(\.org)?( article)?\b//i ||
	    $source =~ s!^/\.$!!) {
		push @result, 'Slashdot';
	}
	if ($source =~ s/\bKernelTrap(\.org| coverage)?\b//i) {
		push @result, 'KernelTrap';
	}
	if ($source =~ s/\bKernelTraffic\b//i) {
		push @result, 'KernelTraffic';
	}
	if ($source =~ s/(^.*on |^.*like )?\bLWN(\.net)?\b(\s+when.*$)?//i ||
	    $source =~ s/^Linux Weekly News$//i) {
		push @result, 'LWN';
	}
	if ($source =~ s/\b(browsing )?kernel\.org( web)?\b//i ||
	    $source =~ s/\bLinux kernel website\b//i) {
		push @result, 'kernel.org';
	}
	if ($source =~ s/^(\w*\.)?freedesktop(\.org)?$//i ||
	    $source =~ s/^Linux and (\w*\.)?freedesktop(\.org)?$//i) {
		push @result, 'freedesktop.org';
	}
	if ($source =~ s/\bLinus'?s? Google (video talk|talk|presentation|video|speech|conference at Google Video|tech talk on youtube)\b//i ||
	    $source =~ s/\bLinus'?s? on (git|Google Talks via Google Video)\b//i ||
	    $source =~ s/\bLinus'?s? (Torvalds'?s? )?(tech )?talk[s]?\b.*$//i ||
	    $source =~ s/\bLinus Torvalds GIT webcast\b// ||
	    $source =~ s/\bLinu[xs]'?s? (Torvalds )?(git )?talk at Google\b//i ||
	    $source =~ s/presentation on YouTube\b//i ||
	    $source =~ s/^Google Video.*$//i ||
	    $source =~ s/^Google Tech Talk$// ||
	    $source =~ s/^Linus on git$//i ||
	    $source =~ s/^Google talk from Linus$// ||
	    $source =~ s!(Torvalds.*|Linus.*)?http://www\.youtube\.com/watch[ ?]v4XpnKHJAok8!! ||
	    $source =~ s/^.*video of Linus talking about it.*$// ||
	    $source =~ s/\bLinux on GIT [(]Google Conference[)] video\b// ||
	    $source =~ s/\bLinus told me I was stupid and ugly\b// ||
	    $source =~ s/^(.* on )?YouTube$//i) {
		push @result, 'Linus presentation at Google';
	}
	if ($source =~ s/\b(I )?Can't (recall|remember)\b//i ||
	    $source =~ s/\b(I )?Don't remember\b//i ||
	    $source =~ s/\bdunno\b//) {
		push @result, 'don\'t remember';
	}
	if ($source =~ s/\b(recommendation )?(from )?(a )?friend[s]?( linked.*| told me| of mine)?\b//i ||
	    $source =~ s/\b(a |my )?colleague[s]?\b//i) {
		push @result, 'friend';
	}
	if ($source =~ s/\b(a )?co-?worker[s]?\b//i ||
	    $source =~ s/\b(a )?co-?developer[s]?\b//i ||
	    $source =~ s/\b(a )?fellow (worker|developer)[s]?\b//i ||
	    $source =~ s/\b(a )?project I work with\b//i ||
	    $source =~ s/\b(a )?project manager\b//i ||
	    $source =~ s/\b(through )?(my )?job\b//i ||
	    $source =~ s/\b(company|work)\b//i) {
		push @result, 'work / coworker';
	}
	if ($source =~ s/\bcommunity buzz\b//i ||
	    $source =~ s/\bbuzz on.*$//i ||
	    $source =~ s/\bgeneral buzz\b//i ||
	    $source =~ s/\bword of mouth\b//i ||
	    $source =~ s/\bnetwork chatter\b//i ||
	    $source =~ s/\bthe hype\b//i ||
	    $source =~ s/\beveryone (knows|uses) (it|git)\b//i) {
		push @result, 'word of mouth';
	}
	if ($source =~ s/\bIRC( channel)?\b//i ||
	    $source =~ s/^.*on #lisp.*$//i) {
		push @result, 'IRC';
	}
	if ($source =~ s/\b(variuos )?blog[s]?( entry| post[s]?| really)?\b//i ||
	    $source =~ s/\bweblog\b//i) {
		push @result, 'blog';
	}
	if ($source !~ m/XMMS2 developer/i &&
	    $source =~ s/\b(using )?(WINE|WineHQ|LilyPond|U-Boot|Arch Linux|Beryl|Compiz|Cairo|Elinks|OLPC|One Laptop Per Child|Rubinius|XMMS2|OpenTTD|Source Mage (GNU\/)?Linux|X\.?Org)( projects?| uses it| adopted it| started using it| devel)?\b//i ||
	    $source =~ s/\b(with )?freedesktop(\.org)? projects?\b//i ||
	    $source =~ s/\b(some )?Lisp projects?( were using it)?\b//i ||
	    $source =~ s/\b(FOSS|OSS|other) projects?( involvement)?\b//i ||
	    $source =~ s/\bUse in other projects\b//i ||
	    $source =~ s/\bprojects? using GIT( as SCM)?\b//i) {
		push @result, 'some project uses git';
	}
	if ($source =~ s/^Linus( Torvalds)?$//i ||
	    $source =~ s/\bCarl Worth\b//i ||
	    $source =~ s/\bKeith Packard\b//i ||
	    $source =~ s/\bRalf Baechle\b//i ||
	    $source =~ s/\bRandal Schwartz\b//i ||
	    $source =~ s/\bRyan Anderson\b//i ||
	    $source =~ s/\bSam Vilain\b//i ||
	    $source =~ s/\b(pasky|Petr Baudis)\b//i ||
	    $source =~ s/\bMcVoy\b//i ||
	    $source =~ s/\bTommi Virtanen\b//i ||
	    $source =~ s/\bBart Trojanowski\b//i ||
	    $source =~ s/\bJulio Martinez\b//i) {
		push @result, 'developer by name';
	}
	if ($source =~ s/\b(a |tech )?news.*websites?\b//i ||
	    $source =~ s/\blinux[- ](kernel )?(related )?news\b//i ||
	    $source =~ s/\b(online )?news (feed|site)s?\b//i ||
	    $source =~ s/\bnews about (the )?kernel\b//i ||
	    $source =~ s/\bnews from internet site\b//i ||
	    $source =~ s/\b^news$//i ||
	    $source =~ s/\b^RSS feeds?$//i ||
	    $source =~ s/\b(http:\/\/)?(www\.)?linuxfr\.org\b//i ||
	    $source =~ s/\bOSNews(\.com)?\b//i ||
	    $source =~ s/\bheise\.de\b//i ||
	    $source =~ s/\bLinux\.com\b//i ||
	    $source =~ s/\bNewsForge\b//i ||
	    $source =~ s/^Linux Magazine$//i ||
	    $source =~ s/\b(on (a|some) |from )?(IT |various )?news (site|page)s?\b//i ||
	    $source =~ s/^news$//i) {
		push @result, 'news site';
	}
	if ($source =~ s/\b[\w.]*(Digg|Reddit)[\w.]*\b//i ||
	    $source =~ s/\b^planets?.*\b//i ||
	    $source =~ s/\bGNOME (bloggers|community)\b//i) {
		push @result, 'community site';
	}
	if ($source =~ s/^Google$//i ||
	    $source =~ s/^internet search$//i ||
	    $source =~ s/^search engine$//i) {
		push @result, 'searching Internet';
	}
	if ($source =~ s/\b(SCM|VCS|RCS) comparisons?( table)?\b//i ||
	    $source =~ s/\b(via )?(Arch|Monotone|Mercurial|bzr) mailing list\b//i ||
	    $source =~ s/\bSVK article\b//i ||
	    $source =~ s/\bvia SVN\b//i ||
	    $source =~ s/\balternative to tla\b//i ||
	    $source =~ s/\bresearching (SVN|CVS) alternatives\b//i ||
	    $source =~ s/\bsearch for version control\b//i ||
	    $source =~ s/^.*solve.*SCM problem.*$//i ||
	    $source =~ s/\b(was )?looking for (a )?(D?SCM|VCS|RCS)\b//i ||
	    $source =~ s/\bhg\b//i ||
	    $source =~ s/\b(I )?follow (the )?(VCS|RCS|SCM) field( closely)?\b//i ||
	    $source =~ s/\bDarcs (competitor|mailing list)\b//i ||
	    $source =~ s/\blooking for (SCM|distributed source control)\b//i) {
		push @result, 'other SCM / SCM research';
	}
	if ($source =~ s/\bAs it became SCM.*for kernel\b//i ||
	    $source =~ s/\b(initial|Linus'?( first)?) announcement\b//i ||
	    $source =~ s/\bkernel moving.* announcement\b//i ||
	    $source =~ s/\bwatched initial development\b//i ||
	    $source =~ s/^at (the )?start$//i) {
		push @result, 'initial GIT announcement';
	}
	if ($source =~ s/\b(?<!Articles about )Linux[- ]kernel (devel|compil)\w*\b//i ||
	    $source =~ s/\b(doing )?(Linux|kernel)( driver)? devel\w*\b//i ||
	    $source =~ s/\bfor (the )?Linux kernel//i ||
	    $source =~ s/\bLinux's VCS\b//i ||
	    $source =~ s/\bsome Linux project\b//i ||
	    $source =~ s/\bthe kernel.*it\b//i ||
	    $source =~ s/\blinux[- ]kernel 2\.6\.[0-9]*\b//i ||
	    $source =~ s/\b(Linux )?kernel (was|is) using it\b//i ||
	    $source =~ s/\b(Linux )?kernel use(s|d) it\b//i ||
	    $source =~ s/^(the )?Linux[- ]kernel( use[sd] it| sources)?$//i ||
	    $source =~ s/^(Linux|kernel)( development| compiling| uses it| (was|is) using it)?$//i ||
	    $source =~ s/\b(at )?Linux kernel project\b//i) {
		push @result, 'Linux kernel uses it';
	}
	if (!@result &&
	    $source =~ s/^(the )?Internet$//i ||
	    $source =~ s/^(read.*)?online\.?$//i ||
	    $source =~ s/\bonline sites?\b//i ||
	    $source =~ s/\btech-related website\b//i ||
	    $source =~ s/\bOn the Internet somewhere\b//i ||
	    $source =~ s/^reading.*on the web.*$//i ||
	    $source =~ s/^(the )?(net|web|websites?)$//i) {
		push @result, 'Internet';
	}
	unless (@result) {
		push @result, 'other / uncategorized';
	}

	return @result;
}

sub normalize_version {
	my $line = shift;
	my $version;

	# find version number
	if ($line =~ /\bv?([0-1]\.[0-9]+[.a-z0-9X]*)\b/) {
		$version = $1;
	} elsif ($line =~ /(^|\b)v?([0-1]\.(:?[xX\?]|sth|something))(\b|$)/) {
		$version = $1;
	} else {
		return '(no version string)';
	}

	# cleanup
	$version =~ s/\.?(?:something|sth)/.x/;
	$version =~ s/\.xx+\b/.x/;
	$version =~ s/\.X\b/.x/;
	$version =~ s/ish\b/.x/;
	$version =~ s/^0\.9([^9]*)$/0.99$1/;

	# divide into clusters
	$version =~ s/^0\.[0-9]([^9]+|$)$/0.x/;
	$version =~ s/^0\.99.*$/0.99x/;
	$version =~ s/^(1\.[0-9]).*$/$1x/;

	if ($version !~ /x$/) {
		$version = '';
	}

	return $version;
}

# returns ARRAY
sub normalize_scm {
	my $scm = shift;

	# cleanup
	$scm =~ s/^\s+//;
	$scm =~ s/\s+$//;
	$scm =~ s/[.]//g;

	# N/A or mistakes
	$scm =~ s/^-$//;
	$scm =~ s/^1441$//;

	# corrections
	$scm =~ s/\bsubverion\b/subversion/ig;
	$scm =~ s/\bMecurial\b/Mercurial/ig;
	$scm =~ s/\bCleacase\b/ClearCase/ig;

	# remove comments etc.
	$scm =~ s/\b(and|or|of)\b//ig;
	$scm =~ s/\ba (?:lot|bit|little)?\b//ig;
	$scm =~ s/(?:[(]alas[)]|almost|primari?ly|[(]death[)]|occasionall?y|limited|some(:?times)|formerly|[(]briefly[)]|most)//ig;
	$scm =~ s/\((:?admin|checkout(:?ing)? only)\)//ig;
	$scm =~ s/\b(:?prior to git|check ?out only)\b//ig;
	$scm =~ s/[(]ugg - when I'm forced[)]//ig;
	$scm =~ s/[(]blegh![)]//ig;
	$scm =~ s/[(]currently[)]//ig;
	$scm =~ s/[(]both very seldom[)]//ig;
	$scm =~ s/[(]but not anymore[)]//ig;
	$scm =~ s/[(]?long time ago[)]?//ig;
	$scm =~ s/\bfor (:?different|C programming) projects\b//ig;
	$scm =~ s/\bwhen it existed\b//ig;
	$scm =~ s/\btiny bit\b//ig;
	$scm =~ s/[(]vss some time ago[)]/vss/ig;
	$scm =~ s/\bI use git exclusively now\b//ig;
	$scm =~ s/\bin the (:?distant )?past\b//ig;
	$scm =~ s/\bbut I only use it for upstream commits now\b//ig;
	$scm =~ s/\bI('ve)? used?( to use)?\b//ig;
	$scm =~ s/\b(:?at work|limited|some|others)\b//ig;
	$scm =~ s/\btiny bit of\b//ig;
	$scm =~ s/\bwhen forced\b//ig;
	$scm =~ s/\bswitched from (.*) to git\b/$1/ig;
	$scm =~ s/\bI'm looking at\b//ig;
	$scm =~ s/\bbefore Larry McVoy went insane\b//ig;
	$scm =~ s/\bnow\b//ig;
	$scm =~ s/\s+-\)//g;

	# normalize SCM names
	$scm =~ s/\bgit\b//ig;
	$scm =~ s/\bstg\b//ig;           # StGIT
	$scm =~ s/\b(:?cg|Cogito)\b//ig; # Cogito

	$scm =~ s/\bSCM\b/SCM/ig;
	$scm =~ s/\bCVS\b/CVS/ig;
	$scm =~ s/\bRCS\b/RCS/ig;
	$scm =~ s/\b(:?MS )?VSS\b/VSS/ig;
	$scm =~ s/\bSVK\b/SVK/ig;
	$scm =~ s/\bSCCS\b/SCCS/ig;
	$scm =~ s/\bCVCS\b/CVCS/ig;
	$scm =~ s/\bPVCS(:? dimensions)?\b/PVCS/ig;
	$scm =~ s/\b(?:SVN|Subversion)\b/Subversion/ig;
	$scm =~ s/\bClear ?Case(:? ADE| UCM)?\b/ClearCase/ig;
	$scm =~ s/\bStarTeam\b/StarTeam/ig;
	$scm =~ s/\bAccuRev\b/AccuRev/ig;
	$scm =~ s/\bOmniworks\b/Omniworks/ig;
	$scm =~ s/\bthat awful M\$ one\b/VSS/ig;
	$scm =~ s/\b(:?Visual )?SourceSafe\b/VSS/ig;
	$scm =~ s/\b(?:BK|BitKeeper|B\*tk\*\*p\*r)\b/BitKeeper/ig;
	$scm =~ s/\b(?:Perforce|p4)\b/Perforce/ig;
	$scm =~ s/\bDarcs\b/Darcs/ig;
	$scm =~ s/\bQuilt\b/Quilt/ig;
	$scm =~ s/\b(?:hg|Mercurial)\b/Mercurial/ig;
	$scm =~ s/\b(?:mnt|mtn|Monotone)\b/Monotone/ig;
	$scm =~ s/Arch via Bazaar\(v1\)/Bazaar/ig;
	$scm =~ s/Arch \((:?using )?Bazaar\)/Bazaar/ig;
	$scm =~ s/Arch \((:?Bazaar|baz)\)/Bazaar/ig;
	$scm =~ s/\b(:?baz|Bazaar)\b/Bazaar/ig;
	$scm =~ s/\b(:?bzr|Bazaar[- ]NG)\b/Bazaar-NG/ig;
	$scm =~ s/\btla \(gnu-arch\)/GNU_Arch/ig;
	$scm =~ s/\b(:?GNU )?arch \(tla\)/GNU_Arch/ig;
	$scm =~ s/\btla\s+arch\b/GNU_Arch/ig;
	$scm =~ s/\barch\s+tla\b/GNU_Arch/ig;
	$scm =~ s/\b(:?(:?GNU[\/ ])?Arch|tla)\b/GNU_Arch/ig;
	$scm =~ s/\b(:?Sun )?TeamWare\b/Sun_TeamWare/ig;
	$scm =~ s/\bSun'?s? NSS\b/Sun_NSS/ig;
	$scm =~ s/\bSun'?s? NSE\b/Sun_NSE/ig;
	$scm =~ s/CMS \(digital\)/CMS_(Digital)/ig;
	$scm =~ s/CMS \(VMS\)/CMS_(VMS)/ig;
	$scm =~ s/VAX CMS/CMS_(VAX)/ig;
	$scm =~ s/\bSerena Version Manager\b/Serena_Version_Manager/ig;
	$scm =~ s/\bSourcerer's Apprentice\b/Sourcerer's_Apprentice/ig;
	$scm =~ s/diff[+ ]patch/diff_patch/ig;
	$scm =~ s/patch[+ ]tarballs/diff_patch/ig;
	$scm =~ s/'cp -a'/'cp_-a'/ig;
	$scm =~ s/scripts for 'shadow trees'/scripts_for_'shadow_trees'/ig;
	$scm =~ s/\bakpm patch scripts\b/akpm_patch_scripts/ig;
	$scm =~ s/\bpossibly undisclosed ones\b/undisclosed/ig;
	$scm =~ s/\breally horrible stuff\b/really_horrible_stuff/ig;
	$scm =~ s/\bcustom in-house tools\b/custom_in-house_tools/ig;

	$scm =~ s/\bnone\b/none/ig;

	# convert separators to space
	$scm =~ s![;/&,+]! !g;

	# cleanup whitespace
	$scm =~ s/^\s+//;
	$scm =~ s/\s+$//;

	$scm =~ s/\s+-[)]//g;

	# split
	#return $scm;
	return map { s/_/ /g; $_ } split(' ', $scm);
}

# returns Yes/No
sub normalize_scm_imported {
	my $scm = shift;

	# strip spaces
	$scm =~ s/^\s+//;
	$scm =~ s/\s+$//;

	return '' unless $scm;
	return 'N/A' if ($scm =~ m!^(?:N/?A|-+)$!i);

	if ($scm =~ /^No\.?$/i ||
	    $scm =~ /^No\s+I just put/i ||
	    $scm =~ /^No\s+I'm not/i ||
	    $scm =~ /^No\s+I did not/i ||
	    $scm =~ /^No\s+they don't/i ||
	    $scm =~ /^No\s+too much hassle/i ||
	    $scm =~ /^No\s+started from scratch/i ||
	    $scm =~ /^No\s+applied patches/i ||
	    $scm =~ /^No.\s+Convinced.*to switch/i ||
	    $scm =~ /^No\s+it's hard enough/i ||
	    $scm =~ /^(?:No\s+not yet|not now)/i ||
	    $scm =~ /^(?:none|nope)/i ||
	    $scm =~ /^Not at (?:the moment|this point)/i ||
	    $scm =~ /^Not any ?more/i ||
	    $scm =~ /^Not[- ]yet/i ||
	    $scm =~ /^Not currently/i ||
	    $scm =~ /^No\s+just the Lin[iu]x kernel/i ||
	    $scm =~ /^Haven\'t (?:done|tried)/i) {
		return 'No';
	}
	return 'Yes';
}

# returns ARRAY
sub normalize_scm_importtool {
	my $line = shift;
	my @tools = ();

	return '' unless (defined $line && $line ne '');

	# corrections
	$line =~ s/\bTaylor\b/Tailor/i;
	$line =~ s/csvimport/cvsimport/;

	# by hand
	$line =~ /\b(?:by hand|just patch|untarred|manually|hand\.\.\.)\b/i ||
		$line =~ /\bhandcrafted partial solution\b/i ||
		$line =~ /\b(?:git[- ]checkout|git[- ]apply|git-format-patch|core[- ]git|bare git tools|command line tools|manual merging|git\/shell|vim\s+diff)\b/i ||
		$line =~ /^tar$/i
		and push @tools, 'by hand';
	# script or fast-import script
	$line !~ /\bgit-fast-?import\b/ &&
		($line =~ /\b(?:shell|custom|own|naive) (?:script|tool)[s]?\.?\b/i ||
		 $line =~ /\b(?:custom[- ]written|self[- ]made)\b/i ||
		 $line =~ /\b(?:customized|own|self-written|wrote|hand(?: rolled|woven|crafted)|homemade).*scripts?\b/i ||
		 $line =~ /\b(?:cvsps\s+homegrown|home-?brew script)\b/i ||
		 $line =~ /custom (?:for others?|in[- ]?house)/ ||
		 $line =~ /(?:self-haxxored python|in[- ]?house) tool/ ||
		 $line =~ /script (?:I )?(?:made|wrote)/i ||
		 $line =~ /^the shell$/ ||
		 $line =~ /roll my own/ ||
		 $line =~ /some scripts?/i ||
		 $line =~ /custom python hack/i ||
		 $line =~ /Homegrown Perl monster/i)
		and push @tools, 'custom script';
	$line =~ /\bgit-fast-?import\b/
		and push @tools, 'fast-import script';

	# universal
	$line =~ /\bTailor\b/i
		and push @tools, 'Tailor';
	$line =~ /\bconvert-repo\b/i
		and push @tools, 'convert-repo';
	# CVS
	$line =~ /\b(?:git[- ])?cvs-?import\b/ ||
		$line =~ /\bgit-cvs(?: \+ scripts)?$/ ||
		$line =~ /^git-cvs[\/ ]/
		and push @tools, 'git-cvsimport';
	$line =~ /\bgit[- ]cvsexportcommit\b/
		and push @tools, 'git-cvsexportcommit';
	$line =~ /\bgit[- ]cvsserver\b/ ||
		$line =~ /\bgitserver\b/
		and push @tools, 'git-cvsserver';
	$line =~ /\b(?:parsecvs|cvsparse|Keith Packard'?s?)(?! doesn't work)\b/
		and push @tools, 'parsecvs';
	$line =~ /\bcvstogit\b/
		and push @tools, 'cvstogit';
	$line =~ /^cvs2git$/
		and push @tools, 'cvs2git';
	$line =~ /\bfromcvs\b/
		and push @tools, 'fromcvs';
	# Subversion (svn)
	$line !~ /git svn init.*git svn import/ &&
		($line =~ /\b(?:git[- ])?svn[- ]?import\b/ ||
		 $line =~ /\bsvn import tool\b/)
		and push @tools, 'git-svnimport';
	$line =~ /\bgit[- ]svn(?:\.perl|\.pl)?(?!\*|[- ]import)\b/ ||
		$line =~ /\bsvn-git\b/
		and push @tools, 'git-svn';
	$line =~ /\bgit-svn\*/
		and push @tools, 'git-svn', 'git-svnimport';
	# Arch (tla, baz, bzr)
	$line =~ /\b(?:git[- ])?arch-?import\b/
		and push @tools, 'git-archimport';
	# Perforce (p4)
	$line =~ /\bgit-p4-?import(?:\.bat)?\b/
		and push @tools, 'git-p4import';
	$line =~ /\bgit-?p4(?:[^-]| |$)/
		and push @tools, 'git-p4';
	# Mercurial (hg)
	$line =~ /\bhgpullsvn\b/
		and push @tools, 'hgpullsvn';
	$line =~ /\bhgsvn\b/
		and push @tools, 'hgsvn';
	$line =~ /\bhg2git\b/
		and push @tools, 'hg2git';
	$line =~ /\bhg-to-git\b/
		and push @tools, 'hg-to-git';
	# Darcs
	$line =~ /\bdarcs[2\/]git(?:\.py)?\b/
		and push @tools, 'darcs2git';
	# ClearCase UCM
	$line =~ /\bgit-ucmimport(?:\.rb)?\b/
		and push @tools, 'git-ucmimport';
	# BitKeeper
	$line =~ /custom.*bk2git/i
		and push @tools, 'bk2git (customized)';
	# Moin?
	$line =~ /\bmoin2git\b/
		and push @tools, 'moin2git';
	# Eclipse?
	$line =~ /\bEclipse\b/i
		and push @tools, 'Eclipse';

	# special cases
	$line =~ /git-\{svs cvs\}import/
		and push @tools, 'git-cvsimport', 'git-svnimport';

	$line =~ /^(?:an )?importer$/i ||
		$line =~ /\bgit-[*]?import\b/ ||
		$line =~ /^(?:the )?included one$/i ||
		$line =~ /\b(?:stock|default|standard) (?:git )?tools?\b/i ||
		$line =~ /\bsomething from git\b/i ||
		$line =~ /\bscripts included with git\b/i ||
		$line =~ /\bdon't know\b/i ||
		$line =~ /^can't remember/i ||
		$line =~ /^git$/ ||
		$line =~ /^SCCS->CVS->GIT$/i
		and push @tools, 'unspecified';
	$line =~ m!^(?:none(?: yet)?|no(?:thing)?|-+|N/?A|\.+|/|(?:I )?(?:did|have)n't|x|\?)\.?$!i ||
		$line =~ /^None \(see previous answer\)/ ||
		$line =~ /\bhave no time\b/i ||
		$line =~ /\b(?:not applicable|nothing yet|does not apply)\.?\b/i ||
		$line =~ /^(?:I didn't do (?:it|the import)|I said no|I haven't use)/
		and push @tools, 'N/A';

	return @tools;
}

# returns ARRAY
sub normalize_march {
	my $line = shift;
	my @arch = ();

	my %known_arch =
		('i386' => undef,
		 'i586' => undef,
		 'i686' => undef,
		 'AMD' => undef,
		 'amd64' => undef,
		 'x86' => undef,
		 'x86-64' => undef,
		 'IA-32' => undef,
		 'IA-64' => undef,
		 'PPC' => undef,
		 'ppc64' => undef,
		 'Intel' => undef,
		 'Athlon' => undef,
		 'Alpha' => undef,
		 'SPARC' => undef,
		 'sparc64' => undef,
		 'MIPS' => undef,
		 'mips64' => undef,
		 'mipsel' => undef,
		 'RS/600' => undef,
		 'RS/6000' => undef,
		 'PA-RISC' => undef,
		 'parisc64' => undef,
		 'Sun-Fire' => undef,
		 'SUNW' => undef,
		 'sun4u' => undef,
		 'sun4v' => undef,
		 'S360' => undef,
		 'k8' => undef,
		 'ARM' => undef,
		 'Apple' => undef,
		 'MacBook' => undef,
		 'PowerBook' => undef,
		 'iMac' => undef,
		);

	return '' unless (defined $line && $line ne '');

	# normalize architecture names
	$line =~ s/\b(?:PowerPC|PPC)\b/PPC/ig;
	$line =~ s/\b(?:PowerPC|PPC)64\b/ppc64/ig;
	$line =~ s/\bamd64\b/amd64/ig;
	$line =~ s/\bx8[64][-_]32\b/x86/ig;
	$line =~ s/\bx8[64][-_](?:64|86)\b/x86-64/ig;
	$line =~ s/\b(?:Genuine)?Intel\b/Intel/ig;
	$line =~ s/\b(?:Authentic)?AMD\b/AMD/ig;
	$line =~ s/\bAlpha\b/Alpha/ig;
	$line =~ s/\bSPARC\b/SPARC/ig;
	$line =~ s/\bMIPS\b/MIPS/ig;
	$line =~ s/\bPA-RISC\b/PA-RISC/ig;
	$line =~ s!\bRS/600\b!RS/600!ig;
	$line =~ s/\bARM\b/ARM/ig;
	$line =~ s/\bIA[-_]?32\b/IA-32/ig;
	$line =~ s/\bIA[-_]?64\b/IA-64/ig;
	$line =~ s/\bMacBook[0-9]*\b/MacBook/ig;
	$line =~ s/\bPowerBook[0-9]*\b/PowerBook/ig;
	$line =~ s/\bSun-Fire[-v0-9]*\b/Sun-Fire/ig;

	$line =~ s/\bPentium\b/i586/ig;
	$line =~ s/\bCore Duo\?\b/Intel/ig;
	$line =~ s/\bIntel x86\b/x86/ig;
	$line =~ s/\bppc \(?32 & 64\b/PPC ppc64/ig;
	$line =~ s/\bAMD 64\b/amd64/ig;
	$line =~ s/\bi686 (AMD)\b/AMD/ig;
	$line =~ s/\bAMD [0-9]* (x86)\b/x86/ig;
	$line =~ s/\bamd64\s+i386\b/amd64/ig;
	$line =~ s/\bix86\b/x86/ig;
	$line =~ s/\bia86\b/IA-64/ig;
	$line =~ s!\bx86-32/64\b!x86 x86_64!ig;
	$line =~ s/\bStrongARM\b/ARM/ig;
	$line =~ s/\barmv5tel\b/ARM/ig;
	#$line =~ s/\bSUN\b/SUNW/g;
	$line =~ s/\bintel32\b/i386/ig;
	$line =~ s/\b([3-6])86\b/i${1}86/ig;
	$line =~ s/\bPower MacIntosh\b/PowerBook/ig;
	$line =~ s/\bIntel.*?x86/x86/ig;
	$line =~ s/\bApple (iMac|PowerBook|MacBook)/$1/ig;
	if ($line !~ /\b(?:(?:Mac|Power)Book|PPC)\b/i) {
		$line =~ s/\bG4\b/PowerBook/ig;
	}
	if ($line !~ /\b(?:MacBook|PowerBook|Apple)\b/i) {
		$line =~ s/\bDarwin\b/Apple/ig;
	}

	# replace separators with whitespace
	$line =~ s![;/()]! !g;

	# return only known architectures
	foreach my $a (split ' ', $line) {
		if (exists $known_arch{$a}) {
			push @arch, $a;
		}
	}
	push @arch, 'unknown' unless @arch;

	return @arch;
}

# returns ARRAY
sub normalize_os {
	my $line = shift;
	my @os_list = ();

	# corrections
	$line =~ s/Max/Mac/i;
	$line =~ s/Cygnus/Cygwin/i;
	$line =~ s/\bWindow\b/Windows/i;

	# Linux, sometimes only distribution name
	if ($line =~ /Linux/i ||
	    $line =~ /(?:ubuntu|Debian|Gentoo|Fedora|Mandriva|
	               SuSE|RHEL|RedHat|CentOS|Slackware|RawHide|
	               SimplyMEPIS|FC[0-9]|2\.[46]\.[0-9]+)/ix) {
		push @os_list, 'Linux';
	}
	# Windows, different flavours
	if ($line =~ /Cygwin/i) {
		push @os_list, 'MS Windows (Cygwin)';
	} elsif ($line =~ /msys/i) {
		push @os_list, 'MS Windows (msys)';
	} elsif ($line =~ /(?:Windows|Win(?:XP|2k)|\bw2k\b)/i) {
		push @os_list, 'MS Windows (unsp.)';
	}
	# MacOS X and Darwin
	if ($line =~ /(?:Darwin|Mac[ ]?OS|OS[ ]?X)/i) {
		push @os_list, 'MacOS X / Darwin';
	}
	# *BSD
	if ($line =~ /FreeBSD/i) {
		push @os_list, 'FreeBSD';
	}
	if ($line =~ /OpenBSD/i) {
		push @os_list, 'OpenBSD';
	}
	# other
	if ($line =~ /Solaris/i) {
		push @os_list, 'Solaris';
	}
	if ($line =~ /HP-UX/i) {
		push @os_list, 'HP-UX';
	}
	if ($line =~ /AIX/i) {
		push @os_list, 'AIX';
	}
	if ($line =~ /SunOS/i) {
		push @os_list, 'SunOS';
	}
	# generic
	if ($line =~ /UNIX/i) {
		push @os_list, 'UNIX (unsp.)';
	}

	push @os_list, $line unless @os_list;

	return @os_list;
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
# ......................................................................

my @sections =
	({'title' => 'About you',
	  'start' => 0},
	 {'title' => 'Getting started with GIT',
	  'start' => 5},
	 {'title' => 'Other SCMs',
	  'start' => 10},
	 {'title' => 'How you use GIT',
	  'start' => 18},
	 {'title' => 'Internationalization',
	  'start' => 31},
	 {'title' => 'What you think of GIT',
	  'start' => 34},
	 {'title' => 'Changes in GIT'.
	             ' (since year ago, or since you started using it)',
	  'start' => 39},
	 {'title' => 'Documentation',
	  'start' => 44},
	 {'title' => 'Getting help, staying in touch',
	  'start' => 53},
	 {'title' => 'Open forum',
	  'start' => 62});




my @questions =
	(undef, # questions are numbered from 1
	 {'title' => '01. What country are you in?',
	  'hist' => \&normalize_country,
	  'survey2006' =>
		{
		 'Australia' => 3,
		 'Austria' => 2,
		 'Belarus' => 1,
		 'Brazil' => 2,
		 'Canada' => 3,
		 'Chile' => 1,
		 'China' => 2,
		 'Czech Republic' => 2,
		 'Denmark' => 4,
		 'Estonia' => 1,
		 'Europe' => 1,
		 'Finland' => 5,
		 'France' => 6,
		 'Germany' => 14,
		 'India' => 1,
		 'Italy' => 3,
		 'Lithuania' => 1,
		 'Netherlands' => 3,
		 'Norway' => 1,
		 'Philippines' => 1,
		 'Poland' => 3,
		 'Russia' => 2,
		 'South Africa' => 1,
		 'Spain' => 2,
		 'Sweden' => 6,
		 'Switzerland' => 1,
		 'UAE' => 1,
		 'United Kingdom' => 8,
		 'United States of America' => 35,
		 'Vietnam' => 1
		}},
	 {'title' => '02. What is your preferred non-programming language?',
	  'hist' => \&normalize_language,
	  'survey2006' =>
		{
		 'Belarusian' => 1,
		 'Chinese' => 1,
		 'Czech' => 2,
		 'Danish' => 5,
		 'Dutch' => 4,
		 'English' => 71,
		 'Estonian' => 1,
		 'Finnish' => 4,
		 'French' => 5,
		 'German' => 12,
		 'Italian' => 3,
		 'Japanese' => 1,
		 'Polish' => 3,
		 'Russian' => 4,
		 'Spanish' => 4,
		 'Swedish' => 5,
		 'Vietnamese' => 1,
		}},
	 {'title' => '03. How old are you?',
	  'histogram' => 
		{' < 18' => 0,
		 '18-21' => 0,
		 '22-25' => 0,
		 '26-30' => 0,
		 '31-40' => 0,
		 '41-50' => 0,
		 '51-75' => 0,
		 '76+  ' => 0},
	  'hist' => \&normalize_age},
	 {'title' => '04. Which programming languages you are proficient with?',
	  'codes' => [undef, 'C', 'shell', 'Perl', 'Python', 'Tcl/Tk']},
	 {'title' => '05. How did you hear about GIT?',
	  'hist' => \&normalize_heard},
	 {'title' => '06. Did you find GIT easy to learn?',
	  'codes' => [undef,'very easy','easy','reasonably','hard','very hard'],
	  'survey2006' =>
		{
		 'very easy'  =>  6,
		 'easy'       => 21,
		 'reasonably' => 64,
		 'hard'       => 23,
		 'very hard'  =>  3,
		}},
	 {'title' => '07. What helped you most in learning to use it?',
	  'freeform' => 1},
	 {'title' => '08. What did you find hardest?',
	  'freeform' => 1},
	 {'title' => '09. When did you start using git? From which version?',
	  'hist' => \&normalize_version},
	 {'title' => '10. What other SCMs did/do you use?',
	  'hist' => \&normalize_scm},
	 {'title' => '11. Why did you choose GIT?',
	  'freeform' => 1},
	 {'title' => '12. Why did you choose other SCMs?',
	  'freeform' => 1},
	 {'title' => '13. What would you require from GIT to enable you to change, '.
	             'if you use other SCM for your project?',
	  'freeform' => 1},
	 {'title' => '14. Did you import your repository from foreign SCM? What SCM?',
	  'hist' => \&normalize_scm_imported},
	 {'title' => '15. What tool did you use for import?',
	  'hist' => \&normalize_scm_importtool},
	 {'title' => '16. Do your GIT repository interact with other SCM? Which SCM?',
	  'hist' => \&normalize_scm_imported},
	 {'title' => '17. What tool did/do you use to interact?',
	  'hist' => \&normalize_scm_importtool},
	 {'title' => '18. Do you use GIT for work, unpaid projects, or both?',
	  'codes' => [undef,'work','unpaid projects','both'],
	  'survey2006' =>
		{
		 'work' => 14,
		 'unpaid projects' => 50,
		 'both' => 53,
		}},
	 {'title' => '19. How do you obtain GIT?',
	  'codes' =>
		[undef,
		 'binary package',
		 'source tarball',
		 'pull from main repository'],
	  'survey2006' =>
		{
		 'source tarball' => 33,
		 'binary package' => 31,
		 'pull from main repository' => 53,
		}},
	 {'title' => '20. What hardware platforms do you use GIT on? '.
	             '(on Unices: result of "uname -i")',
	  'hist' => \&normalize_march},
	 {'title' => '21. What OS (please include the version) do you use GIT on?',
	  'hist' => \&normalize_os},
	 {'title' => '22. What projects do you track (or download) using GIT '.
	             '(or git web interface)?',
	  'hist' => 1},
	 {'title' => '23. How many people do you collaborate with using GIT?',
	  'hist' => 1},
	 {'title' => '24. How big are the repositories that you work on?',
	  'freeform' => 1},
	 {'title' => '25. How many different projects do you manage using GIT?',
	  'hist' => 1},
	 {'title' => '26. Which porcelains do you use?',
	  'codes' =>
		[undef,
		 'core-git',
		 'cogito (deprecated)',
		 'StGIT',
		 'guilt',
		 'pg (deprecated)',
		 'own scripts',
		 'other']},
	 {'title' => '27. Which git GUI do you use?',
	  'codes' =>
		[undef,
		'CLI (command line)',
		'gitk',
		'git-gui',
		'qgit',
		'gitview',
		'giggle',
		'tig',
		'instaweb',
		'(h)gct',
		'qct',
		'KGit',
		'git.el',
		'other']},
	 {'title' => '28. Which (main) git web interface do you use for your projects?',
	  'codes' =>
		[undef,
		'gitweb',
		'cgit',
		'wit (Ruby)',
		'git-php',
		'other']},
	 {'title' => '29. How do you publish/propagate your changes?',
	  'codes' =>
		[undef,
		'push',
		'pull',
		'pull request',
		'format-patch + email',
		'bundle',
		'other']},
	 {'title' => '30. Does git.git repository include code produced by you?',
	  'codes' => [undef,'Yes','No'],
	  'survey2006' => {'Yes' => 73, 'No' => 34}},
	 {'title' => '31. Is translating GIT required for wider adoption?',
	  'codes' => [undef,'Yes','No','Somewhat']},
	 {'title' => '32. What do you need translated?',
	  'hist' => 1},
	 {'title' => '33. For what language do you need translation for?',
	  'hist' => \&normalize_language},
	 {'title' => '34. Overall, how happy are you with GIT?',
	  'codes' =>
		[undef,
		'unhappy',
		'not so happy',
		'happy',
		'very happy',
		'completely ecstatic'],
	  'survey2006' =>
		{
		 'unhappy' => 1,
		 'not so happy' => 19,
		 'happy' => 53,
		 'very happy' => 41,
		 'completely ecstatic' => 1,
		}},
	 {'title' => '35. How does GIT compare to other SCM tools you have used?',
	  'codes' => [undef,'Better','Equal (comparable)','Worse'],
	  'survey2006' =>
		{
		 'Better' => 80,
		 'Equal (comparable)' => 20,
		 'Worse' => 8,
		}},
	 {'title' => '36. What do you like about using GIT?',
	  'freeform' => 1},
	 {'title' => '37. What would you most like to see improved about GIT? '.
	             '(features, bugs, plug-ins, documentation, ...)',
	  'freeform' => 1},
	 {'title' => '38. If you want to see GIT more widely used, '.
	             'what do you think we could do to make this happen?',
	  'freeform' => 1},
	 {'title' => '39. Did you participate in previous Git User\'s Survey?',
	  'codes' => [undef,'Yes','No']},
	 {'title' => '40. What improvements you wanted got implemented?',
	  'hist' => 1},
	 {'title' => '41. What improvements you wanted didn\'t get implemented?',
	  'hist' => 1, 'freeform' => 1},
	 {'title' => '42. How do you compare current version '.
	             'with version from year ago?',
	  'codes' => [undef,'Better','No changes','Worse']},
	 {'title' => '43. Which of the new features do you use?',
	  'codes' =>
		[undef,
		'git-gui',
		'bundle',
		'eol conversion',
		'gitattributes',
		'submodules',
		'worktree',
		'reflog',
		'stash',
		'detached HEAD',
		'shallow clone',
		'mergetool',
		'interactive rebase',
		'commit template',
		'blame improvements']},
	 {'title' => '44. Do you use the GIT wiki?',
	  'codes' => [undef,'Yes','No']},
	 {'title' => '45. Do you find GIT wiki useful?',
	  'codes' => [undef,'Yes','No','Somewhat']},
	 {'title' => '46. Do you contribute to GIT wiki?',
	  'codes' => [undef,'Yes','No','Corrections and removing spam']},
	 {'title' => '47. Do you find GIT\'s on-line help '.
	             '(homepage, documentation) useful?',
	  'codes' => [undef,'Yes','No','Somewhat'],
	  'survey2006' =>	{'Yes' => 88, 'No' => 20}},
	 {'title' => '48. Do you find help distributed with GIT useful '.
	             '(manpages, manual, tutorial, HOWTO, release notes)?',
	  'codes' => [undef,'Yes','No','Somewhat']},
	 {'title' => '49. Did/Do you contribute to GIT documentation?',
	  'codes' => [undef,'Yes','No']},
	 {'title' => '50. What could be improved on the GIT homepage?',
	  'freeform' => 1},
	 {'title' => '51. What topics would you like to have on GIT wiki?',
	  'freeform' => 1},
	 {'title' => '52. What could be improved in GIT documentation?',
	  'freeform' => 1},
	 {'title' => '53. Have you tried to get GIT help from other people?',
	  'codes' => [undef,'Yes','No'],
	  'survey2006' =>	{'Yes' => 68, 'No' => 45}},
	 {'title' => '54. If yes, did you get these problems resolved quickly '.
	             'and to your liking?',
	  'codes' => [undef,'Yes','No'],
	  'survey2006' =>	{'Yes' => 50, 'No' => 19}},
	 {'title' => '55. Would commerical (paid) support from a support vendor '.
	             'be of interest to you/your organization?',
	  'codes' => ['Not Applicable','Yes','No']},
	 {'title' => '56. Do you read the mailing list?',
	  'codes' => [undef,'Yes','No'],
	  'survey2006' =>	{'Yes' => 67, 'No' => 50}},
	 {'title' => '57. If yes, do you find the mailing list useful?',
	  'codes' => [undef,'Yes','No','Somewhat']},
	 {'title' => '58. Do you find traffic levels on GIT mailing list OK?',
	  'codes' => [undef,'Yes','No']},
	 {'title' => '59. Do you use the IRC channel (#git on irc.freenode.net)?',
	  'codes' => [undef,'Yes','No'],
	  'survey2006' =>	{'Yes' => 23, 'No' => 93}},
	 {'title' => '60. If yes, do you find IRC channel useful?',
	  'codes' => [undef,'Yes','No','Somewhat']},
	 {'title' => '61. Did you have problems getting GIT help on mailing list '.
	             'or on IRC channel? What were it? What could be improved?',
	  'hist' => 1, 'freeform' => 1},
	 {'title' => '62. What other comments or suggestions do you have '.
	             'that are not covered by the questions above?',
	  'freeform' => 1},
);

# ----------------------------------------------------------------------

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

sub uniq_cmp (@) {
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

# ======================================================================
# ======================================================================
# ======================================================================
# MAIN

my $csv = Text::CSV->new();
my $line;
my $ident = '';
my $responses = 0;

my ($hist_resp, $test_resp, $free_resp, $resp);

my %datehist = ();

GetOptions('hist|h=i' => \$hist_resp,
           'test|t=i' => \$test_resp,
           'free|f=i' => \$free_resp);
$resp = $hist_resp || $test_resp || $free_resp;

foreach my $q (@questions) {
	if (!exists $q->{'histogram'} &&
	    ($q->{'codes'} || ref($q->{'hist'}) eq 'CODE')) {
		$q->{'histogram'} = {};
	}
}

LINE:
while ($line = <>) {
	last LINE unless defined $line;

	chomp $line;
	unless ($line) {
		print "$.: end of data\n" if DEBUG;
		last LINE;
	}

	$line =~ s/[[:cntrl:]]//;
	#$line =~ s/[^[:print:]]//;

	# continuation line
	if ($line =~ s/!$//) {
		$line .= <>;
		redo LINE unless eof();
	}

	unless ($csv->parse($line)) {
		my $err = $csv->error_input();

		print STDERR "$.: parse() failed on argument: $err\n";
		next LINE;
	}

	my @columns = $csv->fields();

	# "Ident","Date","Time","Question Number","Response"
	unless (@columns == 5 &&
	        $columns[0] =~ /^[a-fA-F0-9]{13}$/ &&
	        $columns[1] =~ /^[0-9]{2}-[0-9]{2}-[0-9]{4}$/ &&
	        $columns[2] =~ /^[0-9]{2}:[0-9]{2}$/ &&
	        $columns[3] =~ /^[0-9]+$/) {
		print "$.: skipped $line\n" if DEBUG;
		next LINE;
	}

	# new responder (new ident)
	if ($columns[0] ne $ident) {
		$ident = $columns[0];
		$responses++;

		my $date = $columns[1];
		add_to_hist(\%datehist, $date);
	}

	my $questionno = $columns[3];
	my $response   = $columns[4];

	my $q = $questions[$questionno];

	# dump responses, or debug tabularization / normalizing responses
	if ($resp && $questionno eq $resp && $response ne '') {
		if ($hist_resp && ref($q->{'hist'}) eq 'CODE') {
			print join("\n", $q->{'hist'}->($response)) . "\n";
		} elsif ($test_resp && ref($q->{'hist'}) eq 'CODE') {
			print "$response\n => [" .
			      join(",", $q->{'hist'}->($response)) .
			      "]\n";
		} elsif ($free_resp) {
			$response =~ s/  /\n\n/g;
			print "*".fill(" ", '', $response) . "\n\n";
		}

		next LINE;
	}


	# count non-empty responses
	add_to_hist($q, 'base')
		if (defined $response && $response !~ /^\|*$/);

	# histogrammed free-form answer, with categorizing subroutine
	if (ref($q->{'hist'}) eq 'CODE' &&
	    defined $response && $response ne '') {
		my $hist = $q->{'histogram'};
		foreach my $ans ($q->{'hist'}->($response)) {
			add_to_hist($hist, $ans);
		}
	}

	# multiple choice or single choice question
	if (exists $q->{'codes'}) {
		my $hist = $q->{'histogram'};
		foreach my $ans (split(/\|/, $response)) {
			add_to_hist($hist, $ans);
		}
	}

}

exit 0 if $resp;


print "There were $responses individual responses\n";

#print Dumper(\@questions);

if (exists $sections[0]) {
	print "\n\n" . $sections[0]{'title'} . "\n" .
	      '~' x length($sections[0]{'title'}) .
	      "\n";
}


print "00. Date of response\n\n";
my ($dates_before, $dates_during, $dates_after) = (0,0,0);
my $date_start = ParseDate('2007-08-20');
my $date_end   = ParseDate('2007-09-10');
foreach my $date (sort keys %datehist) {
	my $ch_date = $date;
	$ch_date =~ s!-!/!g;

	print "  ";
	if (Date_Cmp($ch_date, '2007-08-20') < 0) {
		$dates_before += $datehist{$date};
		print "<";
	} elsif (Date_Cmp($ch_date, '2007-09-10') > 0) {
		$dates_after  += $datehist{$date};
		print ">";
	} else {
		$dates_during += $datehist{$date};
		print "=";
	}

	print " $date: $datehist{$date}\n";
}

print "\n";
printf("  %-30s | %s\n", "Date", "Count");
print  "  ", '-' x 42, "\n";

printf("  %-30s | %d\n", 'Before', $dates_before);
printf("  %-30s | %d\n", 'During', $dates_during);
printf("  %-30s | %d\n", 'After',  $dates_after);

print  "  ", '-' x 42, "\n";


($dates_before, $dates_during, $dates_after) = (0,0,0);
$date_start = ParseDate('2007-08-19');
$date_end   = ParseDate('2007-09-11');
foreach my $date (sort keys %datehist) {
	my $ch_date = $date;
	$ch_date =~ s!-!/!g;

	if (Date_Cmp($ch_date, $date_start) < 0) {
		$dates_before += $datehist{$date};
	} elsif (Date_Cmp($ch_date, $date_end) > 0) {
		$dates_after  += $datehist{$date};
	} else {
		$dates_during += $datehist{$date};
	}
}

print "\n";
printf("  %-30s | %s\n", "Date", "Count");
print  "  ", '-' x 42, "\n";

printf("  %-30s | %d\n", 'Before', $dates_before);
printf("  %-30s | %d\n", 'During', $dates_during);
printf("  %-30s | %d\n", 'After',  $dates_after);

print  "  ", '-' x 42, "\n";


my $nextsect = 1;

QUESTION:
for (my $i = 1; $i <= $#questions; ++$i) {
	my $q = $questions[$i];

	# section header
	if (exists $sections[$nextsect] &&
	    $sections[$nextsect]{'start'} <= $i) {
		print "\n\n" . $sections[$nextsect]{'title'} . "\n" .
		      '~' x length($sections[$nextsect]{'title'}) .
		      "\n";
		$nextsect++;
	}

	print "\n$q->{'title'}\n";

	unless (exists $q->{'histogram'} &&
	        scalar $q->{'histogram'}) {
		print "\n".
		      "  ".($q->{'hist'} ? 'TO TABULARIZE' : 'TO DO')."\n".
		      "  $q->{'base'} / $responses non-empty responses\n".
		      "\n";
		next QUESTION;
	}

	my @answers = ();
	print "\n";
	if (exists $q->{'survey2006'}) {
		printf("  %-30s | %3s | %s\n", "Answer", "Old", "Count");
		print  "  ", '-' x 48, "\n";

		if (exists $q->{'codes'}) {
			@answers = sort keys %{$q->{'histogram'}};
		} else {
			@answers = uniq_cmp(sort(keys %{$q->{'histogram'}},
			                         keys %{$q->{'survey2006'}}));
		}
	} else {
		printf("  %-30s | %s\n", "Answer", "Count");
		print  "  ", '-' x 42, "\n";

		@answers = sort keys %{$q->{'histogram'}};
	}

	my ($sum_old, $sum) = (0,0);
	foreach my $a (@answers) {
		my $name;
		if (exists $q->{'codes'} && $q->{'codes'}[$a]) {
			$name = $q->{'codes'}[$a];
		} else {
			$name = $a;
		}
		printf("  %-30s | ", $name);

		if (exists $q->{'survey2006'}) {
			if (exists $q->{'survey2006'}{$name}) {
				printf("%-3d | ", $q->{'survey2006'}{$name});
				$sum_old += $q->{'survey2006'}{$name};
			} else {
				print "    | ";
			}
		}

		if (exists $q->{'histogram'}{$a}) {
			print $q->{'histogram'}{$a};
			$sum += $q->{'histogram'}{$a};
		}

		print "\n";
	}

	if (exists $q->{'survey2006'}) {
		print  "  ", '-' x 48, "\n";

		printf("  %-30s |     | ", "Base");
		print "$q->{'base'} / $responses\n";

		printf("  %-30s | %-3d | %-3d\n\n",
		       "Total (sum)", $sum_old, $sum);
	} else {
		print  "  ", '-' x 42, "\n";

		printf("  %-30s | ", "Base");
		print "$q->{'base'} / $responses\n";

		printf("  %-30s | ", "Total (sum)");
		print "$sum\n\n";
	}
}

__END__
