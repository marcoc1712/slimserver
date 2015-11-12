#!/usr/bin/perl
#
# @File DummyTranscoderHelper.pm
# @Author Marco Curti <marcoc1712@gmail.com>
# @Created 7-nov-2015 23.36.55
#

package Plugins::C3PO::DummyTranscoderHelper;

sub transcode{
	my $transcodeTable = shift;
	
	Plugins::C3PO::Logger::infoMessage('Start dummyTranscoder using sox');
	
	return Plugins::C3PO::SoxHelper::transcode($transcodeTable);

}
1;