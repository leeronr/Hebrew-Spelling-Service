#!/usr/bin/perl -w
# Copyright (C) 2002-2003 Nadav Har'El and Dan Kenigsberg
use Carp;
use strict;
use Getopt::Long;
use IO::File;

my $VERSION="0.5";

# process command line options:
# -v: verbose (shows derivation of accepted words)
# -c: correct (suggests corrections)
# -s: severity (sorts wrong words in order of number of appearances).
# -n: notes (gives longer notes explaining selected spelling errors).
# -a: for use in pipe (a la ispell's -a).
# -i: use slave ispell

# Set the defaults for the options
my %opts;

# Allow bundling of the short options, e.g., -nc
Getopt::Long::Configure ("bundling");

sub help(){
	print "hspell - Hebrew spellchecker\n".
	      "Usage: $0 [-acinsv] [file...]\n\n".
	      "See hspell(1) manual for a description of hspell and its ".
	      "options.\n";
}

#if(!getopts('vcsnaid:Bm', \%opts)){
if(!GetOptions('correct|c'  => \$opts{c},
               'notes|n'    => \$opts{n},
               'severity|s' => \$opts{s},
               'verbose|v'  => \$opts{v},
               'ispell-slave|i'  => \$opts{i},
               'a'  => \$opts{a},
               'd=s'  => \$opts{d},
               'B'  => \$opts{B},
               'm'  => \$opts{m},
               'version|V'  => sub {print "Hspell $VERSION\nWritten by Nadav ".
	       		      "Har'El and Dan Kenigsberg\n"; exit(0)},
               'help|h'     => sub {help(); exit(0)},
)){
	&help();
	exit(1);
}

if (defined($opts{d}) || defined($opts{B}) || defined($opts{m})) {
	print STDERR "Warning: ispell options -d, -B and -m ".
		     "are ignored by hspell.\n";
}
my $verbose=defined($opts{v});
my $correct=defined($opts{c});
my $severity=defined($opts{s});
my $shownotes=defined($opts{n});
my $interpipe=defined($opts{a}) || ($0 =~ m{-i});
my $slave=defined($opts{i}) || ($0 =~ m{-i});

my $strict_smichut=0;

my @dictionaries=("out.nouns","out.nouns-shemp","out.verbs","milot","extrawords","biza-verbs", "biza-nouns");
#my @dictionaries=("zcat wordlist.wgz|wunzip|");
my @likelyerror_dictionaries=("likelyerrors");
my @spellinghints_dictionaries=();
@spellinghints_dictionaries=("spellinghints") if $shownotes;

# If it exists, use ~/.hspell_words. This is sort of an ad-hoc feature,
# because words in that list do not automatically get inflected.
my @optional_dictionaries=($ENV{HOME}."/.hspell_words","hspell_words");
push @dictionaries, grep {-f $_} @optional_dictionaries;

my $dict;
my %dictionary;
my %likelyerrors;
# read dictionaries
foreach $dict (@dictionaries) {
	my $F = new IO::File;
	my $save=""; # used for verbose mode
	$F->open($dict) or croak "Couldn't open dictionary file $dict";
	$save="xxx" if $dict eq "extrawords"; # ad-hoc, sign for file without stems
	# The speed of the following loop has a great effect on startup time,
	# so we want the inner loop to be as quick as possible! When the
	# various if's were inside the inner loop start up time took (with
	# around 100,000 words) about 5.5 seconds. With the tight loop, it
	# takes 3.4 seconds.
	# This can be further droped to 2.5 seconds if we could remove the
	# s/-$//o command! (e.g., if we're sure the dictionary files doesn't
	# contain those useless (when !$strict_smichut) smichut characters).
	if(!$verbose && !$strict_smichut){
		while(<$F>){
			if(/^[�-�A-Z]/o){
				chomp;
				# s/-$//o;
				# changed to ignore extra descriptions in
				# extrawords
				s/[- ].*$//o;
				$dictionary{$_}=1;
			}
		}
 	} else {
		while(<$F>){
			chomp;
			if(/^[-#]/o){
				# ignore comments, and ---- seperators
				$save=""; # used for verbose mode
			} else {
				s/-//o if(!$strict_smichut);
				if($verbose){
					# tell the user where the word was found...
					if($save eq ""){
						$save=$_;
						$save =~ s/^L/�/o;
					}
					my $s;
					if($save eq "xxx"){
						$s=$dict;
					} else {
						$s="$dict:$save";
					}
					if(exists($dictionary{$_})){
						# ignore double matches
						next if($dictionary{$_} =~ m/$s(,|$)/);
						$dictionary{$_}=$dictionary{$_}.", ".$s;
					} else {
						$dictionary{$_}=$s;
					}
				} else {
					$dictionary{$_}=1;
				}
			}
		}
	}
}

# If we add the empty word to the dictionaries valid prefixes with no
# word after them get accepted. This is useful for when a valid prefix
# (�, ��, etc.) get followed by a number or a non-Hebrew word (usually
# separated by a makaf).
$dictionary{""}=1;

foreach $dict (@likelyerror_dictionaries) {
	my $F = new IO::File;
	$F->open($dict) or croak "Couldn't open dictionary file $dict";
	while(<$F>){
		chomp;
		if(/^\s*#|^\s*$|^-*$/o){
			# ignore comments, white lines and ---- seperators.
		} else {
			$likelyerrors{$_}=1; # TODO: maybe in the future use values
		}
	}
}

my %spellinghints;
foreach $dict (@spellinghints_dictionaries) {
	my $F = new IO::File;
	$F->open($dict) or croak "Couldn't open spelling hints file $dict";
	my $desc="";
	my $lastdesc;
	while(<$F>){
		chomp;
		if(/^\s*#|^\s*$|^-*$/o){
			# ignore comments, white lines and ---- seperators.
		} elsif(/^\+/o){
			# + lines add to the description
			$desc=$desc." ".substr($_,1)."\n";
		} else {
			# word lines use that description
			if($desc ne ""){
				$lastdesc=$desc;
				$desc="";
			}
			$spellinghints{$_}=$lastdesc;
		}
	}
}


my %wrongwords;
my %warnwords;

my @prefixes = (
	"",
	"�","�","�","�","�","�","�",
	"��", "��", "��", "��",
	"��", "��", "��", "��",
	"��", "��", "��",
	"��", "��", "��", "��", "��", "��",
	"��", "��", "��",
	"��", "��", "��", "��",
	"��", # ex: ���� �����, ����� ...
	"���", "����", # ex: �������, ...
	"���","���","���","���","���","���","���",
	"���","���","���","���","���","���","���","���",
	"���","���","���","���",
	"����", "����", "����", "����", "����","����",
	"�����",
        "���","����","����","����","����","�����",
);

sub check_word {
	my $word = shift;
	# ignore empty words
	return 1 if $word =~ m/^[-'" ]*$/o;
	my ($prefix,$plen);
	foreach $prefix (@prefixes){
		$plen=length($prefix);
		if((substr($word,0,length($prefix)) eq $prefix)){
			# ad-hoc trick: eat up " if necessary, to recognize
			# stuff like �"����", �"�����", etc.
			if(length($word) > length($prefix) &&
		 	        substr($word,length($prefix),1) eq '"'){
				$plen++;
			}
			# The first UGLY if() here is the academia's ktiv male
			# rule of doubling a vav (not yud!) starting a word,
			# unless it's already next to a vav.
			# The "elsif" check below is the normal case.
			if($prefix ne "" &&
			   substr($word,$plen,1) eq '�' &&
			   substr($prefix,-1,1) ne '�'){
				if(substr($word,$plen+1,1) eq '�'){
					if(substr($word,$plen+2,1) ne '�' &&
					   exists ($dictionary{substr($word,$plen+1)})){
						if($verbose){
							print "found $word: prefix '$prefix' doubled '�' stem $dictionary{substr($word,$plen+1)}\n";
						}
						if(exists($likelyerrors{substr($word,$plen+1)})){
							return 2+$plen+1;
						} else {
							return 1;
						}
					} elsif(exists ($dictionary{substr($word,$plen)})){
						if($verbose){
							print "found $word: prefix '$prefix' (nondoubled '�') stem $dictionary{substr($word,$plen)}\n";
						}
						if(exists($likelyerrors{substr($word,$plen)})){
							return 2+$plen+1;
						} else {
							return 1;
						}
					}
				}
			# the normal check for word minus the prefix:
			} elsif(exists ($dictionary{substr($word,$plen)})){
				if($verbose){
					print "found $word: prefix '$prefix' stem $dictionary{substr($word,$plen)}\n";
				}
				if(exists($likelyerrors{substr($word,$plen)})){
					return 2+$plen;
				} else {
					return 1;
				}
# 			adding gimatria check here slows things down, and
#                       worse: adds a lot of weird "corrections" because
#			trycorrect calls check_word with an extra " before
#                       the last letter, to check for acronyms....
#			} elsif($word=~/['"]/o && &is_canonic_gimatria($word)){
#				if($verbose){
#					print "found $word: canonic gimatria\n";
#				}
#				return 1;
			# ad-interim trick to check for bachlam+maqor: if a
			# word L����� in the dictionary (as generated by 'woo')
			# we allow any of bachlam to replace the L
			} elsif(($prefix =~ m/[����]$/o) &&
				exists ($dictionary{"L".substr($word,$plen)})){
				if($verbose){
					print "found $word: prefix '$prefix' L-form of stem $dictionary{'L'.substr($word,$plen)}\n";
				}
				if(exists($likelyerrors{substr($word,$plen-1)})){
					return 2+$plen-1;
				} else {
					return 1;
				}
			# ad-interim trick to check for b+maqor: if a
			# word B���� in the dictionary (as generated by 'woo')
			# we allow most � prefixes to replace the B
			} elsif(($prefix =~ m/^�?�?�$/o) &&
				exists ($dictionary{"B".substr($word,$plen)})){
				if($verbose){
					print "found $word: prefix '$prefix' B-form of stem $dictionary{'B'.substr($word,$plen)}\n";
				}
				if(exists($likelyerrors{substr($word,$plen-1)})){
					return 2+$plen-1;
				} else {
					return 1;
				}
			}
		}
	}
	return 0;
}

# ad-hoc attempt to find corrections for word
sub trycorrect {
	my $word = shift;
	my @results;
	my $i;
	# try to add a missing em kri'a - yud or vav
	for($i=1;$i<length($word);$i++){
		my $w=$word;
		substr($w,$i,1)='�'.substr($w,$i,1);
		if(check_word($w)==1){
			push @results,$w if not grep(m/$w/,@results);
		}
		$w=$word;
		substr($w,$i,1)='�'.substr($w,$i,1);
		if(check_word($w)==1){
			push @results,$w if not grep(m/$w/,@results);
		}
	}
	# try to remove an em kri'a - yud or vav
	for($i=0;$i<length($word);$i++){
		my $w=$word;
		if(substr($w,$i,1) eq '�' || substr($w,$i,1) eq '�'){
			substr($w,$i,1)='';
			if(length($w)>0 && check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
	}
	# try to add or remove an aleph (is that useful?)
	for($i=1;$i<length($word);$i++){
		my $w=$word;
		substr($w,$i,1)='�'.substr($w,$i,1);
		if(check_word($w)==1){
			push @results,$w if not grep(m/$w/,@results);
		}
	}
	for($i=0;$i<length($word);$i++){
		my $w=$word;
		if(substr($w,$i,1) eq '�'){
			substr($w,$i,1)='';
			if(length($w)>0 && check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
	}
	# try to replace similarly sounding (for certain people) letters:
	#    ��� �� �� �� �� �� �� ��� ��
	for($i=0;$i<length($word);$i++){
		my $w;
		if(substr($word,$i,1) eq '�' || substr($word,$i,1) eq '�' ||
		   substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�' || substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�' || substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='��';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�' || substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,2) eq '��'){
		   	$w=$word; substr($w,$i,2)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�' || substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
		if(substr($word,$i,1) eq '�'){
		   	$w=$word; substr($w,$i,1)='�';
			if(check_word($w)==1){
				push @results,$w if not grep(m/$w/,@results);
			}
		}
	}
	# try to replace a non-final letter at the end of the word by its
	# final form and vice versa (useful check for abbreviations):
	if(substr($word,-1,1) =~ /[����������]/){
		my $w=substr($word,0,-1);
		my $e=substr($word,-1,1);
		$e =~ tr/����������/����������/;
		$w=$w.$e;
		if(check_word($w)==1){
			push @results,$w if not grep(m/$w/,@results);
		}
	}
	# try to make the word into an acronym (add " before last character)
	if(length($word)>=2){
		my $w=substr($word,0,-1);
		my $e=substr($word,-1,1);
		$w=$w.'"'.$e;
		if(check_word($w)==1){
			push @results,$w if not grep(m/$w/,@results);
		}
	}
	# try to make the word into an abbreviation (add ' at the end)
	my $w=$word."'";
	if(check_word($w)==1){
		push @results,$w if not grep(m/$w/,@results);
	}
#	# try to remove any letter
#	for($i=0;$i<length($word);$i++){
#		my $w=$word;
#		substr($w,$i,1)='';
#		if(check_word($w)==1){
#			push @results,$w if not grep(m/$w/,@results);
#		}
#	}
#	# try to add any letter (warning: very slow, maybe should be an option)
#	for($i=0;$i<length($word);$i++){
#		my $letter;
#		for($letter=ord('�'); $letter<ord('�'); $letter++){
#			my $w=$word;
#			substr($w,$i,1)=chr($letter).substr($w,$i,1);
#			if(check_word($w)==1){
#				push @results,$w if not grep(m/$w/,@results);
#			}
#		}
#	}
	return join(", ",@results);

}

### A function for checking for valid gimatria:
sub is_canonic_gimatria {
  my $s = shift;
  return &int2gim(&gim2int($s)) eq $s;
}
sub gim2int {
  my $gim = shift;
  my $n = 0;
  my %gim2int = ('�'=>1,'�'=>2,'�'=>3,'�'=>4,'�'=>5,'�'=>6,'�'=>7,'�'=>8,'�'=>9,
       '�'=>10,'�'=>20,'�'=>20,'�'=>30,'�'=>40,'�'=>40,'�'=>50,'�'=>50,
       '�'=>60,'�'=>70,'�'=>80,'�'=>80,'�'=>90,'�'=>90,'�'=>100,'�'=>200,
       '�'=>300,'�'=>400,'"'=>0);
  my ($chnk, $c);

  foreach $chnk (split "'", $gim) {
    $n *= 1000;
    foreach $c (split //, $chnk) {
      $n += $gim2int{$c};
    }
  }
  return $n;
}
sub int2gim {
  my $n = shift;
  my $gim = "";
  return undef if $n <= 0;
  my $tmp = &_aux_ig($n);
  return $gim.$tmp."'" if $tmp =~ m/(^|').$/;
  $tmp =~ s/([^'])$/\"$1/o;
  $tmp =~ s/�$/�/o;
  $tmp =~ s/�$/�/o;
  $tmp =~ s/�$/�/o;
  $tmp =~ s/�$/�/o;
  $tmp =~ s/�$/�/o;
  return $gim.$tmp;
}
sub _aux_ig {
  my $n = shift;
  my ($gim, $val) = ("", 0);
  my %int2gim = (1=>'�',2=>'�',3=>'�',4=>'�',5=>'�',6=>'�',7=>'�',8=>'�',
      9=>'�',10=>'�',15=>'��',16=>'��',17=>'��',18=>'��',19=>'��',20=>'�',
      30=>'�',40=>'�',50=>'�',60=>'�',70=>'�', 80=>'�',90=>'�',100=>'�',
      200=>'�',300=>'�',400=>'�');
  my @vals = sort { $b <=> $a } keys %int2gim;

  if ($n >= 1000) {
    $gim = &_aux_ig(($n - $n%1000)/1000)."'";
    $n = $n % 1000;
  }
  foreach $val (@vals) {
    while ($n >= $val) {
      $gim .= $int2gim{$val};
      $n -= $val;
    }
  }
  return $gim;
}
###########


# spell-check the input files
if ($interpipe) {
	if ($slave) {
		# TODO: pass -d -B and -m to ispell
		my $args="-a";
		open(ISPELL,"|ispell $args");
		autoflush ISPELL 1;
	} else {
		print "@(#) International Ispell Version 3.1.20 (but really Hspell $VERSION)\n";
	}
}
$| = 1 if $interpipe;
my ($res, $line, $offset);
while(<>){
	#if ($interpipe && m/^[#!~^%-+&*]/) { #ispell command lines
	if ($interpipe && m/^[#!~@%\-+&*]/) { #ispell command lines
		print ISPELL if $slave;
		next;
	}
	chomp;
	$line = $_;
	$offset = -1;
	# convert a literal "&#1470;" (HTML makaf) into -
	s/&#1470;/-/go;
	my @array;
	if($strict_smichut){
		@array=split(/[^�-�'"-]+|(-)/o);
	} else {
		@array=split(/[^�-�'"]+/o);
	}
	my ($word, $word1, $word2);
	while (@array){
		if($strict_smichut){
			$word1=shift(@array);
			$word2=shift(@array); # contains a - or nothing
			if(defined($word2)){
				$word=$word1.$word2;
			} else {
				$word=$word1;
			}
		} else {
			$word=shift(@array);
		}
		$offset=index($line,$word,$offset+1) if $interpipe;
		# convert two single quotes ('') into one double quote (").
		# For TeX junkies.
		$word =~ s/''/"/go;
		# remove quotes from end or beginning of the word (we do
		# leave, however, single quotes in the middle of the word -
		# used to signify "j" sound in Hebrew, for example, and double
		# quotes used to signify acronyms. A single quote at the end
		# of the word is used to signify an abbreviate - or can be
		# an actual quote (there is no difference in ASCII...), so we
		# must check both possibilities.
		$word =~ s/^['"]//o;
		$word =~ s/"$//o;
		$res=check_word($word);
		if($res!=1 && $word =~ /['"]/o){
			# maybe it's not a word, but rather gimatria?
			if(is_canonic_gimatria($word)){
				if($verbose){
					print "found $word: canonic gimatria\n";
				}
				$res=1;
			}
		}
		if($res!=1 && $word =~ /'$/o){
			# try again, without the quote...
			$word =~ s/'$//o;
			$res=check_word($word);
		}
		if($res==0){
			#$wrongwords{$word}=1
			$wrongwords{$word}++;
			print "? $word 0 $offset: ".trycorrect($word)."\n" if $interpipe;
		} elsif($res>1){
			$warnwords{substr($word,$res-2)}=1;
		}
	}
	if ($interpipe) {
		if ($slave) {
			s/[�-�]/ /og;
			print ISPELL "$_\n";
			next;
		} else {
			print "\n";
		}
        }
}

exit 0 if $interpipe;

my $word;
# list wrong words.
if(%wrongwords){
	if($correct){
		print "������ ���� ������, ��������� ��������:\n\n";
	} else {
		#print "wrong words:\n";
		print "������ ���� ������:\n\n";
	}
	my @badwords;
	if($severity){
		# sort according to severity (repeating incorrect words)
		@badwords = sort {$wrongwords{$b} <=> $wrongwords{$a}} keys %wrongwords;
	} else {
		# alphabetical sorting of the word
		@badwords = sort(keys %wrongwords);
	}
	foreach $word (@badwords){
		if($correct){
			# TODO: maybe enable printing the number just when
			# $severity is on? Or is it useful always?
			#print $word."  ->  ".trycorrect($word)."\n";
			print $wrongwords{$word}." ".$word."  ->  ".trycorrect($word)."\n";
		} else {
			print $word."\n";
		}
		if($shownotes && exists($spellinghints{$word})){
			print $spellinghints{$word};
		}
	}
}
if(%warnwords){
	if($correct){
		print "\n����� ������ ��� ������ ���� ������:\n\n";
	} else {
		#print "rare correct words that are common mispellings:\n";
		print "\n����� ������ ��� ������ ���� ������:\n\n";
	}
	foreach $word (sort(keys %warnwords)){
		if($correct){
			print $word."  ->  ".trycorrect($word)."\n";
		} else {
			print $word."\n";
		}
		if($shownotes && exists($spellinghints{$word})){
			print $spellinghints{$word};
		}
	}
}
