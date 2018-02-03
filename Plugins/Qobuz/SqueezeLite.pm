package Plugins::Qobuz::SqueezeLite;

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
	This file override the default Slim::Player::SqueezeBox::play and
    package Slim::Player::Player::rebuffer.
    
    Used when the player is Squeezelite.
    
=cut

use base qw(Slim::Player::SqueezePlay);
use Slim::Utils::Prefs
use Slim::Utils::Log;

my $prefs = preferences('server');
my $log = logger('player.source');

sub new {
	my $class = shift;

	my $client = $class->SUPER::new(@_);
	
	$client->init_accessor(
		_model                  => 'squeezelite',
		modelName               => 'Squeezelite',
		
	);

	return $client;
}

# lower limit of the input buffer as per Player::buffering.
sub _getRebufferingBufferThreshold{
    my $song = shift;
    
    my $threshold = 80 * 1024; # 5 seconds of 128k

    if ( my $bitrate = $song->streambitrate() ) {
        $threshold = 5 * ( int($bitrate / 8) );
	} #ca 500 per flac, 200 * mp3 320.
    
    # We could calculate a more-accurate outputThreshold, but it really is not worth it
    if ($threshold > $client->bufferSize() - 4000) {
		$threshold = $client->bufferSize() - 4000;	# cheating , really for SliMP3s
	} # this will raise to too hight $threshold if buffer size is huge.
    
    #mc2 #my $threshold = 4 * 1024 * 1024; # same value as in Squeezebox play
    return $threshold;
}
# lower limit of the input buffer as per SqueezeBox::play.
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

        $bufferThreshold = ( int($bitrate / 8) * $bufferSecs ) / 1024;

        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - bitrate", $bitrate);
        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - buffer threshold calculated on bitrate ", $bufferThreshold);

        # Max threshold is 255
        $bufferThreshold = 255 if $bufferThreshold > 255;

        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - resulting buffer Threshold", $bufferThreshold);
    }

    return $bufferThreshold;
}
# lower limit of the (Input) )buffer.
sub _getBufferLowerThreshold{
    my $song = shift;
    my $handler = shift;
    my $url = shift;

    my $bufferThreshold = $prefs->get('bufferThreshold') || 255;
      
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play pref bufferSecs", $bufferSecs);
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play buffer Threshold", $bufferThreshold);
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play handler", $handler);
    Data::Dump::dump("QOBUZ-SQUEEZEPLAY - play handler canThreshold", $handler->can('bufferThreshold'));

    # Set threshold if protocol handler wants to.
    if ( $handler->can('bufferThreshold') ) {
        $bufferThreshold = $handler->bufferThreshold( $client, $url );

        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - handler buffer Threshold", $bufferThreshold);

    # If we know the bitrate of the stream, we instead buffer a certain number of seconds of audio
    } elsif ( my $bitrate = $song()->streambitrate() ) {
        
        my $bufferSecs = $prefs->get('bufferSecs') || 3;
        
        #limit LowerThreshold at no more than 5 seconds.
        if ($bufferSecs > 5){$bufferSecs =5;}
        
        $bufferThreshold = ( int($bitrate / 8) * $bufferSecs ) / 1024;

        Data::Dump::dump("QOBUZ-SQUEEZEPLAY - resulting from bitrate buffer Threshold", $bufferThreshold);
    }

    return $bufferThreshold;
}
# upper limit of the output buffer.
sub _getBufferUpperThreshold{
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
        
        $params->{bufferThreshold} = _getBufferLowerThreshold($song, $handler, $url);
        
        my $bufferSecs = $prefs->get('bufferSecs') || 3;
        my $outputThreshold = _getBufferUpperThreshold($client, $bufferSecs);
      
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
	
    my $threshold = _getBufferLowerThreshold($song);
    # limit buffer Upper Threshold whwn rebuffering, in order to restart asap.
    # To me this is a mistake in player::_buffering, that is keep buffering until 
    # that limit instead of the lower limit. This value is  used here as a "lower Threshold" 
    # for output buffer, but in all the rest of te system is the upper buffer Threshold, not
    # the same meaning at all.
    
    # To me we have:
    
    # Buffer size = client->('buffersize');
    # Lower threshold = $threshold.
    # Upper threshold = $outputThreshold;
    
    # When $threshold is reached in the (input) buffer, then decode (if any) is started) and all data moved to the out buffer,
    # we actually have no lower threshold in the output buffer, playback starts as soon as we have any data there
 
    my $outputThreshold = _getBufferUpperThreshold($client, $threshold);

	Data::Dump::dump("PLAYER - rebuffer: ", $client->bufferSize(), $client->bufferFullness(), $threshold, $client->outputBufferFullness(), $outputThreshold);

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