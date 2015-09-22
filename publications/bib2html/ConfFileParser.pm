# This is a perl module for configuration file parsing
# The configuration file has lines like this
# paramname: value
# where paramname is alphanumeric and
# value is anything, but leading and trailing white space are removed

package ConfFileParser;
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(parse_conf_file_global parse_conf_file_hash parse_conf_file_hash_w_multline);
@EXPORT_OK = ();

##args: file to parse, list of acceptable arguments
## Sets main::param  to value. It's a big hack to be setting this main vars. Oh well
## return: -1 on error, number of parameters read otherwise
sub parse_conf_file_global
  {
    my ($fn, @accept) = @_;
    my (%accept, $line, $cnt);
    local $_;
    map { $accept{$_} = '' } @accept; #make a hash of the list
    if (not open (CONFFH, "<$fn")) {
      warn "ConfFileParser: Could not open conf file '$fn': $!";
      return -1;
    }

    $line = 0;
    $cnt = 0;
    while (<CONFFH>) {
      $line++;
      chomp;
      s/\#.*//;
      next if (/^\s*$/);
      if (not /^\s*(\w+)\s*:\s*(.*?)\s*$/) {
	warn "ConfFileParser: Do not understand line $line of file '$fn': $_";
	next;
      }
      $param = $1;
      $value = $2;
      if (not exists $accept{$param}) {
	warn "ConfFileParser: Param '$param' is not understood (line $line of file '$fn')";
	next;
      }
      $param = "main::$param";
      $$param = $value;
      $cnt++;
    }
    return $cnt;
  }

##args: ref to hash with acceptable values (and used for return), list of files
## Sets hashref->{'param'} to value.
## return: -1 on error, number of parameters read otherwise
sub parse_conf_file_hash
  {
    my ($hashref, @filelist) = @_;
    my ($line, $cnt, $fn);
    local $_;

    $cnt = 0;
    foreach $fn (@filelist) {
      $line = 0;
      if (not open (CONFFH, "<$fn")) {
	warn "ConfFileParser: Could not open conf file '$fn': $!";
	next;
      }
      while (<CONFFH>) {
	$line++;
	chomp;
	s/\#.*//;
	next if (/^\s*$/);
	if (not /^\s*(\w+)\s*:\s*(.*?)\s*$/) {
	  warn "ConfFileParser: Do not understand line $line of file '$fn': $_";
	  next;
	}
	$param = $1;
	$value = $2;
	if (not exists $hashref->{$param}) {
	  warn "ConfFileParser: Param '$param' is not understood (line $line of file '$fn')";
	  next;
	}
	$hashref->{$param} = $value;
	$cnt++;
      }
    }

    return $cnt;
  }

## like parse_conf_file_hash, except you can have multiline options of the form
## <paramname>:
## <val1>
## <val2>
## END
##args: ref to hash with acceptable values (and used for return),
##      ref to hash with acceptable multi-line values (each entry should be an array ref),
##      list of files
## Sets hashref->{'param'} to value.
## return: -1 on error, number of parameters read otherwise
sub parse_conf_file_hash_w_multline
  {
    my ($hashref, $multlinehashref, @filelist) = @_;
    my ($line, $cnt, $fn, $inmult, $param, $value);
    local $_;

    $cnt = 0;
    foreach $fn (@filelist) {
      $line = 0;
      if (not open (CONFFH, "<$fn")) {
	warn "ConfFileParser: Could not open conf file '$fn': $!";
	next;
      }
      while (<CONFFH>) {
	$line++;
	chomp;
	s/\#.*//;
	next if (/^\s*$/);
	if ($inmult)
	  {
	    if (/^\s*END\s*$/)
	      {
		$inmult = 0;
	      }
	    else
	      {
		s/^\s*//;
		s/\s*$//;
		push @{$multlinehashref->{$param}}, $_;
	      }
	    next;
	  }
	if (not /^\s*(\w+)\s*:\s*(.*?)\s*$/) {
	  warn "ConfFileParser: Do not understand line $line of file '$fn': $_";
	  next;
	}
	$param = $1;
	$value = $2;
	if (exists $multlinehashref->{$param}) {
	  @{$multlinehashref->{$param}} = ();
	  $inmult = 1;
	} elsif (exists $hashref->{$param}) {
	  $hashref->{$param} = $value;
	} else {
	  warn "ConfFileParser: Param '$param' is not understood (line $line of file '$fn')";
	  next;
	}
	$cnt++;
      }
    }

    return $cnt;
  }


# we have to return 1 to make the use happy
1;
