#!/usr/bin/perl
#
# @File File.pm
# $Id$
#
#
# @Author Marco Curti <marcoc1712@gmail.com>
# @Created 1-nov-2015 23.53.58
#
		
#print ( (caller(1))[3] )."\n";
#print "\n";

package Utils::Log;

use strict;

#use File::Spec::Functions qw(:ALL);

sub evalLog{
	my $logLevel= shift;
	my $msgLevel= shift;
	
	my $level={
		'verbose'	=> 0,
		'debug'		=> 2,
		'info'		=> 4,
		'warn'		=> 6,
		'error'		=> 8,
		'die'		=> 9,
	};
	
	if ($level->{$logLevel} > $level->{$msgLevel}){
		
		return 0;
	}
	return 1;
}

sub writeLog {
	my $logfile=shift;
	my $msg = shift;
	my $isDebug = shift;
	my $logLevel = shift || 'warn';
	my $msgLevel= shift || 'warn';
	
	my $now = localtime;
	my $line = qq([$now] $msg);
	
	if (evalLog($logLevel, $msgLevel)){
                
                
		if (open(my $fh, ">>", qq($logfile))){
                
                    print $fh "\n $line \n";
                    close $fh;

                } else{
                    
                   #die ("can't write logFile ".qq($logfile));
                   #do nothing at the moment.
                   
                   #TODO: Beter handle logs.
                    
                }
                
                if ($isDebug){

			print $line."\n";
		}  
	}
}
sub dieMessage{
	my $logfile=shift;
	my $msg=shift;
	my $isDebug = shift;
	my $logLevel = shift|| 'warn';
	
	writeLog($logfile, qq(ERROR: $msg),$isDebug,$logLevel,'die');
	die ($msg);
}
sub errorMessage{
	my $logfile=shift;
	my $msg=shift;
	my $isDebug = shift;
	my $logLevel = shift|| 'warn';
	
	writeLog($logfile, qq(ERROR: $msg),$isDebug,$logLevel, 'error');
}
sub warnMessage{
	my $logfile=shift;
	my $msg=shift;
	my $isDebug = shift;
	my $logLevel = shift|| 'warn';
	
	writeLog($logfile, qq(WARNING: $msg),$isDebug,$logLevel, 'warn');
}
sub infoMessage{
	my $logfile=shift;
	my $msg=shift;
	my $isDebug = shift;
	my $logLevel = shift|| 'warn';
	
	writeLog($logfile, qq(INFO: $msg),$isDebug,$logLevel, 'info');
}
sub debugMessage{
	my $logfile=shift;
	my $msg=shift;
	my $isDebug = shift;
	my $logLevel = shift|| 'warn';
	
	writeLog($logfile, qq(DEBUG: $msg),$isDebug,$logLevel, 'debug');
}
sub verboseMessage{
	my $logfile=shift;
	my $msg=shift;
	my $isDebug = shift;
	my $logLevel = shift|| 'warn';
	
	writeLog($logfile, qq(DEBUG: $msg),$isDebug,$logLevel, 'verbose');
}
1;