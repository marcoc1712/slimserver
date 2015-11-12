package Plugins::C3PO::AudioScanHelper;

#
# See plugin.pm for description and terms of use.

use strict;
#use warnings;

#use FindBin qw($Bin);
#use lib $Bin;

#use Data::Dump;

sub getFileInfo{
	my $file = shift;
	#my $libPath = shift || $Bin;
		
	Plugins::C3PO::Logger::debugMessage('in getinfo');
	
	#Plugins::C3PO::Logger::verboseMessage('libPath: '.$libPath);
	#Plugins::C3PO::Logger::verboseMessage('@INC: '.Data::Dump::dump (@INC));
	#Plugins::C3PO::Logger::verboseMessage('Inc is: '.Data::Dump::dump(%INC));
	
	#unshift @INC, Utils::Config::expandINC($libPath);
	require Audio::Scan;

	Plugins::C3PO::Logger::debugMessage('@INC: '.Data::Dump::dump (@INC));
	Plugins::C3PO::Logger::debugMessage('Inc is: '.Data::Dump::dump(%INC));
	
	if ($file) {
		
		my $cpath = File::Spec->canonpath( $file ) ;
		my $data = Audio::Scan->scan($cpath);
		
		Plugins::C3PO::Logger::debugMessage('AudioScan: '.Data::Dump::dump ($data));

		return $data;
	}
	return undef;
	
}
1;



