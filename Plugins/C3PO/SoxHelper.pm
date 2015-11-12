#!/usr/bin/perl
#
# @File SoxHelper.pm
# @Author Marco Curti <marcoc1712@gmail.com>
# @Created 7-nov-2015 22.54.30
#

package Plugins::C3PO::SoxHelper;

use strict;

sub resample{
	my $transcodeTable = shift;
	my $outSamplerate= shift;
	
	my $isRuntime = Plugins::C3PO::Transcoder::isRuntime($transcodeTable);
	
	my $isTranscodingRequested = 
		Plugins::C3PO::Transcoder::isTranscodingRequested($transcodeTable);
	
	my $useSoxToEncodeWhenResampling =
		Plugins::C3PO::Transcoder::useSoxToEncodeWhenResampling($transcodeTable);
	
	my $outChannels		=$transcodeTable->{'outChannels'};
	my $outBitDepth		=$transcodeTable->{'outBitDepth'};
	my $outEncoding		=$transcodeTable->{'outEncoding'};
	#my $outByteOrder	=$transcodeTable->{'outByteOrder'};
	my $outCompression	=$transcodeTable->{'outCompression'};
	my $quality			=$transcodeTable->{'quality'};
	my $phase			=$transcodeTable->{'phase'};
	my $aliasing		=$transcodeTable->{'aliasing'};
	my $bandwidth		=$transcodeTable->{'bandwidth'};
	my $gain			=$transcodeTable->{'gain'};
	my $dither			=$transcodeTable->{'dither'};
	
	my $file			=$transcodeTable->{'options'}->{'file'};
	
	my $inCodec			=$transcodeTable->{'transitCodec'};
	my $outCodec		=$transcodeTable->{'outCodec'};
	
	my $exe				=$transcodeTable->{'pathToSox'};
	my $command			=$transcodeTable->{'command'};

	Plugins::C3PO::Logger::verboseMessage('Start sox resample');

	my $outFormatSpec="";

	# -c 2 -r 19200 -3 -s -C 8

	if ($outSamplerate){$outFormatSpec= $outFormatSpec.' -r '.$outSamplerate};
	if ($outChannels){$outFormatSpec= $outFormatSpec.' -c '.$outChannels};
	if ($outBitDepth){$outFormatSpec= $outFormatSpec.' -'.$outBitDepth};
	if ($outEncoding){$outFormatSpec= $outFormatSpec.' -'.$outEncoding};
	#if ($outByteOrder){$outFormatSpec= $outFormatSpec.' -'.$outByteOrder};
	# TODO:
	# Remove $outByteOrder from parametres, should not be changed
	# and handled directly by SOX for different codecs.

	if ($outCompression){$outFormatSpec= $outFormatSpec.' -C '.$outCompression};
	
	my 	$rateString= ' rate';
	
	$aliasing		= $aliasing ? "a" : undef;
	$bandwidth		=($bandwidth/10)."";
	
	# rate -v -M -a -b 90.7 192000
	if ($quality){$rateString= $rateString.' -'.$quality};
	if ($phase){$rateString= $rateString.' -'.$phase};
	if ($aliasing){$rateString= $rateString.' -'.$aliasing};
	if ($bandwidth){$rateString= $rateString.' -b '.$bandwidth};
	if ($outSamplerate){$rateString= $rateString.' '.$outSamplerate};
	
	my $effects="";
	
	if ($gain){$effects= $effects.' gain -'.$gain};
	
	$effects=$effects.$rateString;
	
	if (!defined $dither){$effects= $effects.' -D'};
	
	$inCodec=_translateCodec($inCodec);
	
	if ($isTranscodingRequested &&
		$useSoxToEncodeWhenResampling){
		
		$outCodec=_translateCodec($outCodec);
		
	} else{
	
		$outCodec=$inCodec;
	}
	
	my $commandString;
	
	if ($isRuntime){
	
		$commandString = qq("$exe" );
	
	} else {
	
		$commandString = '[sox] ';
	}
	
	if ((!defined $command) || ($command eq "")){

		$commandString = $commandString.qq(-q -t $inCodec "$file" -t );

	} else {
	
		$commandString = $commandString.qq(-q -t $inCodec - -t );

	}
	$transcodeTable->{'transitCodec'}= _translateCodec($outCodec);
	$commandString = $commandString.qq($outCodec$outFormatSpec -$effects);

	return $commandString;

}

sub transcode{
	my $transcodeTable = shift;
	
	my $isRuntime		= Plugins::C3PO::Transcoder::isRuntime($transcodeTable);
	
	my $inCodec			= $transcodeTable->{'transitCodec'};
	my $outCodec		= $transcodeTable->{'outCodec'};
	my $file			= $transcodeTable->{'options'}->{'file'};
	my $command			= $transcodeTable->{'command'};
	my $outCompression	= $transcodeTable->{'outCompression'};
	my $exe				= $transcodeTable->{'pathToSox'};
	
	Plugins::C3PO::Logger::verboseMessage('Start soxTranscode');

	$inCodec=_translateCodec($inCodec);
	$outCodec=_translateCodec($outCodec);

	my $commandString = "";
	
	if (!defined ($command)|| ($command eq "")){

		$commandString = qq(-q -t $inCodec "$file" -t $outCodec );

	} else {
		
		$commandString = qq(-q -t $inCodec - -t $outCodec );
	}

	if ($outCompression){
		$commandString = $commandString.'-C '.$outCompression
	};
	
	if ($isRuntime){

		$commandString = qq("$exe" $commandString);
	
	} else{
	
		$commandString = '[sox] '.$commandString;
	}
	$commandString = $commandString."-";
	return $commandString;
}
sub _translateCodec{
	my $codec= shift;
	
	if ($codec eq 'flc') {return 'flac';}
	if ($codec eq 'flac') {return 'flc';}
	return $codec;
}
1;
