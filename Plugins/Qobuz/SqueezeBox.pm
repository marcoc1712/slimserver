package Plugins::Qobuz::SqueezeBox;

# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

=comment
	This file is overriding the default Slim::Player::SqueezeBox::play 
=cut

use base qw(Slim::Player::SqueezeBox);
use Slim::Utils::Prefs
use Slim::Utils::Log;

my $prefs = preferences('server');
my $log = logger('player.source');

sub qobuzSqueezeboxOverload { 1 }

sub _getRebufferingBufferThreshold{
    my $song = shift;
    
    my $threshold = 80 * 1024; # 5 seconds of 128k

    if ( my $bitrate = $song->streambitrate() ) {
        $threshold = 5 * ( int($bitrate / 8) );
	}
    
    # We could calculate a more-accurate outputThreshold, but it really is not worth it
    if ($threshold > $client->bufferSize() - 4000) {
		$threshold = $client->bufferSize() - 4000;	# cheating , really for SliMP3s
	}
    
    #mc2 #my $threshold = 4 * 1024 * 1024; # same value as in Squeezebox play
    return $threshold;
}

sub _getPlayBufferThreshold{
    my $song = shift;
    my $handler = shift;
    my $url = shift;

    #begin playback once we have this much data in the decode buffer (in KB)
    my $bufferThreshold = 20;
    
    my $bufferSecs = $prefs->get('bufferSecs') || 3;
        
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play pref bufferSecs", $bufferSecs);
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play buffer Threshold", $bufferThreshold);
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play handler", $handler);
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play handler canThreshold", $handler->can('bufferThreshold'));

    my $bitrate = $song()->streambitrate();

    # Reduce threshold if protocol handler wants to
    if ( $handler->can('bufferThreshold') ) {
        $bufferThreshold = $handler->bufferThreshold( $client, $url );

        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - resulting buffer Threshold", $bufferThreshold);

    # If we know the bitrate of the stream, we instead buffer a certain number of seconds of audio
    } elsif ( $bitrate ) {

        $bufferThreshold = ( int($bitrate / 8) * $bufferSecs ) / 1000;

        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - bitrate", $bitrate);
        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - buffer threshold calculated on bitrate ", $bufferThreshold);

        # Max threshold is 255
        $bufferThreshold = 255 if $bufferThreshold > 255;

        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - resulting buffer Threshold", $bufferThreshold);
    }

    return $bufferThreshold;
}

sub _getOutputThreshold{
    my $client = shift;
    my $bufferSecs = shift || 5; 

    my $outputThreshold = $bufferSecs * 44100 * 2 * 4; # $bufferSecs seconds 44100 Hz, 2 channels, 32bits/sample.
    
    if ($client->bufferSize() && $outputThreshold > $client->bufferSize()){
        
        $outputThreshold = $client->bufferSize(); 
    }

    return $outputThreshold;
}

sub play {
	my $client = shift;
	my $params = shift;
	
	my $controller = $params->{'controller'};
    my $song = $controller->song();
	my $handler = $controller->songProtocolHandler();
    my $url = $params->{url};
    
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play");
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - is remote?", $handler->isRemote());
    
	# Calculate the correct buffer threshold for remote URLs
	if ( $handler->isRemote() ) {
        
        $params->{bufferThreshold} = _getPlayBufferThreshold($song, $handler, $url);
        
        my $bufferSecs = $prefs->get('bufferSecs') || 3;
        my $outputThreshold = _getOutputThreshold($bufferSecs);
        
        # tested line, use all the buffer and wait as long as necessary before start playback.
        # $bufferSecs =4 * 1024 * 1024
        # $outputThreshold = $client->bufferSize());
        
        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - client buffering:", $params->{bufferThreshold} * 1024, $outputThreshold);

        $client->buffering($params->{bufferThreshold} * 1024, $outputThreshold);
        
	}
    
    #Data::Dump::dump("SQUEEZEBOX - play,  client ISA:",  ref $client);
    # Squeezeplay
    
	$client->bufferReady(0);
	
	my $ret = $client->stream_s($params);

	# make sure volume is set, without changing temp setting
	$client->volume($client->volume(), defined($client->tempVolume()));

	return $ret;
}
sub rebuffer {
	my ($client) = @_;

	my $song = $client->playingSong() || return;
	my $url = $song->currentTrack()->url;

	my $handler = $song->currentTrackHandler();
	my $remoteMeta = $handler->can('getMetadataFor') ? $handler->getMetadataFor($client, $url) : {};
	my $title = Slim::Music::Info::getCurrentTitle($client, $url, 0, $remoteMeta) || Slim::Music::Info::title($url);
	my $cover = $remoteMeta->{cover} || $remoteMeta->{icon} || '/music/' . $song->currentTrack()->coverid . '/cover.jpg';
	
    my $threshold = _getRebufferingBufferThreshold($song);
    my $outputThreshold = _getOutputThreshold($client, 5); # 5 secs instead of pref->('secbuffer'), that is normally = 3.

	# We restart playback based on the decode buffer, 
	# as the output buffer is not updated in pause mode.
	my $fullness = $client->bufferFullness();
    
	Data::Dump::dump("PLAYER - rebuffer: ", $client->bufferSize(), $fullness, $threshold, $client->outputBufferFullness(), $outputThreshold);

	main::INFOLOG && $log->info( "Rebuffering: $fullness / $threshold" );
	
    $client->bufferReady(0);

    $client->bufferStarted( Time::HiRes::time() ); # track when we started rebuffering
    Slim::Utils::Timers::killTimers( $client, \&_buffering );
    Slim::Utils::Timers::setTimer(
        $client,
        Time::HiRes::time() + 0.125,
        \&_buffering,
        {song => $song, threshold => $threshold, outputThreshold => $outputThreshold, title => $title, cover => $cover}
    );
}