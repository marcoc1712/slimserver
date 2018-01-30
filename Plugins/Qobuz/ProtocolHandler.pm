package Plugins::Qobuz::ProtocolHandler;

# Handler for qobuz:// URLs

use strict;
use base qw(Slim::Player::Protocols::HTTP);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use List::Util qw(min max first);
use Slim::Utils::Errno;

use constant MIN_OUT => 256*1024;    # delay before playback starts.
use constant MAX_OUT => 4*1024*1024; # safety limit, the out should always be empty.
use constant DATA_CHUNK => 1024*1024; #size of range in the http get request.

use Plugins::Qobuz::API;

my $log   = logger('plugin.qobuz');
my $prefs = preferences('plugin.qobuz');

sub new {
	my $class  = shift;
	my $args   = shift;
    
    my $song      = $args->{'song'};
    
	my $client    = $args->{client};
	my $streamUrl = $song->streamUrl() || return;

	main::DEBUGLOG && $log->is_debug && $log->debug( 'Remote streaming Qobuz track: ' . $streamUrl );
    
	my $mime = $song->pluginData('mime');

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
#		bitrate => $mime =~ /flac/i ? 750_000 : 320_000,
	} ) || return;
    
	${*$sock}{contentType} = $mime;
   
    if (defined($sock)) {
		${*$sock}{'vars'} = {                   # variables which hold state for this instance:
			'inBuf'       => '',                # buffer of received data
			'outBuf'      => '',                # buffer of processed audio
			'offset'      => 0,                 # offset for next HTTP request
			'streaming'   => 1,                 # flag for streaming, changes to 0 when all data received
			'fetching'    => 0,                 # waiting for HTTP data
		};
	}
    
    return $sock;
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}

sub sysread {
	my $self = $_[0];
    #my $chunk = $_[1];
	my $chunkSize = $_[2];

	my $metaInterval = ${*$self}{'metaInterval'};
	my $metaPointer  = ${*$self}{'metaPointer'};
    
    #Data::Dump::dump("Plugins::Qobuz::ProtocolHandler - sysread: ", $metaInterval, $metaPointer, $chunkSize);
    
	if ($metaInterval && ($metaPointer + $chunkSize) > $metaInterval) {

		$chunkSize = $metaInterval - $metaPointer;

		# This is very verbose...
		#$log->debug("Reduced chunksize to $chunkSize for metadata");
        Data::Dump::dump("Reduced chunksize for metadata", $chunkSize);
        
        my $readLength = CORE::sysread($self, $_[1], $chunkSize, length($_[1] || '' ))

    } 
    
    #Data::Dump::dump("sysread: ", $_[1], $chunkSize, length($_[1]));
	#my $readLength = CORE::sysread($self, $_[1], $chunkSize, length($_[1] || '' ));
    
    my $readLength = _sysread($self, $_[1], $chunkSize);
   
	if ($metaInterval && $readLength) {

		$metaPointer += $readLength;
		${*$self}{'metaPointer'} = $metaPointer;

		# handle instream metadata for shoutcast/icecast
		if ($metaPointer == $metaInterval) {

			$self->readMetaData();

			${*$self}{'metaPointer'} = 0;

		} elsif ($metaPointer > $metaInterval) {

			main::DEBUGLOG && $log->debug("The shoutcast metadata overshot the interval.");
		}	
	}

	return $readLength;
}

sub _sysread(){
    use bytes;
    
    my $self = $_[0];
    #my $chunk  = $_[1];
	#my $chunkSize = $_[2];
    
    my $v = $self->vars;
    my $url = ${*$self}{'url'};

    # need more data
	if ( length $v->{'outBuf'} < MAX_OUT && !$v->{'fetching'} && $v->{'streaming'} ) {
		my $range = "bytes=$v->{offset}-" . ($v->{offset} + DATA_CHUNK - 1);
		
		$v->{offset} += DATA_CHUNK;
		$v->{'fetching'} = 1;
        
        Data::Dump::dump("* Going to fetch:  ", $url, $range, length($v->{'inBuf'} || ''), $v->{'fetching'},$v->{'streaming'});
						
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} .= $_[0]->content;
				$v->{'fetching'} = 0;
				$v->{'streaming'} = 0 if length($_[0]->content) < DATA_CHUNK;
				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: ", length $_[0]->content, " from ", $v->{offset} - DATA_CHUNK, " for $url");
                Data::Dump::dump("* Got chunk length: ", length $_[0]->content, $v->{offset} - DATA_CHUNK, length $v->{'inBuf'});
            },
			
			sub { 
				$log->warn("error fetching $url");
				$v->{'inBuf'} = '';
				$v->{'fetching'} = 0;
                Data::Dump::dump("error fetching $url");
			}, 
			
		)->get($url, 'Range' => $range );
		
	}	
    if (length $v->{'inBuf'} >= MIN_OUT || !$v->{'streaming'}){
        
        Data::Dump::dump("Going to feed OUT BUF:  ", length $v->{'inBuf'}, MIN_OUT);
        
        $v->{'outBuf'} = $v->{'outBuf'}.$v->{'inBuf'};
        $v->{'inBuf'}='';
    }
    
    my $bytes = min(length $v->{'outBuf'}, MIN_OUT);

    if ($bytes) {
        Data::Dump::dump("Going to return OUT BUF:  ",$bytes, length $v->{'outBuf'}, MIN_OUT);
		$_[1] = $_[1].substr($v->{'outBuf'}, 0, $bytes);
		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);
		return $bytes;
	} elsif ( $v->{streaming} ) {
		$! = EINTR;
		return undef;
	} else {
        Data::Dump::dump("EOF");
        return 0; #EOF.
    }
    
}

sub canSeek { 0 }
sub getSeekDataByPosition { undef }
sub getSeekData { undef }

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getFormatForURL {
	my ($class, $url) = @_;
	
	my ($id, $type) = $class->crackUrl($url);
	
	if ($type =~ /^(flac|mp3)$/) {
		$type =~ s/flac/flc/;
		return $type;
	}

	my $info = Plugins::Qobuz::API->getCachedFileInfo($id || $url);
	
	return $info->{mime_type} =~ /flac/ ? 'flc' : 'mp3' if $info && $info->{mime_type};
	
	# fall back to whatever the user can play
	return Plugins::Qobuz::API->getStreamingFormat();
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;
	
	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	return $class->SUPER::canDirectStream( $client, $song->streamUrl() );
}

# parseHeaders is used for proxied streaming
sub parseHeaders {
	my ( $self, @headers ) = @_;
	
	__PACKAGE__->parseDirectHeaders( $self->client, $self->url, @headers );
	
	return $self->SUPER::parseHeaders( @headers );
}

sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;
	
	# May get a track object
	if ( blessed($url) ) {
		$url = $url->url;
	}
	
	my $bitrate     = 750_000;
	my $contentType = 'flc';
	
	my $length;

	foreach my $header (@headers) {
		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
		}
		elsif ( $header =~ /^Content-Type:.*(?:mp3|mpeg)/i ) {
			$bitrate = 320_000;
			$contentType = 'mp3';
		}
	}

	my $song = $client->streamingSong();
	
	# try to calculate exact bitrate so we can display correct progress
	my $meta = $class->getMetadataFor($client, $url);
	my $duration = $meta->{duration};
	
	# sometimes we only get a 60s/mp3 sample
	if ($meta->{streamable} && $meta->{streamable} eq 'sample' && $contentType eq 'mp3') {
		$duration = 60;
	}
	
	$song->duration($duration);
	
	if ($length && $contentType eq 'flc') {
		$bitrate = $length*8 / $duration if $meta->{duration};
		$song->bitrate($bitrate) if $bitrate;
	}
	
	if ($client) {
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
	}

	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $class->crackUrl($url);
	$id ||= $url; 

	my $meta;
	
	# grab metadata from backend if needed, otherwise use cached values
	if ($id && $client->master->pluginData('fetchingMeta')) {
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] ) if $client;
		$meta = Plugins::Qobuz::API->getCachedFileInfo($id);
	}
	elsif ($id) {
		$client->master->pluginData( fetchingMeta => 1 );

		$meta = Plugins::Qobuz::API->getTrackInfo(sub {
			$client->master->pluginData( fetchingMeta => 0 );
		}, $id);
	}
	
	$meta ||= {};
	if ($meta->{mime_type} && $meta->{mime_type} =~ /(fla?c|mp)/) {
		$meta->{type} = $meta->{mime_type} =~ /fla?c/ ? 'flc' : 'mp3';
	}
	$meta->{type} ||= $class->getFormatForURL($url);
	$meta->{bitrate} = $meta->{type} eq 'mp3' ? 320_000 : 750_000;
	
	if ($meta->{type} ne 'mp3' && $client && $client->playingSong && $client->playingSong->track->url eq $url) {
		$meta->{bitrate} = $client->playingSong->bitrate if $client->playingSong->bitrate;
	}
	
	$meta->{bitrate} = sprintf("%.0f" . Slim::Utils::Strings::string('KBPS'), $meta->{bitrate}/1000);
	
	return $meta;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $url = $song->currentTrack()->url;
	
	# Get next track
	my ($id, $format) = $class->crackUrl($url);
	
	Plugins::Qobuz::API->getFileInfo(sub {
		my $streamData = shift;
        #Data::Dump::dump("PROTOCOL HANDLER - getNextTrack getFileInfo CALLBACK", " streamData ",$streamData);
		
        if ($streamData) {
			$song->pluginData(mime => $streamData->{mime_type});
			Plugins::Qobuz::API->getFileUrl(sub {
                my $url = shift;
                
                #Data::Dump::dump("PROTOCOL HANDLER - getNextTrack getFileUrl CALLBACK", "url ".$url);
                #Data::Dump::dump("PROTOCOL HANDLER - getNextTrack SUCCESSS CALLBACK",  $successCb);
                
				$song->streamUrl($url);
				$successCb->();
			}, $id, $format);
			return;
		}
		#Data::Dump::dump("PROTOCOL streamUrlHANDLER - getNextTrack ERROR CALLBACK",  $successCb);
		$errorCb->('Failed to get next track', 'Qobuz');
	}, $id, $format);
}

sub getUrl {
	my ($class, $id) = @_;
	
	return '' unless $id;
	
	my $ext = Plugins::Qobuz::API->getStreamingFormat($id);

	$id = $id->{id} if $id && ref $id eq 'HASH';
	
	return 'qobuz://' . $id . '.' . $ext;
}

sub crackUrl {
	my ($class, $url) = @_;
	
	return unless $url;
	
	my ($id, $format) = $url =~ m{^qobuz://(.+?)\.(mp3|flac)$};
	
	# compatibility with old urls without extension
	($id) = $url =~ m{^qobuz://([^\.]+)$} unless $id;
	
	return ($id, $format || Plugins::Qobuz::API->getStreamingFormat());
}

sub audioScrobblerSource {
	# Scrobble as 'chosen by user' content
	return 'P';
}

1;