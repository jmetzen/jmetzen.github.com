#!/usr/bin/perl -w

# *Copyright:
#
#    Copyright (C) 2000,2001,2002 Patrick Riley
#
#     This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
# *EndCopyright:

# see directions.txt for instructions on how to use this
# pay attention to warnings that you get!
# it's probably trying to tell you that you have missing fields

use File::Basename;
use File::Copy;
# Many people don't have the Time::Zone package, so I'll remove the dependence
#use Time::Zone;
use Cwd;

use ConfFileParser;

$version = "0.94";
$version_date = "March 11, 2006";
$programname = "bib2html.pl";
$programurl = "https://sourceforge.net/projects/bib2html/";
$author = "Patrick Riley";
$authorurl = "http://sourceforge.net/users/patstg/";

# some notes about how this works
# Each bib entry is a hash of fields to values
# all keys are lowercased,
# special keys:
# TYPE: main entry type (lowercased)
# KEY: main key value (not case adjusted)
# ALTKEYS: list reference to alternate keys for this entry
# BIBTEX: the entire original bibtex entry
# and these are the only ones guarunteed to exist
# @bibentry is a list of references to hashes representing all of the entries
# @pruned_bibentry is a list of references to hashes representing all of the entries
# %strings is a hash of all the @string values used
# @main_pages is a list of the main pages that will be generated (does not include detail pages)
#   Each element is [type, output_file, name]
# @generated_xml_files is a list of all the xml generated files
# @file_formats is a list of file formats (which are all extensions) to check for files
# @allowed: somefunctions use this as a list of (formatted) allowed author names
# %conf are parameters read from the configuration file
# $scriptdir is the canonical path for the script directory

##############
## Parsing functions

## this does all the hard work of reading in an entry from a file and adding it to @bibentry
sub read_bib_entry
  {
    my ($fh) = @_;
    my (%be);			# the bib entry we will create
    my ($wholeentry); # accumlates the whole bib entry
    my ($accum, $fdelim, $bdelim, $opendelimcnt) = ('','','',-1);
    local ($_);			# we'll store the current line here

    #accumulate the entry
    while (<$fh>) {
      next if (/^\s*$/);
      chomp;
      # Ignore comment lines
      next if (/^\s*\@Comment/i);
      # see if this is the beginning
      if (!$bdelim && /^\s*\@\w+\s*([\(\{])/) {
	  $fdelim = $1;
	  $bdelim = ')' if ($fdelim eq '(');
	  $bdelim = '}' if ($fdelim eq '{');
	  $opendelimcnt = 0;
	}
      if ($fdelim) {
	# only do this once we have found the start of the entry
	$accum .= $_;
	if ($conf{'remove_bib2html_fields'}) {
	  if (not /bib2html/) {
	    $wholeentry .= remove_particular_latex('btohremove', $_) . "\n";
	  }
	} else {
	  $wholeentry .= $_."\n";
	}
	while ($fdelim && /\Q$fdelim\E/g) { $opendelimcnt++; }
	while ($fdelim && /\Q$bdelim\E/g) { $opendelimcnt--; }
      }
      if ($bdelim && $opendelimcnt <= 0) {
	# we are at the end
	die "How is opendelimcnt < 0? $opendelimcnt" if ($opendelimcnt < 0);
	die "There's something on this line after this entry: '$_'" if (not /\Q$bdelim\E\s*,?\s*$/);
	last;
      }
    }

    # opendelimcnt starts out negative, so if we got nothing, it's still negative
    return 0 if ($opendelimcnt < 0);

    # now it's time to parse $accum;
    $_ = $accum;

    if (/\s*\@string\s*[\(\{]\s*([\w\-\+\:]+)\s*=\s*(.*?)\s*[\)\}]\s*,?\s*$/i) {
      # we've got a string
      $field = $1;
      $value = '';
      print "String '$field' found\n" if ($conf{'debug'});
      @substrs = split /\s*\#\s*/, $2;
      foreach $_ (@substrs) {
	if (/^\s*\{/) {
	  s/^\s*\{(.*)\}\s*$/$1/ || die "Malformatted braced string component '$_'";
	  $value .= $_;
	} elsif (/^\s*\"/) {
	  s/^\s*\"(.*)\"\s*$/$1/ || die "Malformatted quoted string component '$_'";
	  $value .= $_;
	} else {
	  # a bare entry
	  $_ = lc $_;
	  $value .= (exists $strings{$_}) ? $strings{$_} : $_;
	}
      }
      $strings{lc $field} = $value;
    } elsif (/^\s*\@([\w\-\+\:]+)\s*[\(\{]\s*([\w\-\+\:\.]+)\s*,\s*(.*)[\)\}]\s*$/) {
      $be{'TYPE'} = lc($1);
      $be{'KEY'} = $2;
      $_ = $3; # the interior of the string

      #now we have to get the field values
      pos() = 0; # reset the matching position
      for (;;) {
	# check for a bare entry
	if (/\G\s*([\w\-\.\:]+)\s*=\s*([^,\"\{\}\(\)\s]+)\s*,?/cg) {
	  $be{lc($1)} = (exists $strings{lc $2}) ? $strings{lc $2} : $2;
	  next
	}
	# check a quoted string
	if (/\G\s*([\w\-\.\:]+)\s*=\s*\"(.*?[^\\])\"\s*,?/cg) {
	  $be{lc($1)} = $2;
	  next
	}
	#now the tricky one, something enclosed in {}
	# we'll keep matching minimal amounts and storing the result until we are balanced
	if (/\G\s*([\w\-\.\:]+)\s*=\s*\{/cg) {
	  $field = $1;
	  $accum = '{'; # the initial {
	  for (;;) {
	    die "Unbalanced {} in '$_'" if (not /\G([^\}]*\})/cg);
	    $accum .= $1;
	    last if (is_brace_balanced($accum));
	  }
	  /\G\s*,?\s*/cg; # skip the comma if it is there
	  $accum =~ s/^\s*\{//;
	  $accum =~ s/\}\s*$//;
	  $be{lc($field)} = $accum;
	  next
	}
	# I should really need this line, but somehow the regex doesn't seem to 
        # match if \G is after the end of the string
	last if (pos() == length($_));
	last if (/\G\s*$/cg);
	warn "WARNING: I couldn't understand this entry:\n".
	  (exists $be{'KEY'} ? "Key = $be{'KEY'}\n" : '') .
	    "remain (".(pos())."): '".(substr $_,pos())."'\nwholeentry: '$_'";
	return -1;
      }

      $be{'BIBTEX'} = $wholeentry;
      $be{'ALTKEYS'} = [];
      push @bibentry, \%be;

    } else {
      warn "WARNING: I do not understand this entry: $_";
      return -1;
    }

    return 1;
  }

## BiBTeX has some predefined strings
sub add_default_strings
  {
    # this is a list of journals which are often predefined
    $strings{'acmcs'} = 'ACM Computing Surveys';
    $strings{'acta'} = 'Acta Informatica';
    $strings{'cacm'} = 'Communications of the ACM';
    $strings{'ibmjrd'} = 'IBM Journal of Research and Development';
    $strings{'ibmsj'} = 'IBM Systems Journal';
    $strings{'ieeese'} = 'IEEE Transactions on Software Engineering';
    $strings{'ieeetc'} = 'IEEE Transactions on Computers';
    $strings{'ieeetcad'} = 'IEEE Transactions on Computer-Aided Design of Integrated Circuits';
    $strings{'ipl'} = 'Information Processing Letters';
    $strings{'jacm'} = 'Journal of the ACM';
    $strings{'jcss'} = 'Journal of Computer and System Sciences';
    $strings{'scp'} = 'Science of Computer Programming';
    $strings{'sicomp'} = 'SIAM Journal on Computing';
    $strings{'tocs'} = 'ACM Transactions on Computer Systems';
    $strings{'tods'} = 'ACM Transactions on Database Systems';
    $strings{'tog'} = 'ACM Transactions on Graphics';
    $strings{'toms'} = 'ACM Transactions on Mathematical Software';
    $strings{'toois'} = 'ACM Transactions on Office Information Systems';
    $strings{'toplas'} = 'ACM Transactions on Programming Languages and Systems';
    $strings{'tcs'} = 'Theoretical Computer Science';
    # now the months of the year.
    $strings{'jan'} = 'January';
    $strings{'feb'} = 'February';
    $strings{'mar'} = 'March';
    $strings{'apr'} = 'April';
    $strings{'may'} = 'May';
    $strings{'jun'} = 'June';
    $strings{'jul'} = 'July';
    $strings{'aug'} = 'August';
    $strings{'sep'} = 'September';
    $strings{'oct'} = 'October';
    $strings{'nov'} = 'November';
    $strings{'dec'} = 'December';
  }

##############
## Debugging functions

sub print_strings
  {
    print "Printing all strings: \n";
    foreach $str (keys %strings) {
      print '@string('.$str.' = '.$strings{$str}."\n";
    }
  }

##############
## Error checking

## Each argument shoudl be a bibentry ref.
## Does some error checking on each
## Not intended to cover everything, just some common errors
sub error_check_bib_entries
  {
    my ($beref);
    foreach $beref (@_)
      {
	if (exists($beref->{'year'}))
	  {
	    (($beref->{'year'}) =~ /^\d+$/) 
	      || warn ("Entry '" . ($beref->{'KEY'}) . "' has a malformed year field '" . ($beref->{'year'}) . "'");
	  }
      SWITCH: for ($beref->{"TYPE"}) {
	  /inproceedings/ && do {
	    (exists($beref->{'booktitle'}))
	      || warn ("Entry '" . ($beref->{'KEY'}) . "' is lacking the booktitle field");
	  };
	}
	if (!exists($beref->{'author'}) && !exists($beref->{'editor'}))
	  {
	    warn ("Entry '" . ($beref->{'KEY'}) . "' has no author or editor field, I'm probably going to fail");
	  }
      }
  }

## this goes through bibentries and looks for duplicate keys, generating a warning for
## each one
## args: list of bibentry refs, no return
sub check_for_duplicate_keys
  {
    my ($beref, %keys);
    foreach $beref (@_) {
      if (exists($keys{$beref->{'KEY'}})) {
	warn "Key '" . $beref->{'KEY'} . "' appears multiple times";
      }
      $keys{$beref->{'KEY'}} = $beref;
      # temp debug code
      #print ("ALT: ".(join ' ', @{$beref->{'ALTKEYS'}})."\n") if (@{$beref->{'ALTKEYS'}} > 0);
    }
  }

## this goes through a list bibentries and ensures that every entry has an author in
## $confmultline{'catlist_authors'}
## Generates a warning if not
## args: list of bibentries, no return
sub check_for_valid_authors
  {
    print "Checking for valid authors, list is: " . (join ' ', @{$confmultline{'catlist_authors'}} ) . "\n" if ($conf{'debug'});
    return if (@{$confmultline{'catlist_authors'}} == 0);
    my ($beref, @names);
    foreach $beref (@_) {
      @names = get_allowed_author_names($beref);
      print "Entry '" . $beref->{'KEY'} . "' has allowed authors: " . (join ' ', @names) . "\n" if ($conf{'debug'});
      if (@names == 0) {
	warn "Entry with key '" . $beref->{'KEY'} . "' has no authors in the allowed list";
      }
    }
  }

##############
## Duplication and Merging Functions

## Tries to remove duplicate entries by merging their information
## args: ref to array to process, no return
sub duplicate_reduce
  {
    my ($aberef) = @_;
    my ($cnt) = (0);
    print "Merging duplicates..." unless ($conf{'quiet'});
    for ($idx1=0; $idx1<@$aberef; $idx1++) {
      for ($idx2=$idx1+1; $idx2<@$aberef; $idx2++) {
	next if (not are_bibentries_duplicates($aberef->[$idx1], $aberef->[$idx2]));
	print "Found duplicate: " . $aberef->[$idx1]->{'KEY'} . " " . $aberef->[$idx2]->{'KEY'} . "\n" if ($conf{'debug'});
	$aberef->[$idx1] = merge_entries($aberef->[$idx1], $aberef->[$idx2]);
	splice(@$aberef, $idx2, 1);
	$idx2--; # since $idx2 got removed and $idx will be ++ above, we decrement here
	$cnt++;
      }
    }
    print " $cnt duplicates removed\n" unless ($conf{'quiet'});
  }

## Merges two bib entries
## Takes two bibentry refs. Modifies one of them (you don't know which)
## and returns the modified one (which is a merge of the two)
sub merge_entries
  {
    my ($beref1, $beref2) = @_;
    my ($tmp, $key);
    # First, let's make $beref1 the entry with the most fields
    # Conflicts will get resolved in favor of that entry
    if ((keys %$beref2) > (keys %$beref1))
      {
	$tmp = $beref1;
	$beref1 = $beref2;
	$beref2 = $tmp;
      }
    #Now any field in $beref2 that does not exist in $beref1 will be copied there
    foreach $key (keys %$beref2) {
      next if (exists($beref1->{$key}));
      $beref1->{$key} = $beref2->{$key};
    }
    push @{$beref1->{'ALTKEYS'}}, ($beref2->{'KEY'}, @{$beref2->{'ALTKEYS'}});
    return $beref1;
  }

## Tries to decide if two bibentries describe the same paper
## Args: Two bibentry refs
## Return: bool (whether they are the same)
sub are_bibentries_duplicates
  {
    my ($beref1, $beref2) = @_;
    return 0 if ($beref1->{'TYPE'} ne $beref2->{'TYPE'});
    warn "Bibentry with key '" . ($beref1->{'KEY'}) . "' has no title" if (not exists ($beref1->{'title'}));
    warn "Bibentry with key '" . ($beref2->{'KEY'}) . "' has no title" if (not exists ($beref2->{'title'}));
    return 0 if (canonicalize_title($beref1->{'title'}) ne canonicalize_title($beref2->{'title'}));
    if ((exists ($beref1->{'year'}) && not exists ($beref2->{'year'})) ||
	(not exists ($beref1->{'year'}) && exists ($beref2->{'year'})))
      {
	warn "are_bibentries_duplicates: Entries with keys '" . $beref1->{'KEY'} 
	  . "' and '" . $beref2->{'KEY'} . "': one has year, the other doesn't";
	return 0;
      }
    # we now that they either both have a year field, or they both don't
    # if no year field, then since the title is the same, we'll assume it's the same
    # entry
    return 1 if (not exists ($beref1->{'year'}));
    return 1 if ($beref1->{'year'} == $beref2->{'year'});
    return 0;
  }

## Takes a string (which is the title of a paper and tries to
## make a canonical form of it for comparison
sub canonicalize_title
  {
    local ($_);
    $_ = $_[0];
    s/://g;
    s/;//g;
    s/{//g;
    s/}//g;
    s/-//g;
    s/\.//g;
    #It's important that space reduction goes at the end because previous removals
    # can join space
    s/\s+/ /g;
    s/^\s+//g;
    s/\s+$//g;
    $_ = lc $_;
  }

##############
## Removing entries specifically flagged as to be ignored

## Takes a list of bibentry refs and returns a list 
## Removes an entry which have a true value as the field bib2html_ignore
## Thank you to Peter Stone 1/24/04
sub remove_ignored_entries
  {
    my ($beref, @output);
    foreach $beref (@_) {
      if (exists $beref->{"bib2html_ignore"} &&
	  $beref->{"bib2html_ignore"}) {
        print "Removing an entry flagged as to be ignored '$beref->{'KEY'}'\n" if ($conf{'debug'});
      } else {
	push @output, $beref;
      }
    }
    return @output;
}

##############
## Helper formatting functions

## an auxiliary formatting function for handling urls
## args: string
## return: string
sub format_url
  {
    my ($str) = @_;
    $str =~ s/~/\\char\"7E/g;
    #let's figure out if this is an email addr
    if ( ($str =~ /\@/)) {
      $str =~ s/href\s*=\s*\"/href=\"mailto:/g;
    }
    return $str;
  }

## performs some formatting from basic tex stuff
## args: a string to format
## return: formatted string
sub htmlfm_from_tex
  {
    my ($str) = @_;

    if (not defined($str))
      {
	die "In htmlfm_from_tex, why is str undefined";
      }

    $str = remove_particular_latex('btohremove', $str);

    # The auxiliary format sub takes a ~ and turns it into \char"7E (which is a special
    # latex code for ~
    # After the regular ~ replacement has happended, we'll replace \char"7E with ~
    $str = replace_particular_latex('url', '<a href="#1">#1</a>', $str, \&format_url);

    # apply various text formatting macros
    $str = replace_particular_latex('emph', '<i>#1</i>', $str);
    $str = replace_particular_latex('textit', '<i>#1</i>', $str);
    $str = replace_particular_latex('textbf', '<b>#1</b>', $str);
    $str = replace_particular_latex('textsc', '<span style="font-variant: small-caps;">#1</span>', $str);

    # apply the {\it }, {\em } and {\bf }formatting styles
    $str =~ s/\{\s*\\it\s*([^\{\}]*)\}/<i>$1<\/i>/g;
    $str =~ s/\{\s*\\em\s*([^\{\}]*)\}/<i>$1<\/i>/g;
    $str =~ s/\{\s*\\bf\s*([^\{\}]*)\}/<b>$1<\/b>/g;

    # remove extra braces
    while ($str =~ s/\{(.*?)\}/$1/g) {}

    # convert spaces
    $str =~ s/~/&nbsp;/g;
    $str =~ s/\\ / /g;

    # now replace \char"7E with ~ (should only be used in urls
    $str =~ s/\\char\"7E\s*/~/g;

    # underscores, etc.
    $str =~ s/^/ /;
    $str =~ s/\\_/_/g;
    $str =~ s/\\\-//g;
    $str =~ s/\\\,//g;
    $str =~ s+\\\/++g;
    $str =~ s/\\\&/&amp;/g;
	
    # replace \par with <br /> (TeX for new paragraphs in abstracts -- oliver)
    $str =~ s/\\par/<br>/g;

    # %
    $str =~ s/\\\%/\%/g;

	# #
	$str =~ s/\\#/#/g;

	# &
	$str =~ s/\\&/&amp;/g;

	# ``
	$str =~ s/\`\`/&#147;/g;

	# ''
	$str =~ s/\'\'/&#148;/g;

    ## latin-1 entitities
    $str =~ s/\\\`a/&agrave;/g;
    $str =~ s/\\\'a/&aacute;/g;
    $str =~ s/\\\^a/&acirc;/g;
    $str =~ s/\\\~a/&atilde;/g;
    $str =~ s/\\\"a/&auml;/g;
    $str =~ s/\\aa/&aring;/g;
    $str =~ s/\\ae/&aelig;/g;

    $str =~ s/\\c c/&ccedil;/g;

    $str =~ s/\\\`e/&egrave;/g;
    $str =~ s/\\\'e/&eacute;/g;
    $str =~ s/\\\^e/&ecirc;/g;
    $str =~ s/\\\"e/&euml;/g;

    $str =~ s/\\\`\\i/&igrave;/g;
    $str =~ s/\\\'\\i/&iacute;/g;
    $str =~ s/\\\^\\i/&icirc;/g;
    $str =~ s/\\\"\\i/&iuml;/g;

    $str =~ s/\\\~n/&ntilde;/g;

    $str =~ s/\\\`o/&ograve;/g;
    $str =~ s/\\\'o/&oacute;/g;
    $str =~ s/\\\^o/&ocirc;/g;
    $str =~ s/\\\~o/&otilde;/g;
    $str =~ s/\\\"o/&ouml;/g;
	$str =~ s/\\o/&oslash;/g;

    $str =~ s/\\\`u/&ugrave;/g;
    $str =~ s/\\\'u/&uacute;/g;
    $str =~ s/\\\^u/&ucirc;/g;
    $str =~ s/\\\~u/&utilde;/g;
    $str =~ s/\\\"u/&uuml;/g;

    $str =~ s/\\ss/&szlig;/g;

    $str =~ s/\\\`A/&Agrave;/g;
    $str =~ s/\\\'A/&Aacute;/g;
    $str =~ s/\\\^A/&Acirc;/g;
    $str =~ s/\\\~A/&Atilde;/g;
    $str =~ s/\\\"A/&Auml;/g;
    $str =~ s/\\AA/&Aring;/g;
    $str =~ s/\\AE/&AElig;/g;

    $str =~ s/\\\c C/&Ccedil;/g;

    $str =~ s/\\\`E/&Egrave;/g;
    $str =~ s/\\\'E/&Eacute;/g;
    $str =~ s/\\\^E/&Ecirc;/g;
    $str =~ s/\\\"E/&Euml;/g;

    $str =~ s/\\\`\\I/&Igrave;/g;
    $str =~ s/\\\'\\I/&Iacute;/g;
    $str =~ s/\\\^\\I/&Icirc;/g;
    $str =~ s/\\\"\\I/&Iuml;/g;


    $str =~ s/\\l/\&#322;/g;

    $str =~ s/\\\~N/&Ntilde;/g;

    $str =~ s/\\\`O/&Ograve;/g;
    $str =~ s/\\\'O/&Oacute;/g;
    $str =~ s/\\\^O/&Ocirc;/g;
    $str =~ s/\\\~O/&Otilde;/g;
    $str =~ s/\\\"O/&Ouml;/g;

    $str =~ s/\\\`U/&Ugrave;/g;
    $str =~ s/\\\'U/&Uacute;/g;
    $str =~ s/\\\^U/&Ucirc;/g;
    $str =~ s/\\\~U/&Utilde;/g;
    $str =~ s/\\\"U/&Uuml;/g;
    return $str;
  }

## these are some simple formatting routines
## all take a string and return a string
## they do very little html stuff, mostly handling case formatting and commas and such

## This one is a little different because it looks up the name in the author urls and handles that
sub htmlfm_indiv_author
  {
    my ($name) = @_;
    my $idxname = get_name_form_from_list($name, [keys %author_urls]);

    if ( my ($last_name,$first_name) = $name =~ m/(.*),\s+(.*)/ ) {
      $name = "$first_name $last_name";
    }
    return htmlfm_from_tex($name) if (not defined($idxname));
    my $url = $author_urls{$idxname};
    print "htmlfm_indiv_author: '$name' has idx name " . (defined($idxname) ? $idxname : "UNDEF") . "; URL of $url\n" if ($conf{'debug'});
    return "<a href=\"$url\">".htmlfm_from_tex($name)."</a>";
  }

sub htmlfm_author
  {
    my (@list) = split /\s+and\s+/, $_[0];
    my ($tmp);
    return htmlfm_indiv_author($list[0]) if (@list == 1);
    return (htmlfm_indiv_author($list[0]).' and '.htmlfm_indiv_author($list[1])) if (@list == 2);
    # we have at least 3 elements
    $tmp = htmlfm_indiv_author($list[$#list-1]).', and '.htmlfm_indiv_author($list[$#list]);
    $#list -= 2; # cut off 2 elements
    return join (', ', ( (map { htmlfm_indiv_author($_) } @list), $tmp) );
  }

sub htmlfm_title
  {
    my $str = '';
    $str .= "<$conf{'title_html_tag'}>" if ($conf{'title_html_tag'});
    $str .= htmlfm_from_tex($_[0]);
    $str .= "</$conf{'title_html_tag'}>" if ($conf{'title_html_tag'});
    return $str;
  }

sub htmlfm_volnumpgs
  {
    my ($v, $n, $p) = @_;
    my ($ret);
    return '' if (!defined($v) && !defined($n) && !defined($p));
    $ret = '';
    if (defined($v))
      {
	$ret .= htmlfm_from_tex($v);
	$ret .= '('.$n.')' if (defined($n));
	$ret .= ':' if (defined($p));
      }
    else
      {
	$ret .= 'pp. ';
      }
    $ret .= htmlfm_pages($p) if (defined($p));
    $ret .= ', ';
  }

sub htmlfm_pages
  {
    my ($pp) = @_;
    $pp =~ s/-+/&ndash;/;
    return $pp;
  }

sub htmlfm_author_count
   {
     my (@list) = split /\s+and\s+/, $_[0];
     return scalar @list;
   }

## Prints a no-frills version of the bib entry. This does the work of differentiation based
## on type of entry.
#args: reference to bib entry hash
# return string with an html formatted entry
sub htmlfm_entry_basic
  {
    my ($beref) = @_;
    my ($ret);
  SWITCH: for ($beref->{"TYPE"}) {
      /article/ && do {
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	$ret .= '<i>'.(htmlfm_from_tex($beref->{'journal'})).'</i>, ';
	$ret .= htmlfm_volnumpgs($beref->{'volume'}, $beref->{'number'}, $beref->{'pages'});
	$ret .= htmlfm_from_tex($beref->{'publisher'}).', ' if (exists $beref->{'publisher'});
	$ret .= htmlfm_from_tex($beref->{'address'}).', ' if (exists $beref->{'address'});
	$ret .= $beref->{'month'}.' ' if (exists $beref->{'month'});
	$ret .= $beref->{'year'};
	$ret .= '.';
	last
      };
      /book/ && do {
	if (exists $beref->{"author"}) {
	  $ret = htmlfm_author($beref->{"author"}).'. ';
	} else {
	  $ret = htmlfm_author($beref->{"editor"}).', editors. ';
	}
	$ret .= '<i>'.htmlfm_title($beref->{"title"}).'</i>, ';
	$ret .= 'pp. '.(htmlfm_pages($beref->{'pages'})). ', ' if (exists $beref->{'pages'});
	if (exists $beref->{'volume'}) {
	  $ret .= htmlfm_from_tex($beref->{'series'}).' ' if (exists $beref->{'series'});
	  $ret .= htmlfm_from_tex($beref->{'volume'}).', ';
	} else {
	  $ret .= htmlfm_from_tex($beref->{'series'}).', ' if (exists $beref->{'series'});
	}
	$ret .= htmlfm_from_tex($beref->{'publisher'}).', ' if (exists $beref->{'publisher'});
	$ret .= $beref->{'address'}.', ' if (exists $beref->{'address'});
	$ret .= $beref->{'month'}.' ' if (exists $beref->{'month'});
	$ret .= $beref->{'year'};
	$ret .= '.';
	last
      };
      /booklet/ && do { die "Unimplemented type for print '".($beref->{"TYPE"})."'"; last };
      /inbook/ && do { die "Unimplemented type for print '".($beref->{"TYPE"})."'"; last };
      /incollection/ && do {
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	$ret .= 'In ';
	if (exists ($beref->{'editor'})) {
	  $ret .= htmlfm_author($beref->{'editor'}).', editor';
	  $ret .= 's' if (htmlfm_author_count($beref->{'editor'})>1);
	  $ret .= ', ' ;
	}
	$ret .= '<i>'.(htmlfm_from_tex($beref->{'booktitle'})).'</i>, ';
	$ret .= "number ".$beref->{'number'}.' in ' if (exists $beref->{'number'});
	$ret .= htmlfm_from_tex($beref->{'series'}).', ' if (exists $beref->{'series'});
	$ret .= 'pp. '.(htmlfm_pages($beref->{'pages'})). ', ' if (exists $beref->{'pages'});
	$ret .= htmlfm_from_tex($beref->{'publisher'}).', ' if (exists $beref->{'publisher'});
	$ret .= htmlfm_from_tex($beref->{'address'}).', ' if (exists $beref->{'address'});
	$ret .= $beref->{'month'}.' ' if (exists $beref->{'month'});
	$ret .= $beref->{'year'};
	$ret .= '.';
	$ret .= ' '.$beref->{'edition'}.' edition.' if (exists $beref->{'edition'});
	last
      };
      /inproceedings/ && do { 
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	$ret .= 'In <i>'.(htmlfm_from_tex($beref->{'booktitle'})).'</i>, ';
	$ret .= 'pp. '.(htmlfm_pages($beref->{'pages'})). ', ' if (exists $beref->{'pages'});
	# Print volume information for articles in proceedings (oliver)
	if (exists $beref->{'volume'}) {
	  $ret .= htmlfm_from_tex($beref->{'series'}).' ' if (exists $beref->{'series'});
	  $ret .= htmlfm_from_tex($beref->{'volume'}).', ';
	} else {
	  $ret .= htmlfm_from_tex($beref->{'series'}).', ' if (exists $beref->{'series'});
	}
	$ret .= htmlfm_from_tex($beref->{'publisher'}).', ' if (exists $beref->{'publisher'});
	$ret .= htmlfm_from_tex($beref->{'address'}).', ' if (exists $beref->{'address'});
	$ret .= $beref->{'month'}.' ' if (exists $beref->{'month'});
	$ret .= $beref->{'year'};
	$ret .= '.';
	last
      };
      /manual/ && do { 
	if (exists $beref->{"author"}) {
	  $ret = htmlfm_author($beref->{"author"}).'. ';
	} else {
	  $ret = htmlfm_author($beref->{"editor"}).', editors. ';
	}
	$ret .= '<i>'.htmlfm_title($beref->{"title"}).'</i>, ';
	$ret .= $beref->{'series'}.', ' if (exists $beref->{'series'});
	$ret .= 'pp. '.(htmlfm_pages($beref->{'pages'})). ', ' if (exists $beref->{'pages'});
	$ret .= htmlfm_from_tex($beref->{'publisher'}).', ' if (exists $beref->{'publisher'});
	$ret .= htmlfm_from_tex($beref->{'address'}).', ' if (exists $beref->{'address'});
	$ret .= $beref->{'month'}.' ' if (exists $beref->{'month'});
	$ret .= $beref->{'year'};
	$ret .= '.';
	last
      };
      /mastersthesis/ && do {
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	$ret .= "Master's Thesis, ".htmlfm_from_tex($beref->{'school'});
	$ret .= ', '.htmlfm_from_tex($beref->{'address'}) if (exists $beref->{'address'});
	$ret .= ','.$beref->{'year'};
	$ret .= '.';
	last
      };
      /misc/ && do {
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	$ret .= '<i>'.(htmlfm_from_tex($beref->{'howpublished'})).'</i>, '
	  if (exists $beref->{'howpublished'});
	$ret .= $beref->{'month'}.' ' if (exists $beref->{'month'});
	$ret .= $beref->{'year'};
	$ret .= '.';
	last
      };
      /phdthesis/ && do {
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	$ret .= "Ph.D. Thesis, ".htmlfm_from_tex($beref->{'school'});
	$ret .= ', '.htmlfm_from_tex($beref->{'address'}) if (exists $beref->{'address'});
	$ret .= ', '.$beref->{'year'};
	$ret .= '.';
	last
      };
      /preamble/ && do { die "Unimplemented type for print '".($beref->{"TYPE"})."'"; last };
      /proceedings/ && do { die "Unimplemented type for print '".($beref->{"TYPE"})."'"; last };
      /string/ && do { die "Unimplemented type for print '".($beref->{"TYPE"})."'"; last };
      /techreport/ && do {
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	if (exists $beref->{'type'}) {	  
	  $ret .= htmlfm_from_tex($beref->{"type"});
	} else {
	  $ret .= 'Technical Report';
	}
	$ret .= ' '.($beref->{'number'}).', ' if (exists $beref->{'number'});
	$ret .= htmlfm_from_tex($beref->{'institution'}).', ';
	$ret .= $beref->{'year'};
	$ret .= '.';
	last
      };
      /unpublished/ && do { 
	$ret = htmlfm_author($beref->{"author"}).'. ';
	$ret .= htmlfm_title($beref->{"title"}).'. ';
	$ret .= '<i>Unpublished</i> ';
	$ret .= $beref->{'year'};
	$ret .= '.';
	last
      };
    }
    #stuff common to all
    $ret .= ' '.htmlfm_from_tex($beref->{'note'}) if (exists $beref->{'note'});
    $ret .= '<br /> '.htmlfm_from_tex($beref->{$conf{'bibfield_wwwnote'}}) if (exists $beref->{$conf{'bibfield_wwwnote'}});

    return $ret;
  }

## returns the directory (relative to the output dir) where the file resides, undef if it does not exist
## check all directory in $confmultline{'paperfiledirlist'}
# args: filename
sub get_paper_local_location
  {
    my ($fn) = @_;
    my ($dir, $fulldir);
    foreach $dir (@{$confmultline{'paperfiledirlist'}}) {
      $fulldir = resolve_path($conf{'outputdir'}, $dir);
      return $dir if (-e "$fulldir/$fn");
    }
    return undef;
  }

## Gets the path to the paper, undef if none can be found
## check all directories in $confmultline{'paperfiledirlist'}
## and all possible key values, stopping at the first one found
## args: bib entry ref, file extension
sub get_paper_file_path
  {
    my ($beref, $fe) = @_;
    my ($dir, $fulldir, $key, $fs, $fn, $fl, $path, $ext, @args);
    foreach $key ($beref->{'KEY'}, @{$beref->{'ALTKEYS'}}) {
      $fs = get_file_name_from_key($key);
      foreach $dir (@{$confmultline{'paperfiledirlist'}}) {
	$fulldir = resolve_path($conf{'outputdir'}, $dir);
	return "$dir/$fs.$fe" if (-e "$fulldir/$fs.$fe");
      }
    }
	# BibDesk support
	if (exists $beref->{'local-url'}) {
		$fl = $beref->{'local-url'};
		$fl =~ s/file:\/\/localhost//;
		$fl =~ s/%20/ /g;
		($fn, $path, $ext) = fileparse($fl, $fe);
		if ($ext eq $fe) {
			$fs = get_file_name_from_key($beref->{'KEY'});
			$dir = $confmultline{'paperfiledirlist'}[0];
			$fulldir = resolve_path($conf{'outputdir'}, $dir);
			return "$dir/$fs.pdf" if (-e "$fulldir/$fs.$fe");
			@args = ( "ln", "-s", "$fl", "$fulldir/$fs.$fe" );
			system(@args);
			return "$dir/$fs.pdf";
		}
	}
		
    return undef;
  }

## returns the url to download this paper, extracted from the bib fields, undef if no field
## args: file extension in which we are interested
sub get_paper_url
  {
    my ($beref,$fe) = @_;
    my ($field);
    $fe =~ s/\.//g;
    $field = $conf{"bibfield_dl_$fe"};
    return $beref->{$field} if (exists $beref->{$field});
    return 'http://dx.doi.org/'.$beref->{'doi'} if (exists $beref->{'doi'});
    return undef;
  }

## extract a base file name for a detail page from a bibentry
## args: beref
sub get_detail_file_name
  {
    my ($beref) = @_;
    return "b2hd-" . get_file_name($beref);
  }

## extract a file name for a bibtex page from a bibentry
## args: beref
sub get_bibtex_file_name
  {
    my ($beref) = @_;
    return get_file_name($beref) . '.bib';
  }

## extract a base file name from a bibentry, based on the key
## args: beref
sub get_file_name
  {
    my ($beref) = @_;
    return get_file_name_from_key($beref->{'KEY'});
  }

## extract a base file name from a key value
## args: string which is a bibtex key
## returns base file name
sub get_file_name_from_key
  {
    my ($fn) = @_;
    $fn =~ s/\://g;
    $fn =~ s/\+//g;
    return $fn;
  }
## Creates a file for each class
## Outputs the original bibentries (separated by a single blank line
## args: output directory, reference to a hash where keys are class and
##       values are refs to a list of ref to bibentries
## return: none
sub create_files_from_class
  {
    my ($outputdir, $classhashref) = @_;
    my ($fn, $class, $beref);
    foreach $class (keys %$classhashref) {
      $fn = "$outputdir/$class.bib";
      $fn = normalize_file_name($fn);
      open (OUTFH, ">$fn") || die "Could not open class file '$fn': $!";
      print OUTFH <<EOH;
This file was generated by bib2html version $version (date $version_date)
The function create_files_from_class did the magic.
The class name is: $class

EOH
      foreach $beref (@{$classhashref->{$class}}) {
	print OUTFH $beref->{'BIBTEX'};
	print OUTFH "\n";
      }
      close (OUTFH);
    }
  }
##############
## XML Output functions

## Provides needed XML quoting on values
## First arg is a string, returns the armored string
sub xml_armor
  {
    my ($val) = @_;
    return undef if (not defined($val));
    $val =~ s/&/&amp;/g;
    $val =~ s/</&lt;/g;
    $val =~ s/>/&gt;/g;
    $val =~ s/\'/&apos;/g;
    $val =~ s/\"/&quot;/g;
    return $val;
  }

## Formats a class name for inclusion in the output file
## args: string
## output string ready to be included in the XML output
sub xmlfm_class_name
  {
    return xml_armor(htmlfm_from_tex(ucfirst($_[0])));
  }

## Formats a class name for inclusion in the output file where the class name is an author
## Most appropriate for author names
## args: string
## output string ready to be included in the XML output
sub xmlfm_author_class_name
  {
    my ($str) = @_;
    # remove extra spaces
    $str =~ s/\s+/ /g;
    $str =~ s/^\s+/ /g;
    $str =~ s/\s+$/ /g;
    # This applies the formatting of upper case first letter only
    # We actually want to take whatever formatting is supplied
    #$str = join ' ', (map { ucfirst($_) } (split /\s+/, $str));
    # old thing, only got initials
    #$str =~ s/\s[a-z]\./uc(\1)/g;
    return xml_armor(htmlfm_from_tex($str));
  }

## No args, returns the standard header informaiton for an xml doc
sub get_xml_header
  {
    my ($output) = '';
    $output .= '<?xml version="1.0" encoding="ISO-8859-1"?>'."\n\n";
    $output .= '<?xml-stylesheet type="text/xsl" href="' .
      ($conf{'output_xsl_dir'} . '/' . $conf{'xsl_fn'}) . '"?>' . "\n\n";
    return $output;
  }

## No args, returns the standard attributes to be put onto the root element
sub get_xml_root_elem_attr
  {
    my ($output) = '';
    $output .= 'xmlns:b2h="http://www.cs.cmu.edu/~pfr/misc_software/index.html#bib2html"'."\n";
    $output .= 'xmlns="http://www.cs.cmu.edu/~pfr/misc_software/index.html#bib2html"'."\n";
    $output .= 'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'."\n";
    $output .= 'xsi:schemaLocation="http://www.cs.cmu.edu/~pfr/misc_software/index.html#bib2html ' .
                $scriptdir . '/bib2html.xsd"'."\n";
    return $output;
  }

## No args, and returns a string that is the current date and time formatted in an XML datetime
sub get_xml_curr_datetime
  {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
    return ((1900+$year).'-'.(sprintf("%02d",$mon+1)).'-'.(sprintf("%02d",$mday)).
            'T'.(sprintf("%02d", $hour)).':'.(sprintf("%02d", $min)).':'.(sprintf("%02d", $sec)));
    # I use to put the time zone here, but many people don't have the Time::Zone package, so I'll
    # remove the dependence
    #my ($offset) = tz_local_offset();
    # sprintf("%+03d:%02d",$offset/60/60,abs($offset) % (60*60)));
}

## No args, and returns a string that is a generation_info xml element
sub get_xml_generation_info
  {
    my ($out) = ('');
    $out .= "<generation_info>\n";
    $out .= "<program>$programname</program>\n";
    $out .= "<program_url>$programurl</program_url>\n";
    $out .= "<author>$author</author>\n";
    $out .= "<author_url>$authorurl</author_url>\n";
    $out .= "<datetime>" . (&get_xml_curr_datetime) . "</datetime>\n";
    $out .= "</generation_info>\n";
    return $out;
  }

## No args, uses @main_pages to generate the main_index_links xml element
sub get_xml_main_index_links
  {
    my ($output) = '';
    $output .= "<main_index_links>\n";
    foreach $page_entry_ref (@main_pages) {
      $output .= "<index_link>\n";
      $output .= "<name>" . ($page_entry_ref->[2]) . "</name>\n";
      $output .= "<url>" . (get_final_file($page_entry_ref->[1])) . "</url>\n";
      $output .= "</index_link>\n";
    }
    $output .= "</main_index_links>\n";
    return $output;
  }

## takes a bibentry ref, file extension, and file_format and returns a dowonload_entry xml element
sub get_xml_download_entry
  {
    my ($beref, $fe, $format) = @_;
    my ($path) = get_paper_file_path($beref, $fe);
    my ($url) = xml_armor(get_paper_url($beref, $fe));
    my ($output) = '';
    $output .= "<download_entry>\n";
    $output .= " <file_format>$format</file_format>\n";
    if (defined($path)) {
      $output .= " <url>$path</url>\n";
      $output .= " <size> " . (get_file_size(resolve_path($conf{'outputdir'},"$path"))) . " </size>\n";
      $output .= " <exists>1</exists>\n";
    } elsif (defined($url)) {
      $output .= " <url>$url</url>\n";
      $output .= " <exists>1</exists>\n";
    } else {
      $output .= " <exists>0</exists>\n";
    }
    $output .= "</download_entry>\n";
  }

## Takes a bibentry ref and returns a download_links xml element for it
sub get_xml_download_links
  {
    my ($beref) = @_;
    my ($output);
    $output = '';
    $output .= "<download_links>\n";
    foreach $format (@file_formats) {
      $output .= get_xml_download_entry($beref, $format, $format);
    }
    # if we didn't find any entry, check the 'url' entry and
    # assume it points to a web page. (oliver)
    if ($output !~ m/exists>1</) {
      $output .= get_xml_download_entry($beref, 'url', 'html');
    }
    $output .= "</download_links>\n";
    return $output;
  }

## the first arg is a boolean saying whether to include the abstract and bibtex fields
## second in a bib entry ref
## The return is a reference to an array of strings, each bib entry ref formatted
sub get_xml_paper_info
  {
    my ($long, $beref) = @_;
    my ($ouput);
    $output = '';
    $output .= "<paper_info>\n";
	# each paper should have authors or editors, add this data in an extra tag (oliver)
    if (exists $beref->{"author"}) {
      $output .= "<author>".xml_armor(htmlfm_author($beref->{"author"})).". </author>\n";
    } else {
      $output .= "<author>".xml_armor(htmlfm_author($beref->{"editor"})).", editors.</author>\n";
    }
    $output .= "<title>".xml_armor(htmlfm_title($beref->{'title'}))."</title>\n";
    # if the paper has a number, add it so we can format the number separately from the rest
    $output .= "<number>".($beref->{'number'})."</number>" if (exists $beref->{'number'});
    $output .= "<citation><![CDATA[".(htmlfm_entry_basic($beref))."]]></citation>\n";
    $output .= get_xml_download_links($beref);
    $output .= "<abstract><![CDATA[".(htmlfm_from_tex($beref->{$conf{'bibfield_abstract'}}))."]]></abstract>\n" if ($long && exists($beref->{$conf{'bibfield_abstract'}}));
    $output .= "<bibtex_entry><![CDATA[".($beref->{'BIBTEX'})."]]></bibtex_entry>\n" if ($long);
    if ($conf{'generate_detail_pages'}) {
      $output .= "<detail_url>".get_final_file(get_detail_file_name($beref))."</detail_url>";
    }
    if ($conf{'generate_bibtex_files'}) {
      $output .= "<bibtex_url>".get_bibtex_file_name($beref)."</bibtex_url>";
    }
    $output .= "<extra_info><![CDATA[".$beref->{$conf{'bibfield_extra_info'}}."]]></extra_info>\n" if (exists($beref->{$conf{'bibfield_extra_info'}}));
    $output .= "</paper_info>\n";
    return $output;
  }

## generates an xml detail file for the given bib entry
## args: a reference for a bib entry
sub generate_xml_detail_file
  {
    my ($beref) = @_;
    my ($fn);
    $fn = get_detail_file_name($beref);
    $fn = $conf{'outputdir'}."/$fn.xml";
    open (OUTFH, ">$fn") || die "Could not open detail file '$fn': $!";
    push @generated_xml_files, $fn;

    print OUTFH &get_xml_header;
    print OUTFH ("<paper_detail\n" . (&get_xml_root_elem_attr) . ">\n");
    print OUTFH &get_xml_main_index_links;
    print OUTFH get_xml_paper_info(1, $beref);
    print OUTFH &get_xml_generation_info;
    print OUTFH "</paper_detail>\n";

    close (OUTFH);
  }

## generates a classified list of papers file
## args: output fn, xml element name, title, reference to a hash where keys are class and
## values are refs to a list of ref to bibentries,
## then a ref to an array with the list of categories
## then a ref to a function which formats the class name
sub generate_xml_classified_file
  {
    my ($outfs, $elemname, $title, $classhashref, $allowedlistref, $fmtfuncref) = @_;
    my ($fulloutfn);

    $fulloutfn = $conf{'outputdir'}."/$outfs.xml";
    open (OUTFH, ">$fulloutfn") || die "Could not open classified out file '$fulloutfn': $!";
    push @generated_xml_files, $fulloutfn;

    print OUTFH &get_xml_header;
    print OUTFH ("<${elemname}\n" . (&get_xml_root_elem_attr) . ">\n");

    print OUTFH &get_xml_main_index_links;

    print OUTFH "<list_title>$title</list_title>\n";

    print OUTFH &get_xml_generation_info;

    print OUTFH "<list_group_papers>\n";

    foreach $class (@$allowedlistref, 'Unspecified') {
      next if (not exists $classhashref->{lc $class});
      print OUTFH "<group_papers>\n";
      print OUTFH "<group_title>".(&$fmtfuncref($class))."</group_title>\n";
      #print OUTFH "<group_title>$class</group_title>\n";
      foreach $beref (@{$classhashref->{lc $class}}) {
	# the 0 excludes the abstract and bibtex entry
	print OUTFH get_xml_paper_info(0, $beref);
      }
      print OUTFH "</group_papers>\n";
    }

    print OUTFH "</list_group_papers>\n";

    print OUTFH "</${elemname}>\n";

    close(OUTFH);
  }

## generates a sorted list of papers
## args: output fn, xml element name, a function reference, sorted list of references
## the function is called before outputting each entry. If the return is defined, then
##  a new group is started
## If the function returns undef before the first entry, then the group is assigned the name None
sub generate_xml_sorted_file
  {
    my ($outfs, $elemname, $title, $tfuncref, @belist) = @_;
    my ($fulloutfn, $tfuncout, $closer) = ('', 0, '');

    $fulloutfn = $conf{'outputdir'}."/$outfs.xml";
    open (OUTFH, ">$fulloutfn") || die "Could not open classified out file '$fulloutfn': $!";
    push @generated_xml_files, $fulloutfn;

    print OUTFH &get_xml_header;
    print OUTFH ("<${elemname}\n" . (&get_xml_root_elem_attr) . ">\n");

    print OUTFH &get_xml_main_index_links;

    print OUTFH "<list_title>$title</list_title>\n";

    print OUTFH &get_xml_generation_info;

    print OUTFH "<list_group_papers>\n";

    foreach $beref (@belist) {
      $tfuncout = &$tfuncref($beref);
      if ($closer eq '' && !defined($tfuncout)) {
	$tfuncout = "None";
      }
      if (defined $tfuncout) {
	print OUTFH "$closer\n";
	print OUTFH "<group_papers>\n";
	print OUTFH "<group_title>$tfuncout</group_title>\n";
	$closer = "</group_papers>"
      }
      print OUTFH get_xml_paper_info(0, $beref);
    }
    print OUTFH "$closer\n";

    print OUTFH "</list_group_papers>\n";

    print OUTFH "</${elemname}>\n";

    close(OUTFH);
  }

## generate a file for an index page
## args: out file stem
sub generate_xml_index_file
  {
    my ($outfs) = @_;
    my ($fulloutfn);
    local $_;
    $fulloutfn = $conf{'outputdir'}."/$outfs.xml";
    open (OUTFH, ">$fulloutfn") || die "Could not open index file '$fulloutfn': $!";
    push @generated_xml_files, $fulloutfn;

    print OUTFH &get_xml_header;
    print OUTFH ("<main_index_page\n" . (&get_xml_root_elem_attr) . ">\n");

    print OUTFH &get_xml_main_index_links;

    print OUTFH &get_xml_generation_info;

    print OUTFH "</main_index_page>\n";
    close(OUTFH);
  }

## generates a bibtex file for a beref
## args: ref to a bibentry
sub generate_bibtex_file
  {
    my ($beref) = @_;
    my $outfn = $conf{'outputdir'} . "/" . get_bibtex_file_name($beref);
    open (OUTFH, ">$outfn") || die "Could not open bibtex file '$outfn': $!";

    # leading comments
    print OUTFH <<EOH;
\@COMMENT This file was generated by $programname <$programurl> version $version
\@COMMENT written by $author <$authorurl>
EOH
    map { print OUTFH '@COMMENT ' . $_ . "\n" } @{$confmultline{'bibtex_file_comments'}};

    # Now the main part of the page
    print OUTFH $beref->{'BIBTEX'};

    close (OUTFH);
  }
##############
## Misc

# print list of bibentry refs to the given file handles
# args: a filehandle ref, list of bibentries
sub print_all
  {
    my ($fh, @be) = @_;
    foreach $beref (@be) {
      print $fh '@'.($beref->{"TYPE"}).'('.($beref->{"KEY"}).",\n";
      foreach $field (keys %{$beref}) {
	next if ($field eq "TYPE");
	next if ($field eq "KEY");
	next if ($field eq "ALTKEYS");
	next if ($field eq "BIBTEX");
	print $fh "$field = {".$beref->{$field}."},\n";
      }
      print $fh ")\n";
    }
  }

## returns the first of the arugment list
sub first_of
  {
    return $_[0];
  }

## returns the last of the arugment list
sub last_of
  {
    return $_[$#_];
  }

# Just calls ucfirst. I need this to pass a function reference into one of my functions
sub myucfirst
  {
    return ucfirst($_[0]);
  }

## returns whether the input string is an initial
## ex "P." -> true "Riley" -> false
sub isinitial
  {
    return $_[0] =~ /^\s*[A-Za-z]\.\s*$/;
  }

## returns the initial form of a name
## Patrick -> P.
## Safe to give it an initial
sub makeinitial
  {
    my ($name) = @_;
    $name =~ s/^\s*//;
    return (substr $name, 0, 1) . '.';
  }
## Returns the possible forms of an author name
## takes a single str that is an author name like "Patrick Riley", "P.~Riley", "P. F. Riley"
## return: list of name forms with the last being the most specific
sub get_name_forms_for
  {
    my ($name) = @_;
    my (@output, @nameparts);
    my ($numnames, $numinitials, $idx, $thiname, $nextprefix);

    # dirty hack: switch "Riley, Patrick F." back to "Patrick F. Riley"
    if ( my ($last_name,$first_name) = $name =~ m/(.*),\s+(.*)/ ) {
      $name = "$first_name $last_name";
    }

    @nameparts = split /\s+/, $name;
    # $numnames is how many names to include, $numinitials is how many initials there should be
    # (as opposed to full names)
    for ($numnames = 1; $numnames <= @nameparts; $numnames++)
      {
	for ($numinitials = $numnames - 1; $numinitials >= 0; $numinitials--)
	  {
	    $thisname = @nameparts[@nameparts - 1];
	    $nextprefix = ', ';
	    # -1 because we already have the last name there
	    for ($idx = 0; $idx < $numnames - 1; $idx++)
	      {
		$thisname .= $nextprefix . (($idx >= $numnames - $numinitials - 1) ? 
					    makeinitial($nameparts[$idx]) : 
					    $nameparts[$idx]);
		$nextprefix = ' ';
	      }
	    push @output, $thisname;
	  }
      }
    # SMURF: the same form could appear multiple times
    return @output;
  }

## Takes a name and a list reference of allowed names
## Returns the name form in the list ref that is a form of the given name
## or undef if none exists
sub get_name_form_from_list
  {
    my ($name, $namelistref) = @_;
    print "Trying to find '$name' in " . (join ' ', @$namelistref) . "\n" if ($conf{'debug'});
    my (@forms) = get_name_forms_for($name);
    my (@matches) = grep { is_str_in_list($_, @forms) } @$namelistref;
    return (@matches > 0) ? $matches[0] : undef;
  }

## Takes an author of a form like "Patrick F. Riley" and returns the 
## most specific formatted form, like "Riley, Patrick F."
sub get_most_exact_name_form
  {
    return last_of(get_name_forms_for($_[0]));
  }

# is_name_lesseq_exact_than(a, b) returns whether a is a possible name form of b
sub is_name_lesseq_exact_than
  {
    my ($a, $b) = @_;
    my (@bforms) = get_name_forms_for($b);
    # This last of gets the most specific name from a list of forms
    return is_str_in_list(get_most_exact_name_form($a), @bforms);
  }

## extract author last name
## processes first argument and returns a scalar
## takes a scalar
sub get_first_author_last_name
  {
    #return last_of(split /[\s~]+/, (first_of (split /\s+and\s+/, $_[0])));
    return first_of(get_last_names(get_names($_[0])));
  }

## Extracts a list of names form a single string  (separated by 'and')
sub get_names
  {
    return (split /\s+and\s+/, $_[0]);
  }

## extract last names from a list of authors
## returns a list of last names
sub get_last_names
  {
    #return map { last_of (split /\s+/, $_) } @_;
    return map { /,\s/ ? first_of (split /[\s,]+/, $_) : last_of (split /\s+/, $_) } @_;
    # This was the old variant that split on ~ as well. mmoll suggested not doing this
    # so that suffixes can be correctly handled by doing e.g. Patrick Riley,~Jr.
    #return map { last_of (split /[\s~]+/, $_) } @_;
  }
## takes a single bibentry
## returns the name to be used for sorting (either editor or author last name)
sub get_sort_name
  {
    return get_first_author_last_name((exists $_[0]->{'author'}) ? ($_[0]->{'author'}) : ($_[0]->{'editor'}));
    #return get_first_author_last_name($_[0]->{'author'});
  }

## takes a single bibentry
## returns a list of all author/editor last names
sub get_author_last_names
  {
    return (get_last_names(get_author_names(@_)));
  }

## takes a single bibentry
## returns a list of all author/editor names
sub get_author_names
  {
    return get_names((exists $_[0]->{'author'}) ? ($_[0]->{'author'}) : ($_[0]->{'editor'}));
  }

## takes a list reference of valid single bibentry
## returns a list of all author/editor last names that are in the list
## If the list is empty, returns all names
sub get_author_names_in_list
  {
    my ($listref, $beref) = @_;
    my ($name, @names, @output, $match);
    @names = get_author_names($beref);
    return @names if (@{$listref} == 0);
    foreach $name (@names) {
      $match = get_name_form_from_list($name, $listref);
      push (@output, $match) if (defined($match));
    }
    return @output;
  }

## takes a single bibentry
## returns a list of all author/editor last names
## Like get_author_last_names, but only returns names in $confmultline{'catlist_authors'}
## NOTE: uses the global var @allowed
sub get_allowed_author_names
  {
    return get_author_names_in_list(\@allowed, $_[0]);
  }

## extract the last name of the first author in the allowed list
## processes first argument and returns a scalar
## takes a bibentry ref
## NOTE: uses the global var @allowed
sub get_first_allowed_author_name
  {
    #return last_of(split /[\s~]+/, (first_of (split /\s+and\s+/, $_[0])));
    return first_of(get_allowed_author_names($_[0]));
  }

## Goes through all bibentries and finds all the authors with the most general name forms
## seen
## names that should be the same
## args: list of bibentry refs to search
## returns: list of names
sub find_all_authors
  {
    my $beref;
    my @out_names;
    my $name;
    my $idx;
    foreach $beref (@_) {
      NAME: foreach $name (get_author_names($beref)) {
          # Can't use get_name_form_from_list because @out_names is not in the
          # Riley, P. form but in P. Riley
          next NAME if (grep {is_name_lesseq_exact_than($_, $name)} @out_names);
          for ($idx = 0; $idx < @out_names; ++$idx) {
            if (is_name_lesseq_exact_than($name, $out_names[$idx])) {
              # $name has more info than $out_names. replace it and go on
              $out_names[$idx] = $name;
              next NAME;
            }
          }
          # $name is not a more general form of anything we already have
          push @out_names, $name;
        }
      }
    return @out_names;
  }

## trims two characters from the string
sub trim_two_chars
  {
    map {substr $_,2} @_;
  }

##adds a item to a hash which contains references to lists
## args: hash ref, key, new value
sub add_to_hash_list_ref
  {
    my ($hashref, $key, $value) = @_;
    if (exists $hashref->{$key}) {
      push @{$hashref->{$key}}, $value;
    } else {
      $hashref->{$key} = [$value];
    }
  }

## returns 1 if the first argument has balanced braces
## right now this just does a simple count check, not detecing order problems
sub is_brace_balanced
  {
    return ($_[0] =~ tr/\{//) == ($_[0] =~ tr/\}//);
  }

## returns the string if it matches and undef otherwise
sub is_str_in_list
  {
    my ($str, @list) = @_;
    my ($x);
    $str = lc $str;
    foreach $x (@list) {
      return $x if ($str eq (lc $x));
    }
    return undef;
  }

## removes anythign contained in a \macro{}
## The content must be {} balanced
## args: macro name, string to have macro removed
## return: string with \macro{} removed
sub remove_particular_latex
  {
    my ($macro, $str) = @_;
    return replace_particular_latex($macro, '', $str);
  }

## replaces thing contained in a \macro{}
## The content must be {} balanced
## replacement string can use '#1' as the content of the macro
## if an aux_format function (string -> string) is given, it will be called
## on the replacement (after #1 substitution)
## args: macro name, replacement string, string to have macro removed, aux format func ref
## return: string with \macro{} replaced by replacement string
sub replace_particular_latex
  {
    my ($macro, $repl, $str, $aux_form_func_ref) = @_;
    my ($val, $thisrepl);
    while ($str =~ /\\$macro\s*\{/g) {
      my $startpos = pos $str;
      for (;;) {
	die "Unbalanced {} in '$str'" if (not $str =~ /\G([^\}]*\})/cg);
	last if (is_brace_balanced(substr($str, $startpos - 1, pos($str) - $startpos + 1)));
      }
      my $endpos = pos $str;
      $val =  substr($str, $startpos, $endpos - $startpos - 1);
      $thisrepl = $repl;
      $thisrepl =~ s/\#1/$val/g;
      $thisrepl = &$aux_form_func_ref($thisrepl) if (defined ($aux_form_func_ref));
      # take out the content of the \macro
      substr($str, $startpos, $endpos - $startpos - 1) = '';
      ($str =~ s/\\$macro\s*\{\}/$thisrepl/) || die "How did I not replace a \\$macro I found?";
    }
    return $str;
  }

## gets the size (in bytes) of the file passed in
sub get_file_size
  {
    return ((stat($_[0]))[7]);
  }

## Takes two arguments: first is a dir to be considered the current working dir,
##                      second is a file name to resolve
## returns a path where this file can be accessed from the curent working dir, but not
##  necesarily the canonical path
sub resolve_path
  {
    my ($start_dir, $path) = @_;
    if ($path =~ /^\//) {
      return $path;
    }
    return "$start_dir/$path";
  }

## Fills in values from a hash into variable spots in the string
## Args: string (with var spots), hash reference
## Return: string with vars filled in
## vars look like %var; your inserted value should not have any % signs!
sub fill_in_vars
  {
    my ($str, $hashref) = @_;
    my ($key);
    foreach $key (keys %$hashref) {
      $str =~ s/\%$key/$hashref->{$key}/gi;
    }
    return $str;
  }

## Uses the value of conf{'link_as_html'} to determine whether to put .xml or .html after the file stem
## args: file stem (no extension, but can have a path)
## return: new file name with .html or .xml appended
sub get_final_file
  {
    my ($str) = @_;
    if ($conf{'link_as_html'}) {
      $str .= '.html';
    } else {
      $str .= '.xml';
    }
    return $str;
  }

## cleans up a classification name to avoid spurios mismatches
## args: string (of a class name)
## return canonical name for the class
sub canonicalize_class_name
  {
    my ($name) = @_;
    $name =~ s/\s+/ /g;
    return $name;
  }

## Takes a filename with possible bad characters and transforms
## it to something usable
## args: string (file name)
## return: normalized file name
sub normalize_file_name
  {
    my ($val) = @_;
    $val =~ s/&/_/;
    $val =~ s/;/_/;
    $val =~ s/\s+/_/;
    return $val;
  }

## Returns whether the file name (arg 1) looks to be a conf file
sub is_conf_file_name
  {
    return $_[0] =~ /\.conf$/;
  }

##############
## Execution functions

## args: exec line, expected return, is signal bad?, is core dump bad?
## return true is the function executed successfully
sub system_w_check
  {
    my ($exec_line, $exp_ret, $signal_bad, $core_dump_bad) = @_;
    my $res = system $exec_line;
    return 0 if ($res == -1); # exec failed
    return 0 if ($res >> 8) != $exp_ret;
    return 0 if ($signal_bad && ($res & 127));
    return 0 if ($core_dump_bad && ($res & 128));
    return 1;
  }

##############
## Sorting and classifying functions

## $a anbd $b bib entry refs
sub sort_bydate
  {
    return ($b->{'year'} <=> $a->{'year'})
  }

## $a anbd $b bib entry refs
sub sort_bydate_then_author_last
  {
    return ($b->{'year'} <=> $a->{'year'}) if ($b->{'year'} != $a->{'year'});
    return ( get_sort_name($a) cmp get_sort_name($b) );
  }

## $a anbd $b bib entry refs
sub sort_by_author_last
  {
    return ( get_sort_name($a) cmp get_sort_name($b) );
  }

# note that this does not use $a and $b
sub sort_by_num_two_chars ($$)
  {
    return (substr ($_[0], 0, 2) <=> substr($_[1], 0, 2))
  }

# this function take a bibentry ref
# it is meant to be given to generate_sorted_file
sub always_output
  {
    my ($beref) = @_;
    return "Foo";
  }

# this function take a bibentry ref
# it is meant to be given to generate_sorted_file
sub never_output
  {
    return undef;
  }

# uses a global var to store the last year
# if called with no args, reset the global vars
sub for_sort_year_header
  {
    my ($beref) = @_;
    return ($global_year_header = undef) if (!defined($beref));
    if (!defined($global_year_header) || $global_year_header != $beref->{'year'})
      {
	$global_year_header = $beref->{'year'};
	return $global_year_header;
      }
    return undef;
  }

# uses a global var to store the last year
# if called with no args, reset the global vars
sub for_sort_author_header
  {
    my ($beref) = @_;
    my ($name);
    return ($global_first_author_header = undef) if (!defined($beref));
    $name = xmlfm_class_name(get_sort_name($beref));
    if (!defined($global_first_author_header) || 
	$global_first_author_header ne $name)
      {
	$global_first_author_header = $name;
	return $global_first_author_header;
      }
    return undef;
  }

## classifies bib entries according to a specified value
## args: field to classify, ref to list of possible value, list of entries
## returns a hash reference for the classification
sub classify_bibentries
  {
    my ($field, $allowedlistref, $ignoredlistref, @belist) = @_;
    my (%outhash);
    my ($beref, $entry, $key, $cnt);
    foreach $beref (@belist) {
      $cnt = 0;
      if (exists $beref->{$field}) {
	foreach $entry (split /\s*,\s*/, $beref->{$field}) {
	  $entry = canonicalize_class_name($entry);
	  if ( is_str_in_list($entry, @$ignoredlistref)) {
	    print ("For classification: entry " . $beref->{'KEY'} . ", field '$field', ignoring '$entry'\n") if ($conf{'debug'});
	  } elsif ( is_str_in_list($entry, @$allowedlistref)) {
	    print ("Adding " . $beref->{'KEY'} . " with entry '$entry' to classifications\n") if ($conf{'debug'});
	    add_to_hash_list_ref(\%outhash, lc $entry, $beref);
	    $cnt++;
	  } else {
	    $key = $beref->{'KEY'};
	    warn "Warning: Value '$entry' in field '$field' of entry '$key' is not in the allowed list" unless ($conf{'suppress_classify_warnings'});
	  }
	}
      } else {
	print ("For classification: entry " . $beref->{'KEY'} . " has no field '$field'\n") if ($conf{'debug'});
      }
      if ($cnt == 0) {
	add_to_hash_list_ref(\%outhash, 'unspecified', $beref);
      }
    }
    return \%outhash;
  }

## classifies bib entries based on the output of a given function
## args: ref to func, list of entries
## The func should take a bib entry ref and return a list of entry values
## returns a hash reference for the classification
## Note that there is NO list of allowed values
sub classify_bibentries_by_func
  {
    my ($funcref, @belist) = @_;
    my (%outhash);
    my ($beref, $entry);
    foreach $beref (@belist) {
      foreach $entry (&$funcref($beref)) {
	add_to_hash_list_ref(\%outhash, lc $entry, $beref);
      }
    }
    return \%outhash;
  }

#########################################
## MAIN PROGRAM CODE

## First, set defaults for the parameters
# configurable setup parameters

$conf{'debug'} = 0;

$conf{'quiet'} = 0;

# This is where you want the html files put
$conf{'outputdir'} = '/tmp/';

$conf{'output_bibfile'} = '';

$conf{'generate'} = 'default date pubtype rescat';

$conf{'default_title'} = 'Default Ordering';
$conf{'date_title'} = 'Sorted by Date';
$conf{'author_title'} = 'Sorted by First Author Last Name';
$conf{'author_class_title'} = 'Classified by Author Last Name';
$conf{'author_class_2_title'} = 'Classified by Author Last Name';
$conf{'pubtype_title'} = 'Classified by Publication Type';
$conf{'rescat_title'} = 'Classified by Research Category';
$conf{'funding_title'} = 'Classified by Funding Source';
$conf{'index_title'} = 'Main Index';

$conf{'generate_detail_pages'} = 1;

$conf{'remove_bib2html_fields'} = 0;

$conf{'merge_duplicates'} = 1;

# we need to find this relative our current directory
$conf{'xsl_fn'} = 'trans_ex1.xsl';

# gives a directory to prefix xsl_fn with in the xml files which are output
$conf{'output_xsl_dir'} = '.';

$conf{'do_xml_verify'} = 0;
$conf{'xml_verify_cmdline'} = 'env PYTHONPATH=/usr/lib/python2.2/site-packages/ python /usr/lib/python2.2/site-packages/XSV/commandLine.py %XMLFN %XSDFN';
$conf{'xml_verify_exp_ret'} = 0;

$conf{'do_xsl_transform'} = 1;
$conf{'xsl_transform_cmdline'} = 'saxon -o %OUTFN %INFN %XSLFN';
$conf{'xsl_transform_exp_ret'} = 0;

$conf{'remove_xml_files'} = 0;

$conf{'link_as_html'} = 1;

$conf{'suppress_classify_warnings'} = 0;

$conf{'title_html_tag'} = 0;

$conf{'generate_bibtex_files'} = 0;

# This group of options controls the names of field that are used
$conf{'bibfield_abstract'} = 'abstract';
$conf{'bibfield_wwwnote'} = 'wwwnote';
$conf{'bibfield_extra_info'} = 'bib2html_extra_info';
$conf{'bibfield_pubtype'} = 'bib2html_pubtype';
$conf{'bibfield_rescat'} = 'bib2html_rescat';
$conf{'bibfield_funding'} = 'bib2html_funding';
$conf{'bibfield_dl_pdf'} = 'bib2html_dl_pdf';
$conf{'bibfield_dl_ps'} = 'bib2html_dl_ps';
$conf{'bibfield_dl_psgz'} = 'bib2html_dl_psgz';
$conf{'bibfield_dl_html'} = 'bib2html_dl_html';
$conf{'bibfield_dl_url'} = 'url';

$confmultline{'catlist_rescat'} = [];
$confmultline{'catlist_rescat_ignored'} = [];
$confmultline{'catlist_pubtype'} = [];
$confmultline{'catlist_pubtype_ignored'} = [];
$confmultline{'catlist_funding'} = [];
$confmultline{'catlist_funding_ignored'} = [];
$confmultline{'catlist_authors'} = [];
$confmultline{'catlist_authors_ignored'} = [];
$confmultline{'catlist_authors_2'} = [];
$confmultline{'catlist_authors_2_ignored'} = [];
$confmultline{'paperfiledirlist'} = [];
$confmultline{'bibtex_file_comments'} = [];
$confmultline{'author_urls'} = [];

parse_conf_file_hash_w_multline(\%conf, \%confmultline, 'bib2html.conf');
# Now parse any conf files on the command line
foreach $fn (@ARGV) {
  next if (not is_conf_file_name($fn));
  parse_conf_file_hash_w_multline(\%conf, \%confmultline, $fn);
}

%author_urls = 
  (map { die "author_urls must contain | separator '$_'" if (not /\|/); split /\s*\|\s*/, $_, 2 } 
   (@{$confmultline{'author_urls'}}));

print ("This is bib2html v".$version." (date: ".$version_date.")\n") unless ($conf{'quiet'});

print "URLs for Authors: " . (join ' ', (keys %author_urls)) . "\n" if ($conf{'debug'});

# new make sure the various categoried are canonicalized
map { $_ = canonicalize_class_name($_) } @{$confmultline{'catlist_rescat'}};
map { $_ = canonicalize_class_name($_) } @{$confmultline{'catlist_rescat_ignored'}};
map { $_ = canonicalize_class_name($_) } @{$confmultline{'catlist_pubtype'}};
map { $_ = canonicalize_class_name($_) } @{$confmultline{'catlist_pubtype_ignored'}};
map { $_ = canonicalize_class_name($_) } @{$confmultline{'catlist_funding'}};
map { $_ = canonicalize_class_name($_) } @{$confmultline{'catlist_funding_ignored'}};

@file_formats = ('pdf', 'ps.gz', 'ps', 'html');

$scriptdir = dirname($0);
$scriptdir = cwd() . '/' . $scriptdir if ($scriptdir =~ /^\./);
warn "$scriptdir";

$| = 1;

## read in the bib files
&add_default_strings;

print "Reading bib files: " unless ($conf{'quiet'});
foreach $fn (@ARGV) {
  # skip anything that looks like a conf file
  next if (is_conf_file_name($fn));

  open (FH, "<$fn") || die "Could not open file '$fn'";

  $cnt = 0;
  $skip_cnt = 0;
  while (($res = read_bib_entry(\*FH))) {
    $cnt++ if ($res > 0);
    $skip_cnt++ if ($res < 0);
    print '.' unless ($conf{'quiet'});
  }

  print STDERR "Read $cnt bib entries ($skip_cnt skipped) from '$fn'\n" if ($conf{'debug'});
}
print "\n" unless ($conf{'quiet'});


# this is for debugging
#print_all(\*STDOUT, @bibentry);
#foreach $beref (@bibentry) {
#  print STDERR htmlfm_author($beref->{'author'})."\n";
#}
#&print_strings;
#print ((last_of (qw(a b c)))."\n");
#print ((first_of (qw(a b c)))."\n");
#print ("value: ".(get_first_author_last_name("pat riley and manuela veloso")));
#print (("value: ".(get_sort_name($bibentry[0]))[0])."\n");
#foreach $bib (@bibentry) {
#  print ((get_sort_name($bib))."\t");
#}
#map {get_sort_name($_)} (@bibentry);
#print ((join "\t", (map {get_sort_name($_)} (@bibentry)))."\n");
#$ref = \&always_output;
#print ((&$ref($bibentry[0]))."\n");
#print ( "Value0:".(join '\t',@testmult)."\n");
#print ( "Value1:".(join '\t',@{$confmultline{'catlist_pubtype'}})."\n");
#print ( "Value2:".(join '\t',(@foo))."\n");

#print ((&get_xml_gen_message)."\n");
#print (get_xml_paper_info(1, $bibentry[0]));
#print (get_xml_paper_info(1, $bibentry[1]));
#print "1\n" if ( is_str_in_list('a', (qw(a b c d e f))));
#print "2\n" if ( is_str_in_list('f', (qw(a b c d e f))));
#print "3\n" if ( is_str_in_list('q', (qw(a b c d e f))));
#print "4\n" if ( is_str_in_list('abcd', (qw(a b c d e f))));

#$test = "{CMU}nited-97: {R}obo{C}up-97 Small-Robot World";
#print "Canonicalize\n$test\n".(canonicalize_title($test))."\n";
#$test = "Proceedings of the 1996 IEEE International";
#print "Canonicalize\n$test\n".(canonicalize_title($test))."\n";
#$test = "{PRODIGY}4.0: {T}he Manual and Tutorial";
#print "Canonicalize\n$test\n".(canonicalize_title($test))."\n";
#die;

#print "Names for 'Patrick F. Riley'\n";
#print ((join "\n", get_name_forms_for('Patrick F. Riley')) . "\n");
#print "Names for 'Test Alice Bob Eve'\n";
#print ((join "\n", get_name_forms_for('Test Alice Bob Eve')) . "\n");
#print ("get_name_form_from_list: " . get_name_form_from_list("Patrick F. Riley", ['Bob, F', 'Alice', 'Riley, P.', 'Guy, S.']) . "\n");
#print ("get_name_form_from_list: " . get_name_form_from_list("Does N. Exist", ['Bob, F', 'Alice', 'Riley, P.', 'Guy, S.']) . "\n");
#die;

#print "Author URLS:\n";
#foreach $author (keys %author_urls) {
#  print "$author has url " . $author_urls{$author} . "\n";
#}
#die;

#print ("All authors: \n" . (join "\n", find_all_authors(@bibentry))); die;

# To remove entries specifically flagged as to be ignored
# Added by Peter Stone 1/24/04
@pruned_bibentry = remove_ignored_entries(@bibentry);

# Tries to remove duplicates
duplicate_reduce(\@pruned_bibentry) if ($conf{'merge_duplicates'});

error_check_bib_entries(@pruned_bibentry);
check_for_duplicate_keys(@pruned_bibentry);
check_for_valid_authors(@pruned_bibentry);

print "Finding all authors:" unless ($conf{'quiet'});
@all_authors = find_all_authors(@pruned_bibentry);
print "\tDone\n" unless ($conf{'quiet'});

# Now we set the @main_pages var appropriately
foreach $page (split /\s+/, $conf{'generate'}) {
  $page = lc($page);
 SWITCH: {
    ($page eq 'default') && do {
      push @main_pages, [$page, 'sort_default', $conf{'default_title'}];
      last;
    };
    ($page eq 'date') && do {
      push @main_pages, [$page, 'sort_date', $conf{'date_title'}];
      last;
    };
    ($page eq 'author') && do {
      push @main_pages, [$page, 'sort_author', $conf{'author_title'}];
      last;
    };
    ($page eq 'author_class') && do {
      push @main_pages, [$page, 'class_author', $conf{'author_class_title'}];
      last;
    };
    ($page eq 'author_class_2') && do {
      push @main_pages, [$page, 'class_author_2', $conf{'author_class_2_title'}];
      last;
    };
    ($page eq 'pubtype') && do {
      push @main_pages, [$page, 'class_type', $conf{'pubtype_title'}];
      last;
    };
    ($page eq 'rescat') && do {
      push @main_pages, [$page, 'class_rescat', $conf{'rescat_title'}];
      last;
    };
    ($page eq 'funding') && do {
      push @main_pages, [$page, 'class_funding', $conf{'funding_title'}];
      last;
    };
    ($page eq 'index') && do {
      push @main_pages, [$page, 'index', $conf{'index_title'}];
      last;
    };
    die "Did not understand generate entry '$page'";
  }
}

# now generate detail files for every bib entry
if ($conf{'generate_detail_pages'}) {
  print "Generating detail pages: " unless ($conf{'quiet'});
  foreach $beref (@pruned_bibentry) {
    #generate_detail_file($beref);
    generate_xml_detail_file($beref);
    print '.' unless ($conf{'quiet'});
  }
  print "\n" unless ($conf{'quiet'});
}

# now generate bibtex files for every bib entry
if ($conf{'generate_bibtex_files'}) {
  print "Generating bibtex files: " unless ($conf{'quiet'});
  foreach $beref (@pruned_bibentry) {
    generate_bibtex_file($beref);
    print '.' unless ($conf{'quiet'});
  }
  print "\n" unless ($conf{'quiet'});
}

# we use the sorted by date as the initial for many things
#@sorted = sort sort_bydate @pruned_bibentry;
@sorted = sort sort_bydate_then_author_last @pruned_bibentry;

if ($conf{'output_bibfile'} ne '') {
  print 'Generating output bib file...' unless ($conf{'quiet'});
  open (OUTBIB, ">".$conf{'output_bibfile'}) 
    || die "Could not open out bibfile '".$conf{'output_bibfile'}."': $!";
  print_all(\*OUTBIB);
  close (OUTBIB);
  print " done\n" unless ($conf{'quiet'});
}

print "Generating list pages: " unless ($conf{'quiet'});

# Some temporary code: generates separate bib files
#$typeclassref = classify_bibentries_by_func(\&get_first_allowed_author_name, @sorted);
#$typeclassref = classify_bibentries_by_func(\&get_allowed_author_names, @sorted);
#create_files_from_class($conf{'outputdir'}, $typeclassref);

foreach $page_entry_ref (@main_pages) {
 SWITCH: {
    ($page_entry_ref->[0] eq 'default') && do {
      generate_xml_sorted_file($page_entry_ref->[1],
			       "list_papers_by_default",
			       $page_entry_ref->[2],
			       \&never_output,
			       @pruned_bibentry);
      last;
    };
    ($page_entry_ref->[0] eq 'date') && do {
      generate_xml_sorted_file($page_entry_ref->[1],
			       "list_papers_by_date",
			       $page_entry_ref->[2],
			       \&for_sort_year_header,
			       @sorted);
      last;
    };
    ($page_entry_ref->[0] eq 'author') && do {
      @sorted_author = sort sort_by_author_last @pruned_bibentry;
      generate_xml_sorted_file($page_entry_ref->[1],
			       "list_papers_by_author",
			       $page_entry_ref->[2],
			       \&for_sort_author_header,
			       @sorted_author);
      last;
    };
    ($page_entry_ref->[0] eq 'author_class') && do {
		my @names = @{$confmultline{'catlist_authors'}};
		my @ignore = @{$confmultline{'catlist_authors_ignored'}};
		
		# allowed is a GLOBAL VAR used by the classifying function
		@allowed = [];
		foreach $name (@names ? @names : @all_authors) {
			$match = get_name_form_from_list($name, \@ignore);
			push (@allowed, get_most_exact_name_form($name)) if (not defined($match));
		}
		@allowed = sort(@allowed) if (@names == 0);


      #note that we use sorted here
      $typeclassref = classify_bibentries_by_func(\&get_allowed_author_names, @sorted);
      print ("DEBUG: allowed authors: " . (join ' | ', (keys %$typeclassref)) . "\n") if ($conf{'debug'});
      generate_xml_classified_file($page_entry_ref->[1],
				   "list_papers_by_author_class",
				   $page_entry_ref->[2],
				   $typeclassref,
				   \@allowed,
				   \&xmlfm_author_class_name);
      last;
    };
    ($page_entry_ref->[0] eq 'author_class_2') && do {
		my @names = @{$confmultline{'catlist_authors_2'}};
		my @ignore = @{$confmultline{'catlist_authors_2_ignored'}};
		
		# allowed is a GLOBAL VAR used by the classifying function
		@allowed = [];
		foreach $name (@names ? @names : @all_authors) {
			$match = get_name_form_from_list($name, \@ignore);
			push (@allowed, get_most_exact_name_form($name)) if (not defined($match));
		}
		@allowed = sort(@allowed) if (@names == 0);
	
      #note that we use sorted here
      $typeclassref = classify_bibentries_by_func(\&get_allowed_author_names, @sorted);
      generate_xml_classified_file($page_entry_ref->[1],
				   "list_papers_by_author_class",
				   $page_entry_ref->[2],
				   $typeclassref,
				   \@allowed,
				   \&xmlfm_author_class_name);
      last;
    };
    ($page_entry_ref->[0] eq 'pubtype') && do {
      #note that we use sorted here
      $typeclassref = classify_bibentries($conf{'bibfield_pubtype'},
					  $confmultline{'catlist_pubtype'},
					  $confmultline{'catlist_pubtype_ignored'},
					  @sorted);
      generate_xml_classified_file($page_entry_ref->[1],
				   "list_papers_by_pubtype",
				   $page_entry_ref->[2],
				   $typeclassref,
				   $confmultline{'catlist_pubtype'},
				   \&first_of); #use first_of like the identify func
      last;
    };
    ($page_entry_ref->[0] eq 'rescat') && do {
      #note that we use sorted here
      $typeclassref = classify_bibentries($conf{'bibfield_rescat'},
					  $confmultline{'catlist_rescat'},
					  $confmultline{'catlist_rescat_ignored'},
					  @sorted);
      generate_xml_classified_file($page_entry_ref->[1],
				   "list_papers_by_rescat",
				   $page_entry_ref->[2],
				   $typeclassref,
				   $confmultline{'catlist_rescat'},
				   \&first_of); #use first_of like the identify func
      last;
    };
    ($page_entry_ref->[0] eq 'funding') && do {
      #note that we use sorted here
      $typeclassref = classify_bibentries($conf{'bibfield_funding'},
					  $confmultline{'catlist_funding'},
					  $confmultline{'catlist_funding_ignored'},
					  @sorted);
      generate_xml_classified_file($page_entry_ref->[1],
				   "list_papers_by_funding",
				   $page_entry_ref->[2],
				   $typeclassref,
				   $confmultline{'catlist_funding'},
				   \&first_of); #use first_of like the identify func
      last;
    };
    ($page_entry_ref->[0] eq 'index') && do {
      generate_xml_index_file($page_entry_ref->[1]);
      last;
    };
    die "Did not understand generate entry (after processing) '$page_entry_ref->[0]'";
  }
  print '.' unless ($conf{'quiet'});
}
print "\n" unless ($conf{'quiet'});

# Verify the generated files match the schema
if ($conf{'do_xml_verify'}) {
  print "Verifying the generated XML files: " unless ($conf{'quiet'});
  foreach $xmlfn (@generated_xml_files) {
    $verify_cmdline_repl{'XMLFN'} = $xmlfn;
    $verify_cmdline_repl{'XSDFN'} = $scriptdir . '/bib2html.xsd';
    $cmdline = fill_in_vars($conf{'xml_verify_cmdline'}, \%verify_cmdline_repl);
    system_w_check ($cmdline, $conf{'xml_verify_exp_ret'}, 1, 1)
      || die "Verification of xml file '$xmlfn' failed";
    print '.' unless ($conf{'quiet'});
  }
  print "\n" unless ($conf{'quiet'});
}

# Transform the xml files to html
if ($conf{'do_xsl_transform'}) {
  print "Transforming XML files to HTML: " unless ($conf{'quiet'});
  foreach $xmlfn (@generated_xml_files) {
    $xsl_cmdline_repl{'OUTFN'} = $xmlfn;
    $xsl_cmdline_repl{'OUTFN'} =~ s/\.xml$/.html/;
    $xsl_cmdline_repl{'INFN'} = $xmlfn;
    $xsl_cmdline_repl{'XSLFN'} = $conf{'xsl_fn'};
    $cmdline = fill_in_vars($conf{'xsl_transform_cmdline'}, \%xsl_cmdline_repl);
    system_w_check ($cmdline, $conf{'xsl_transform_exp_ret'}, 1, 1)
      || die "Transformation of xml file '$xmlfn' failed";
    print '.' unless ($conf{'quiet'});
  }
  print "\n" unless ($conf{'quiet'});
}

if ($conf{'remove_xml_files'}) {
  print "Removing XML files: " unless ($conf{'quiet'});
  foreach $xmlfn (@generated_xml_files) {
    unlink($xmlfn) || warn("Could not remove xml file '$xmlfn': $!");
    print '.' unless ($conf{'quiet'});
  }
  print "\n" unless ($conf{'quiet'});
}

