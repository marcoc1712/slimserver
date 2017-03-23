#!/usr/bin/perl
# $Id$
#
# Handles server side file type conversion and resampling.
# Replace custom-convert.conf.
#
# To be used mainly with Squeezelite-R2 
# (https://github.com/marcoc1712/squeezelite/releases)
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
################################################################################

package Plugins::Recorder::Plugin;

use strict;
use warnings;

use Data::Dump qw(dump pp);

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

if ( main::WEBUI ) {
	require Plugins::Recorder::Settings;
}

my $class;
my $preferences = preferences('plugin.recorder');
my $serverPreferences = preferences('server');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.recorder',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_RECORDER',
} );

#
###############################################
## required methods

sub getDisplayName {
	return 'PLUGIN_RECORDER';
}
	
sub initPlugin {
	$class = shift;

	$class->SUPER::initPlugin(@_);
	
	if (main::INFOLOG && $log->is_info) {
		$log->info('initPlugin');
	}

	if ( main::WEBUI ) {
		Plugins::Recorder::Settings->new($class);
	}
	$preferences->init({
			mac					=> "",
			codec				=> "flc",
			directory			=> "",
			prefix				=> "",
			suffix				=> ".flac",
			logfile				=> "",
			elementSize			=> "1",
			elementCount		=> "1024",
			delay				=> 0,
	});
	
	_disableProfiles();

	# Subscribe to new client events
	Slim::Control::Request::subscribe(
		\&newClientCallback, 
		[['client'], ['new']],
	);
	
	# Subscribe to reconnect client events
	Slim::Control::Request::subscribe(
		\&clientReconnectCallback, 
		[['client'], ['reconnect']],
	);
}
sub shutdownPlugin {
	Slim::Control::Request::unsubscribe( \&newClientCallback );
	Slim::Control::Request::unsubscribe( \&clientReconnectCallback );
}

sub newClientCallback {
	my $request = shift;
	my $client  = $request->client() || return;
	
	return _clientCalback($client,"new");
}

sub clientReconnectCallback {
	my $request = shift;
	my $client  = $request->client() || return;
	
	return _clientCalback($client,"reconnect");
}

sub settingsChanged{
	my $class = shift;
		
	if (main::DEBUGLOG && $log->is_debug) {	
			my $conv = Slim::Player::TranscodingHelper::Conversions();
			my $caps = \%Slim::Player::TranscodingHelper::capabilities;
			$log->debug("STATUS QUO ANTE: ");
			$log->debug("LMS conversion Table:   ".dump($conv));
			$log->debug("LMS Capabilities Table: ".dump($caps));
	}

	_disableProfiles();

	if (main::DEBUGLOG && $log->is_debug) {	
			my $conv = Slim::Player::TranscodingHelper::Conversions();
			my $caps = \%Slim::Player::TranscodingHelper::capabilities;
			$log->debug("AFTER PROFILES DISABLING: ");
			$log->debug("LMS conversion Table:   ".dump($conv));
			$log->debug("LMS Capabilities Table: ".dump($caps));
	}
	
	_setupCommand();
	
	if (main::DEBUGLOG && $log->is_debug) {	
			my $conv = Slim::Player::TranscodingHelper::Conversions();
			my $caps = \%Slim::Player::TranscodingHelper::capabilities;
			$log->debug("RESULT: ");
			$log->debug("LMS conversion Table:   ".dump($conv));
			$log->debug("LMS Capabilities Table: ".dump($caps));
	}
}
################################################################################

################################################################################
sub _clientCalback{
	my $client = shift;
	my $type = shift;
	
	my $id= $client->id();
	my $macaddress= $client->macaddress();
	my $modelName= $client->modelName();
	my $model= $client->model();
	my $name= $client->name();
	
	if (main::INFOLOG && $log->is_info) {
			 $log->info("$type ClientCallback received from \n".
						"id:                     $id \n".
						"mac address:            $macaddress \n".
						"modelName:              $modelName \n".
						"model:                  $model \n".
						"name:                   $name \n".
						"");
	}
	
	if ($preferences->get('mac') && ($preferences->get('mac') eq  $client->macaddress())) {
	
		_setupCommand();
		
		if (main::DEBUGLOG && $log->is_debug) {		
				my $conv = Slim::Player::TranscodingHelper::Conversions();
				$log->debug("transcodeTable: ".dump($conv));
		}
	} 
	
	return 1;
}

sub _disableProfiles{
	
	my $mac = $preferences->get('mac');
	
	my $conv = Slim::Player::TranscodingHelper::Conversions();
	
	if (main::DEBUGLOG && $log->is_debug) {		
		$log->debug("transcodeTable: ".dump($conv));
	}
	
	for my $profile (keys %$conv){
		
		#flc-pcm-*-00:04:20:12:b3:17
		#aac-aac-*-*
		
		my ($inputtype, $outputtype, $clienttype, $clientid) = _inspectProfile($profile);
		
		if ($clientid eq $mac){
		
			if (main::DEBUGLOG && $log->is_debug) {		
				$log->debug("disable: ". $profile);
			}
			
			_disableProfile($profile);

			delete $Slim::Player::TranscodingHelper::commandTable{ $profile };
			delete $Slim::Player::TranscodingHelper::capabilities{ $profile };

		}
	}
	
	if (main::DEBUGLOG && $log->is_debug) {		
				my $conv = Slim::Player::TranscodingHelper::Conversions();
				$log->debug("transcodeTable: ".dump($conv));
	}
}

sub _disableProfile{
	my $profile = shift;
	my @disabled = @{ $serverPreferences->get('disabledformats') };
	my $found=0;
	for my $format (@disabled) {
		
		if ($format eq $profile){
			$found=1;
			last;}
	}
	if (! $found ){
		push @disabled, $profile;
		$serverPreferences->set('disabledformats', \@disabled);
		$serverPreferences->writeAll();
		$serverPreferences->savenow();
	}
}

sub _inspectProfile{
	my $profile=shift;
	
	my $inputtype;
	my $outputtype;
	my $clienttype;
	my $clientid;;
	
	if ($profile =~ /^(\S+)\-+(\S+)\-+(\S+)\-+(\S+)$/) {

		$inputtype  = $1;
		$outputtype = $2;
		$clienttype = $3;
		$clientid   = lc($4);
		
		return ($inputtype, $outputtype, $clienttype, $clientid);	
	}
	return (undef,undef,undef,undef);
}

sub _buildProfile{
	my $macaddress = shift;
	my $codec = shift;

	return $codec.'-'.$codec.'-*-'.$macaddress;
}

sub _enableProfile{
	my $profile = shift;
	my @out = ();
	
	my @disabled = @{ $serverPreferences->get('disabledformats') };
	for my $format (@disabled) {

		if ($format eq $profile) {next;}
		push @out, $format;
	}
	$serverPreferences->set('disabledformats', \@out);
	$serverPreferences->writeAll();
	$serverPreferences->savenow();
}

sub _setupCommand{

	my $macaddress = $preferences->get('mac');
	my $codec = $preferences->get('codec');
	my $directory = $preferences->get('directory');
	my $prefix = $preferences->get('prefix');
	my $suffix = $preferences->get('suffix');
	my $logfile = $preferences->get('logfile');
	my $elementSize = $preferences->get('elementSize');
	my $elementCount = $preferences->get('elementCount');
	my $delay = $preferences->get('delay');

	my $command="[cPump]";
	if ($directory){
		$command = $command." ".qq(-d  "$directory");
	}
	if ($prefix){
		$command = $command." ".qq(-p  "$prefix");
	}
	if ($suffix){
		$command = $command." ".qq(-f  "$suffix");
	}
	if ($logfile){
		$command = $command." ".qq(-l "$logfile");
	}
	if ($elementSize){
		$command = $command." ".qq(-s $elementSize);
	}
	if ($elementCount){
		$command = $command." ".qq(-c $elementCount);
	}
	if ($delay){
		$command = $command." ".qq(-c $delay);
	}

	my $capabilities = { 
		I => 'noArgs',
		F => 'noArgs', 
		R => 'noArgs'};
	
	my $profile = _buildProfile($macaddress, $codec);
	_enableProfile($profile);
	
	$Slim::Player::TranscodingHelper::commandTable{ $profile } = $command;
	$Slim::Player::TranscodingHelper::capabilities{ $profile } = $capabilities;
	
}
1;
