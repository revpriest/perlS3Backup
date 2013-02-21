#!/usr/bin/perl -w
#
# You'll need these of course:
# sudo apt-get install gnupg s3cmd gzip
#
# You'll have run
# $ s3cmd --configure
# and saved it's settings.
#
use strict;
use Getopt::Long;
use File::Basename;

##
# Help function
#
sub help{
    print "Usage: backupToS3.pl {Directory}\n";
    print "backupToS3.pl will make a configuration file in {Directory}/S3BackupConfig.cfg\n";
    print "and a file-database in {Directory}/S3BackupData.txt\n";
    print "You will need s3cmd installed, and gnu tar, and perl.\n";
    exit;
}



##
# Read a config file. If it isn't there, create
# a default and return that.
#
sub readConfigFile{
  my $path = shift;
  my $verbose = shift;
  my %vars;
  if(!open CONFIG, "$path/S3BackupConfig.cfg"){
    if(!open CONFIG, ">$path/S3BackupConfig.cfg"){
      print "Can't Create New Config File At $path/S3BackupConfig.cfg. Quitting.\n";
      exit 1;
    }
    print CONFIG "#S3Backup Config - Controlling All Files In $path/\n";
    print CONFIG "BucketName =\n";
    print CONFIG "GPGRecipient = {NO-ENCRYPTION}\n";
    print CONFIG "SaveProgressSeconds = 10    #Save database of backed up files this often during backup.\n";
    print CONFIG "MaxUploadSize = 1024000\n";
    print CONFIG "FileDatabase = $path/S3BackupDatabase.db\n";
    print CONFIG "TempDir = /tmp/s3Backup-".int(rand(10000))."\n";
    print CONFIG "#MaxFiles = 100\n";
    print CONFIG "#MaxMinutes = 360\n";
    close CONFIG;
    if(!open CONFIG, "$path/S3BackupConfig.cfg"){
      print "Can't read newly created Config File at $path/S3BackupConfig.cfg. Quitting\n";
      exit 1;
    }
  }

  #Read the config vars.
  while (<CONFIG>) {
        chomp;                  # no newline
        s/#.*//;                # no comments
        s/^\s+//;               # no leading white
        s/\s+$//;               # no trailing white
        next unless length;     # anything left?
        my ($var, $value) = split(/\s*=\s*/, $_, 2);
        $vars{lc($var)} = $value;
  }
  close CONFIG; 
  return %vars;
}


##
# Read a file database. We just save a list of every file we've
# tracked, the last alteration date we have for 'em and if they're
# backed up etc.
sub readFileDatabase{
  my $config = shift;
  my %data;
  my $fn = $config->{'filedatabase'};
  print "Reading Database $fn\n" if $config->{'verbose'};
  if(open DATA, "$fn"){
    while(<DATA>){
        chomp;                  # no newline
        s/^\s+//;               # no leading white
        s/\s+$//;               # no trailing white
        next unless length;     # anything left?
        if(m/^"(.*)" (\d*)$/){
          $data{$1} = $2;
        }else{
          print "  Bad Database Line: $_\n";
        }
    }
    close DATA;
  }
  return %data;
}


##
# Check all the files written in the database
# are already property backed up, we do this
# before we append any new files for sure.
sub checkBackedUpFiles{
  my $fileDb = shift;
  my $config = shift;
  while ((my $file, my $date) = each ($fileDb)) {
    print "    Checking existing file $file last backed up $date\n" if $config->{'verbose'};
    my $timestamp = (stat($file))[9];
    if(!defined($timestamp)){
      print "    $file has been deleted. Leaving on backup system.\n" if $config->{'verbose'};
    }else{
      if($timestamp>$date){
        backupFileAndUpdateDatabase($file,$timestamp,$fileDb,$config);
      }
    }
  }
}


##
# Make a temp directory given a certain path
#
sub makeTempDir{
  my $path = shift;
  my $bit = int(rand(100000000));
  mkdir($path,0777);
  mkdir($path."/".$bit,0700);
  return $path."/".$bit;
}



##
# Check if we're out of allotted time or
# bandwidth. Quit if we are.
#
sub checkLimits{
  my $config = shift;
  my $dFiles = shift;

  if(time()>int($config->{'timeatwrite'})+int($config->{'saveprogressseconds'})){
    writeDb($config);
  }

  if(defined($config->{"filesleft"})){
    $config->{"filesleft"} -= $dFiles;
    if($config->{"filesleft"} <= 0){
      cleanupAndQuit("Reached maximum files",$config);
      exit 2;
    }
  }

  if(defined($config->{"endminutes"})){
    if(time()>$config->{"endminutes"}){
      cleanupAndQuit("Reached maximum time",$config);
      exit 2;
    }
  }
}


##
# Upload a file to S3. We're given the path
# of the original file, the zipped and 
# encrypted and possibly split file name,
# and the configs etc.
#
sub uploadToS3{
  my $originalFilePath = shift;
  my $processedVersion = shift;
  my $extension = shift;
  my $config = shift;

  my $cmd = "s3cmd put $processedVersion s3://".$config->{'bucketname'}.$originalFilePath.$extension;
  my $result = `$cmd 2>/dev/null`;
  $config->{'chunkcount'}++;
  print "    ".$result if $config->{'verbose'};
  return;
}


##
# First we gzip it, then we encrypt it,
# then if needed we split it into chunks,
# then we upload each of the chunks.
#
sub encryptAndSendToS3{
  my $file = shift;
  my $config = shift;

  my $tmpdir = makeTempDir($config->{'tempdir'}); 
  my $basename = basename($file);

  print "  Zipping up: $file to $tmpdir/$basename.gz\n" if $config->{'verbose'};
  my @res = `gzip $file -c >$tmpdir/$basename.gz`;

  my $encryptionRecipient = $config->{'gpgrecipient'};
  my $gz = ".gz";
  if(($encryptionRecipient eq '') or ($encryptionRecipient eq "{NO-ENCRYPTION}")){
    print "  Skipping Encryption\n" if $config->{'verbose'};
  }else{
    print "  Encrypting: $tmpdir/$basename.gz to $tmpdir/$basename.gz.gpg\n" if $config->{'verbose'};
    my $cmd = "gpg -e -r ".$config->{"gpgrecipient"}." $tmpdir/$basename.gz";
    @res = `$cmd`;
    $gz = ".gz.gpg";
  }

  my $length = (stat("$tmpdir/$basename$gz"))[7];
  my $max = $config->{'maxuploadsize'};
  my $numParts = int($length/$max)+1;
  if($numParts>1){
    my $numDigits = length("".$numParts);
    print "  Splitting: $tmpdir/$basename$gz to $numParts bits\n" if $config->{'verbose'};
    my $cmd = "split -db $max -a $numDigits $tmpdir/$basename$gz $tmpdir/$basename.gz.gpg.";
    @res = `$cmd`;
    for(my $n=0;$n<$numParts;$n++){
      my $num = sprintf("%0".$numDigits."d",$n);
      uploadToS3($file,"$tmpdir/$basename$gz.$num","$gz.$num",$config);
    }
  }else{
    uploadToS3($file,"$tmpdir/$basename$gz",$gz,$config);
  }
  $config->{'filecount'}++;

  #Clean up
  `rm -rf $tmpdir`;

  #And check we're on for more.
  checkLimits($config,$numParts);
}



##
# Back up a file and update the database to show it
#
sub backupFileAndUpdateDatabase{
  my $file = shift;
  my $timestamp = shift;
  my $fileDb = shift;
  my $config = shift;
  encryptAndSendToS3($file,$config);
  $fileDb->{$file} = $timestamp;
  return;
}



##
# Find new files and add them to the DB
#
sub findNewFiles{
  my $fileDb = shift;
  my $path = shift;
  my $config = shift;
  my %newLines;
  if(!open FIND, "find $path -type f |"){
    print "Can't run find to get new files\n";
    cleanupAndQuit("ERROR: call to 'find' failed",$config);
    exit 1;
  }
  while(<FIND>){
    chomp;                  # no newline
    my $timestamp = (stat($_))[9];
    if((!exists $fileDb->{$_})||($fileDb->{$_}<$timestamp)){
      print "Found new file $_\n" if $config->{'verbose'};
      backupFileAndUpdateDatabase($_,$timestamp,$fileDb,$config);
    }else{
      #File already backed up.
    }
  }
  return \%newLines;
}


##
# Write the database
#
sub writeDb{
  my $config = shift;
  my $name = $config->{"filedatabase"};
  my $fileDb = $config->{"filedb"};

  if(!open FILE, ">$name"){
    print "DAMNIT! Can't write updated file Db. Quitting and being VERY sad.\n";
    exit 1;
  }
  print "* Backup Save Progress.....\n";
  while ((my $file, my $date) = each ($fileDb)) {
    print FILE "\"$file\" $date\n";
  }
  close FILE;
  $config->{'timeatwrite'} = time();
}


##
# Write an updated file database
#
sub cleanupAndQuit{
  my $message = shift;
  my $config = shift;
   
  writeDb($config);
  print $message." - ".$config->{"filecount"}." files as ".$config->{"chunkcount"}." chunks backed up.\n" if (!$config->{'quiet'});
  if($config->{'section'} ne 'end'){
    print "Quit during $config->{'section'}, before finishing.\n" if (!$config->{'quiet'});
  }

}

############################################## START #################################3


# Process Command Line 
my $backupPath="";
my $verbose = 0;
my $quiet = 0;
my $help = 0;
my $result = GetOptions("path=s" => \$backupPath,
                        "quiet"   => \$quiet,
                        "verbose"   => \$verbose,
                        "help"   => \$help);
if($help){help();}
$backupPath =  shift(@ARGV);
if(!$backupPath){ help(); }

my %config = readConfigFile($backupPath,$verbose);
if($config{"bucketname"} eq ""){
  print "Config file exists at $backupPath/S3BackupConfig.cfg but needs editing.\nIt needs AT LEAST a bucket name.\n";
  exit 1;
}
$config{'timeatwrite'} = time();
$config{'section'} = "init";
$config{'quiet'} = $quiet;
$config{'verbose'} = $verbose;
$config{'filecount'} = 0;
$config{'chunkcount'} = 0;
if(defined($config{"maxfiles"})){
  $config{"filesleft"} = $config{"maxfiles"};
}
if(defined($config{"maxminutes"})){
  $config{"endminutes"} = time()+int($config{"maxminutes"})*60;
  print "Will stop after ".$config{"maxminutes"}." minutes at ".$config{'endminutes'}."\n" if ($config{'verbose'});
}

my %fileDb = readFileDatabase(\%config);
$config{'filedb'} = \%fileDb;
$config{'section'} = "checking";

checkBackedUpFiles(\%fileDb,\%config);
$config{'section'} = "finding";
findNewFiles(\%fileDb,$backupPath,\%config);
$config{'section'} = "end";
cleanupAndQuit("Done",\%config);



