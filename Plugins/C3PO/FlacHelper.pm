#!/usr/bin/perl
#
# @File FfmpegHelper.pm
# @Author Marco Curti <marcoc1712@gmail.com>
# @Created 7-nov-2015 21.21.24
#

package Plugins::C3PO::FlacHelper;

use strict;

sub encode{
	my $transcodeTable =shift;
	Plugins::C3PO::Logger::verboseMessage('Start flac encode');
	
	return transcode($transcodeTable,'');
}
sub decode{
	my $transcodeTable =shift;
	Plugins::C3PO::Logger::verboseMessage('Start flac decode');
	
	# TODO:
	# To decode directly in split, we should take care of the desired 
	# output codec.
	# See also useFlacToDecodeWhenSplitting.
	#
	return transcode($transcodeTable,'d');
}
sub transcode{
	my $transcodeTable =shift;
	my $decode=shift;
	
	my $isRuntime	= Plugins::C3PO::Transcoder::isRuntime($transcodeTable);
	my $start = $transcodeTable->{'options'}->{'startTime'};
	my $end = $transcodeTable->{'options'}->{'endTime'};
	my $file = $transcodeTable->{'options'}->{'file'};
	my $exe=$transcodeTable->{'pathToFlac'};
	
	my $compression	= $transcodeTable->{'outCompression'};
		
	Plugins::C3PO::Logger::verboseMessage('Start flac transcode');
	
	$compression =_getCompression($compression);
	
	my $commandString="";
	if (!defined $decode || $decode eq ''){
		
		$commandString = '-cs --totally-silent --compression-level-'.$compression.' ';
	}
	else{
	
		$commandString = '-dcs --totally-silent ';
	}
	
	if ($isRuntime){

		$commandString= qq("$exe" $commandString);
		
		if (defined $start){
			$commandString = $commandString.'--skip='.$start.' ';
		}
		if (defined $end){
			$commandString = $commandString.'--until='.$end.' ';
		}
		if ((defined $file) && !($file eq "")){
		
			$commandString = qq($commandString-- "$file");

		} elsif ($file eq "-"){
		
			$commandString =$commandString.'-- -';
			
		}else {
		
			$commandString =$commandString.'--';
		}

		return $commandString;
		
	} else {

		return '[flac] '.$commandString.'$START$ $END$ -- $FILE$';
	}
}
sub _getCompression{
	my $compression= shift;
	
	if (!defined $compression) {$compression= 0;}
	
	$compression = (( grep { $compression eq $_ } 0,5,8 ) ? $compression : 0);
	return $compression;
}
1;