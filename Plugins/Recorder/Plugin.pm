#!/usr/bin/perl
# $Id$
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

use Time::Local;
use File::Spec;
use File::Path;
use File::Basename;
use File::Copy;
use POSIX qw(strftime);

use Data::Dump qw(dump pp);

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Recorder::Metadata;

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
    
    # Subscribe to new song event
	Slim::Control::Request::subscribe(
		\&newSong, 
		[['playlist'], ['newsong']],
	);
    # Subscribe to stop event
	Slim::Control::Request::subscribe(
		\&stop, 
		[['playlist'], ['stop']],
	);
}
sub shutdownPlugin {
	Slim::Control::Request::unsubscribe( \&newClientCallback );
	Slim::Control::Request::unsubscribe( \&clientReconnectCallback );
    Slim::Control::Request::unsubscribe( \&newSong );
    Slim::Control::Request::unsubscribe( \&stop );
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

sub newSong{
    my $request = shift;
    my $client  = $request->client() || return 0;

    if ($preferences->get('mac') && ($preferences->get('mac') eq  $client->macaddress())) {
        
        my $id = $request->clientid();
        main::INFOLOG && $log->info("newSong request received from client ".$id);
        
        my $metadata = Plugins::Recorder::Metadata->new($client);
        my $current = $metadata->getFile();
        
        if (main::DEBUGLOG && $log->is_debug) {
            
            my $player      = $metadata->getPlayer(); 
            my $timeString  = $metadata->getTime(); 
            my $title       = $metadata->getTitle();  
            my $artist      = $metadata->getArtist();  
            my $album       = $metadata->getAlbum();  
            my $track       = $metadata->getTrackNo();  
            my $year        = $metadata->getYear() ? $metadata->getYear() : '';  
        
            $log->debug("player: $player\n");
            $log->debug("time:   $timeString\n");
            $log->debug("track:  $track\n");
            $log->debug("title:  $title\n");
            $log->debug("album:  $album\n");
            $log->debug("artist: $artist\n");
            $log->debug("year:   $year\n");
    }
        
        my $base = $preferences->get('directory');
        my $dir  = _createDirectory($base, $metadata->getArtist(),$metadata->getAlbum());
        
        if ($dir && main::DEBUGLOG && $log->is_debug) {
                 
                 $log->debug("created $dir");
        }
        
        # move previous files to album directory.
        $dir       = $preferences->get('directory');
        my $prefix = $preferences->get('prefix');
        my $suffix = $preferences->get('suffix');
        
        _match($client, $dir, $prefix, $suffix, $current);
    }
    return 1;
}
sub stop{
    my $request = shift;
    my $client  = $request->client() || return 0;
    
    if ($preferences->get('mac') && ($preferences->get('mac') eq  $client->macaddress())) {
        
        my $id = $request->clientid();
        main::INFOLOG && $log->info("stop request received from client ".$id);
       
       # move last file to directory.
        my $dir    = $preferences->get('directory');
        my $prefix = $preferences->get('prefix');
        my $suffix = $preferences->get('suffix');
        
       _match($client, $dir, $prefix,$suffix, undef);
    }
    return 1;
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
#
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
sub _createDirectory{
    my $base = shift;
    my $artist = shift;
    my $album = shift;

    if (!$base) {
        $log->error("missing directory");
        return 0;
    }
    
    if (! -d $base){
        $log->error("$base is not a directory");
        return 0; 
    }
    if (!$artist){
        $log->error("missing artist");
        return 0
    }
    if (!$album){
        $log->error("missing $album");
        return 0
    }
    my ($ar, $al);
    
    $ar = _filterFileName($artist);
    $al = _filterFileName($album);
    
    my $path = File::Spec->catdir( $base, $ar, $al );  
    
    File::Path::make_path( $path, {error => \my $err} );
    
    if (@$err) {
        for my $diag (@$err) {
          my ($file, $message) = %$diag;
          if ($file eq '') {
               $log->error ("general error: $message");
          } else {
              $log->error ("problem cretaing $file: $message")
          }
      }
      return 0;
    }
    return $path;
}

sub _match{
    my $client      = shift;
    my $dir         = shift;
    my $prefix      = shift;
    my $suffix      = shift;
    my $current_dat = shift;
    
    
    my @files_dat = glob( $dir . '*.dat');
    my @files = glob( $dir . '*'.$suffix);

    my $prefixLen= length($prefix);
    my $found=0;

    foreach my $dat (sort @files_dat) {

        $dat = File::Spec->canonpath( $dat );
        if ($current_dat && $current_dat eq $dat) {next}
        
        my $datName = File::Basename::basename($dat);
        my $dat_str = substr($datName,$prefixLen,15);
        my $dat_time= _getTime($dat_str);

        foreach my $file (sort @files) {

            my $name = File::Basename::basename($file);
            my $str = substr($name,$prefixLen,15);
            my $time= _getTime($str);

            if ($time le $dat_time){
                $found = $file;

            } else {last;}
        }
        if ($found) {

            _move($client, $found, $dat, $suffix);
        }
    }
}
sub _move{
    my $client  = shift;
    my $old     = shift;
    my $dat     = shift;
    my $suffix  = shift;
    
    my $oldName = File::Basename::basename($old);
    my $base    = File::Basename::dirname($old);
    
    my $metadata = Plugins::Recorder::Metadata->new($client, $dat);
   
    if (main::DEBUGLOG && $log->is_debug) {
            
            my $player      = $metadata->getPlayer(); 
            my $timeString  = $metadata->getTime(); 
            my $title       = $metadata->getTitle();  
            my $artist      = $metadata->getArtist();  
            my $album       = $metadata->getAlbum();  
            my $track       = $metadata->getTrackNo();  
            my $year        = $metadata->getYear() ? $metadata->getYear() : '';  
        
            $log->debug("player: $player\n");
            $log->debug("time:   $timeString\n");
            $log->debug("track:  $track\n");
            $log->debug("title:  $title\n");
            $log->debug("album:  $album\n");
            $log->debug("artist: $artist\n");
            $log->debug("year:   $year\n");
    }
   
    if (!$metadata->getAlbum() || !$metadata->getArtist()|| !$metadata->getTitle() || !$metadata->getTrackNo()){
    
        $log->warn ("invalid metadata");
        return 0;
    }
    
    my $artist = _filterFileName($metadata->getArtist());
    my $album = _filterFileName($metadata->getAlbum());
    my $dir = File::Spec->catdir( $base, $artist, $album );
       
    if (! -d $dir) {
    
        $log->warn ("invalid directory: $dir");
        return 0;
    }
    
    my $title = _filterFileName($metadata->getTitle());
    
    my $track;
    if (length($metadata->getTrackNo())== 1 ){$track = '000'.$metadata->getTrackNo();}
    elsif (length($metadata->getTrackNo())== 2 ){$track = '00'.$metadata->getTrackNo();}
    elsif (length($metadata->getTrackNo())== 2 ){$track = '0'.$metadata->getTrackNo();}
    
    my $filename = $track."-".$title.$suffix;
    
    if (length($filename)+ length($dir)>255) {$filename = $track.$oldName.$suffix;}
    if (length($filename)+ length($dir)>255) {$filename = $track.$suffix;}
    if (length($filename)+ length($dir)>255) {
    
    $log->warn ("resulting pathname too long");
        return 0;
    }

    if (_moveFile($old, $dir, $filename)){
    
        my $datName = File::Basename::basename($dat);
        
        _moveFile($dat, $dir, $datName);
        return 1;
    }
    return 0;
}
sub _moveFile{
    my $old = shift;
    my $dir = shift;
    my $filename = shift;
    
    my $new = File::Spec->catfile($dir, $filename);
    
    if (!-e $old){
        $log->warn ( "file $old does not exists, can't rename");
        return 0; 
    }

    if (-e $new){
        $log->warn ( "file $new already exists, can't rename");
        return 0; 
    }
    if (!-w $dir){
        $log->warn ( "can't write to $dir, can't rename");
        return 0; 
    }

    my $ret= move ($old, $new);
    if (!$ret && $!){

        $log->warn($!);

    }
    return $ret;
}

sub _filterFileName{
    my $in = shift;

    my $out;
    ($out = $in)=~ s/[^A-Za-z0-9-_\s]/_/g;
    
    return $out;
}
sub _getTime {
    my $str = shift;
    #my $str = '20070717_132101';
    
    if (! $str) {return 0;}
    
    my @t   = $str =~ m!(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})!;
    $t[1]--;
    my $time = timelocal @t[5,4,3,2,1,0];
    # verify...
    #print scalar localtime $timestamp."\n";
    
    return $time;
    
}
1;
