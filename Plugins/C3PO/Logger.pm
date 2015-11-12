#!/usr/bin/perl
#
# @File File.pm
# $Id$
#
#
# @Author Marco Curti <marcoc1712@gmail.com>
# @Created 1-nov-2015 23.53.58
#

package Plugins::C3PO::Logger;

use strict;

#use File::Spec::Functions qw(:ALL);

sub getLogFile{
	my $logFolder=shift;
	my $filemane= shift || 'C-3PO.log';

	return File::Spec->catdir($logFolder, $filemane);
}

sub writeLog {
	my $msg = shift;
	Utils::Log::writeLog($main::logfile,$msg,$main::isDebug,$main::logLevel,'info');
}
sub verboseMessage{
	my $msg=shift;
	Utils::Log::verboseMessage($main::logfile,$msg,$main::isDebug,$main::logLevel);
}
sub debugMessage{
	my $msg=shift;
	Utils::Log::debugMessage($main::logfile,$msg,$main::isDebug,$main::logLevel);
}
sub infoMessage{
	my $msg=shift;
	Utils::Log::infoMessage($main::logfile,$msg,$main::isDebug,$main::logLevel);
}
sub warnMessage{
	my $msg=shift;
	Utils::Log::warnMessage($main::logfile,$msg,$main::isDebug,$main::logLevel);
}
sub errorMessage{
	my $msg=shift;
	Utils::Log::errorMessage($main::logfile,$msg,$main::isDebug,$main::logLevel);
}
sub dieMessage{
	my $msg=shift;
	Utils::Log::dieMessage($main::logfile,$msg,$main::isDebug,$main::logLevel);
}
sub guessFileFatal{
	my $filemane= shift || 'C-3PO.fatal';
	
        my $dir;
        
        if (main::ISWINDOWS || main::ISMAC){
        
            #require File::HomeDir;

            $dir = File::HomeDir->my_home;
        
        } else {
        
            #some sort of linux, in UBUNTU we could not write in the home dir...
            
            $dir= "/var/log";
            
        }
        my $fatal=File::Spec->catfile($dir, $filemane);
        return $fatal;
}
1;