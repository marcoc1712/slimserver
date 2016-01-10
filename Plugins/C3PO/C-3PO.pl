#!/usr/bin/perl
#
# This program is part of the C-3PO Plugin. 
# See Plugin.pm for credits, license terms and others.
#
# Logitech Media Server Copyright 2001-2011 Logitech.
# This Plugin Copyright 2015 Marco Curti (marcoc1712 at gmail dot com)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
#########################################################################
#
# Command line options.
#
# -c - client mac address (es. 00:04:20:12:b3:17) -> clientId
# -p - preference file.
# -l - log folder.
# -i - input stream format (es. flc) -> inFormat
# -o - output stream format (es. wav) -> outFormat
# -t - stream time start offset (m:ss.cc es. 24:46.02) -> startTime
# -v - stream time end offset (m:ss.cc es. 28:24.06) -> endTime
# -s - stream seconds start offset (hh:mm:ss.mmm es. 00:15:47.786) -> startSec
# -u - stream seconds end offset (hh:mm:ss.mmm es. 00:19:07.000) -> endSec
# -w - stream seconds duration (n*.n* es. 542.986666666667) -> durationSec
# -r - imposed samplerate
# -h - answer with an hello message, do nothing else.
# -d - run in debug mode, don't send the real command.
#
# The input file is the first and only parameter (with no option) in line.
#
#########################################################################

package main;

use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;

use File::Spec::Functions qw(:ALL);
use File::Basename;

my $C3PODir=$Bin;
my ($volume,$directories,$file) =File::Spec->splitpath($0);


#print '$volume is      : '.$volume."\n";
#print '$directories is : '.$directories."\n";
#print '$file is   : '.$file."\n";

if (!$file) {die "undefined filename";}

if ($file eq 'C-3PO.exe'){

	# We are running the compiled version in 
	# \Bin\MSWin32-x86-multi-thread folder inside the
	#plugin folder.
	
	$C3PODir = File::Spec->canonpath(getAncestor($Bin,2));

} elsif ($file eq 'C-3PO'){

	#running on linux or mac OS x from inside the Bin folder
	#$C3PODir= File::Spec->canonpath(File::Basename::dirname(__FILE__)); #C3PO Folder
	$C3PODir = File::Spec->canonpath(getAncestor($Bin,1));
        

} elsif ($file eq 'C-3PO.pl'){

	#running .pl 
	#$C3PODir= File::Spec->canonpath(File::Basename::dirname(__FILE__)); #C3PO Folder
	$C3PODir= $Bin;

} else{
	
	# at the moment.
	die "unexpected filename";
}

my $lib = File::Spec->rel2abs(catdir($C3PODir, 'lib'));
my $cpan= File::Spec->rel2abs(catdir($C3PODir,'CPAN'));
my $util= File::Spec->rel2abs(catdir($C3PODir,'Util'));

#print '$directories is : '.$lib."\n";
#print '$directories is : '.$cpan."\n";
#print '$directories is : '.$util."\n";

my @i=($C3PODir,$lib,$cpan);

unshift @INC, @i;

require Utils::Config;
unshift @INC, Utils::Config::expandINC($C3PODir);

# let standard modules load.
#
use constant SLIM_SERVICE => 0;
use constant SCANNER      => 1;
use constant RESIZER      => 0;
use constant TRANSCODING  => 0;
use constant PERFMON      => 0;
use constant DEBUGLOG     => ( grep { /--nodebuglog/ } @ARGV ) ? 0 : 1;
use constant INFOLOG      => ( grep { /--noinfolog/ } @ARGV ) ? 0 : 1;
use constant STATISTICS   => ( grep { /--nostatistics/ } @ARGV ) ? 0 : 1;
use constant SB1SLIMP3SYNC=> 0;
use constant IMAGE        => ( grep { /--noimage/ } @ARGV ) ? 0 : 1;
use constant VIDEO        => ( grep { /--novideo/ } @ARGV ) ? 0 : 1;
use constant MEDIASUPPORT => IMAGE || VIDEO;
use constant WEBUI        => 0;
use constant ISWINDOWS    => ( $^O =~ /^m?s?win/i ) ? 1 : 0;
use constant ISMAC        => ( $^O =~ /darwin/i ) ? 1 : 0;
use constant HAS_AIO      => 0;
use constant LOCALFILE    => 0;
use constant NOMYSB       => 1;
#
#######################################################################
require Logger;
require Transcoder;
require Shared;
require OsHelper;

require FfmpegHelper;
require FlacHelper;
require FaadHelper;
require SoxHelper;

require Utils::Log;
require Utils::File;
require Utils::Config;

require FileHandle;
require Getopt::Long;
require YAML::XS;
require File::HomeDir;
require Data::Dump;
require Audio::Scan;

our $logFolder;
our $logfile;
our $isDebug;
our $logLevel = main::DEBUGLOG ? 'debug' : main::INFOLOG ? 'info' : 'warn';

#$logLevel='verbose'; #to show more debug mesages
#$logLevel='debug';
#$logLevel='info';
#$logLevel='warn'; #to show less debug mesages

main();
#################

sub main{
	#
	# until we read preferences, we don't know where logfile is.
	# use a deault one instead.
	#
	$logfile = Plugins::C3PO::Logger::guessFileFatal();

	Plugins::C3PO::Logger::verboseMessage ('C3PO.pl Started');

	my $options=getOptions();
	if (!defined $options) {Plugins::C3PO::Logger::dieMessage("Missing options");}
	
	if (defined $options->{logFolder}){
	
		$logFolder=$options->{logFolder};

		Plugins::C3PO::Logger::verboseMessage ('found log foder in options: '.$logFolder);
		
		my $newLogfile= Plugins::C3PO::Logger::getLogFile($logFolder);
		Plugins::C3PO::Logger::verboseMessage("Swithing log file to ".$newLogfile);

		$logfile= $newLogfile;
		Plugins::C3PO::Logger::verboseMessage("Now log file is $logfile");
	
	}
	
	$isDebug= $options->{debug};
	if ($isDebug){
		Plugins::C3PO::Logger::infoMessage('Running in debug mode');
	}
	Plugins::C3PO::Logger::debugMessage('options '.Data::Dump::dump($options));
	
	if (defined $options->{hello}) {

		my $message="C-3PO says $options->{hello}! see $logfile for errors ".
					"log level is $logLevel";
					
		print $message;

		Plugins::C3PO::Logger::infoMessage($message);
		Plugins::C3PO::Logger::debugMessage('Bin is: '.$Bin);
		Plugins::C3PO::Logger::debugMessage('PluginDir is: '.$C3PODir);
		Plugins::C3PO::Logger::verboseMessage('Inc is: '.Data::Dump::dump(@INC));
		Plugins::C3PO::Logger::verboseMessage('Inc is: '.Data::Dump::dump(%INC));
		exit 0;
	}
	
	if (!defined $options->{clientId}) {Plugins::C3PO::Logger::dieMessage("Missing clientId in options")}
	if (!defined $options->{prefFile}) {Plugins::C3PO::Logger::dieMessage("Missing preference file in options")}
	if (!defined $options->{inCodec})  {Plugins::C3PO::Logger::dieMessage("Missing input codec in options")}
	
	my $prefFile=$options->{prefFile};
	Plugins::C3PO::Logger::debugMessage ('Pref File: '.$prefFile);
	
	my $prefs=loadPreferences($prefFile);
	if (!defined $prefs) {Plugins::C3PO::Logger::dieMessage("Invalid pref file in options")}
	Plugins::C3PO::Logger::debugMessage ('Prefs: '.Data::Dump::dump($prefs));

	my $clientId= $options->{clientId};
	Plugins::C3PO::Logger::debugMessage ('clientId: '.$clientId);

	my $client=Plugins::C3PO::Shared::buildClientString($clientId);
	Plugins::C3PO::Logger::debugMessage ('client: '.$client);
	
	my $serverFolder=$prefs->{'serverFolder'};
	if (!defined $serverFolder) {Plugins::C3PO::Logger::dieMessage("Missing ServerFolder")}
	Plugins::C3PO::Logger::debugMessage ('server foder: '.$serverFolder);

	#use prefs only if not already in options.
	if (!defined $options->{logFolder}){
		
		my $logFolder=$prefs->{'logFolder'};
		if (!defined $logFolder) {Plugins::C3PO::Logger::warnMessage("Missing log directory in preferences")}
		Plugins::C3PO::Logger::debugMessage ('log foder: '.$logFolder);

		Plugins::C3PO::Logger::verboseMessage("Swithing log file to ".catdir($logFolder, 'C-3PO.log'));

		$main::logfile= catdir($logFolder, 'C-3PO.log');

		Plugins::C3PO::Logger::verboseMessage("Now log file is $main::logfile");
	}
	
	my $transcodeTable=Plugins::C3PO::Shared::buildTranscoderTable($client,$prefs,$options);
	
	Plugins::C3PO::Logger::verboseMessage('Transcoder table : '.Data::Dump::dump($transcodeTable));
	Plugins::C3PO::Logger::verboseMessage('@INC : '.Data::Dump::dump(@INC));
	
	$transcodeTable->{'inCodec'}=$options->{inCodec};
	my $commandTable=Plugins::C3PO::Transcoder::buildCommand($transcodeTable);
	
	executeCommand($commandTable->{'command'});
}
# launch command and die, passing Output directly to LMS, so far the best.
# but does not work in Windows with I capability (socketwrapper involved)
#
sub executeCommand{
	my $command=shift;

	#some hacking on quoting and escaping for differents Os...
	$command= Plugins::C3PO::Shared::finalizeCommand($command);

	Plugins::C3PO::Logger::infoMessage(qq(Command is: $command));
	Plugins::C3PO::Logger::verboseMessage($main::isDebug ? 'in debug' : 'production');
	
	if ($main::isDebug){
	
		return $command;
	
	} else {
	
		my @args =($command);
		exec @args or &Plugins::C3PO::Logger::errorMessage("couldn't exec command: $!");	
	}
}
sub loadPreferences {
	my $file=shift;
	
	my $prefs;
	$prefs = eval {YAML::XS::LoadFile($file) };

	if ($@) {
		Plugins::C3PO::Logger::warnMessage("Unable to read prefs from $file : $@\n");
	}
	return $prefs;
}
sub getOptions{

	#Data::Dump::dump(@ARGV);

	my $options={};
	if ( @ARGV > 0 ) {

		Getopt::Long::GetOptions(	
			'd' => \$options->{debug},
			'h=s' => \$options->{hello},
			'l=s' => \$options->{logFolder},
			'p=s' => \$options->{prefFile},
			'c=s' => \$options->{clientId},
			'i=s' => \$options->{inCodec},
			'o=s' => \$options->{outCodec},
			't=s' => \$options->{startTime},
			'v=s' => \$options->{endTime},
			's=s' => \$options->{startSec},
			'u=s' => \$options->{endSec},
			'w=s' => \$options->{durationSec},
			'r=s' => \$options->{forcedSamplerate},
		);

		my $file;
		for my $str (@ARGV){

			if (!defined $file){

				$file=$str;

			} else {

				$file = qq($file $str);
			}
		}
		$options->{file}=$file;

		#print "\n\n\n".$options->{file}."\n";
		return $options;
	}
	return undef;
}
sub getAncestor{
	my $folder=shift;
	my $lev=shift || 1;
	
	#print $folder."\n";
	
	my ($volume,$directories,$file) =
                       File::Spec->splitpath( $folder, 1 );
	
	my @dirs = File::Spec->splitdir( $directories );

	my $dirs= @dirs;

	@dirs= splice @dirs, 0, $lev*-1;

	return File::Spec->catfile($volume, File::Spec->catdir( @dirs ), $file);
}
1;

