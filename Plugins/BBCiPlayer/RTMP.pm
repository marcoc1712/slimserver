package Plugins::BBCiPlayer::RTMP;

# This protocol hander implements the Adobe RTMP protocol as specified by:
#  http://www.adobe.com/devnet/rtmp/pdf/rtmp_specification_1.0.pdf
#
# Note that the licence terms of this specification are restricted to streaming
# and prevents storage of content.  Streaming to http clients is therefore disabled.
#
# This version of the protocol handler supports streaming of AAC RTMP stream as used
# by the BBC.
#
# (c) Triode, 2007-2015, triode1@btinternet.com
#
# Released under GPLv2
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

use strict;

use base qw(Slim::Formats::RemoteStream);

use MIME::Base64;
use Time::HiRes;
use List::Util qw(min max);
use Scalar::Util qw(looks_like_number blessed);
use IO::Socket qw(pack_sockaddr_in inet_aton);

use Slim::Utils::Errno;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use bytes;

my $log   = logger('plugin.bbciplayer.rtmp');
my $prefs = preferences('plugin.bbciplayer');

Slim::Player::ProtocolHandlers->registerHandler('rtmp', __PACKAGE__);

my $flashVer = "LNX 10,0,22,87";

my $liveStartTS = 4500; # timestamp at which to start playing live stream (flash server can burst on 4 sec boundaries)

sub packUrl {
	my $class = shift;
	my $params = shift;

	my $host = $params->{'host'};
	my $port = $params->{'port'};
	my $ct   = delete $params->{'ct'} || 'mp3';

	my $url = "rtmp://$host:$port?";

	for my $key (keys %$params) {
		next if $key =~ /host|port/;
		if (defined $params->{$key}) {
			$url .= "$key=" . encode_base64(Slim::Utils::Unicode::utf8encode($params->{$key}), '') . '&';
		}
	}
	
	$url .= ".$ct"; # used for server content type handling

	return $url;
}

sub unpackUrl {
	my $class = shift;
	my $url   = shift;

	my ($host, $port, $params, $ct) = $url =~ /rtmp:\/\/(.+):(.+)\?(.*)\.(.*)/;

	my $res = {
		host => $host,
		port => $port,
	};
	
	for my $param (split /&/, $params) {
		my ($key, $val) = $param =~ /(.*?)=(.*)/;
		$res->{$key} = Slim::Utils::Unicode::utf8decode(decode_base64($val));
	}

	$res->{'ct'} = $ct;

	return $res;
}

sub new {
	my $class = shift;
	my $args = shift;

	if ($args->{'client'} && $args->{'client'}->isa('Slim::Player::HTTP')) {
		$log->error("unable to stream RTMP to HTTP client");
		return undef;
	}

	my $song       = $args->{'song'};
	my $url        = ($song->can('streamUrl') ? $song->streamUrl : $song->{'streamUrl'}) || $args->{'url'};

	my $transcoder = $args->{'transcoder'};
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};

	my $params = $class->unpackUrl($url);

	if (!$params->{'live'} && (my $newtime = $seekdata->{'timeOffset'})) {

		$params->{'start'} = $newtime;

		if($song->can('startOffset')) {
			$song->startOffset($newtime);
		} else {
			$song->{startOffset} = $newtime;
		}
		
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	$log->info(sub { Data::Dump::dump($params) });

	my $self;
	my $timeout = preferences('server')->get('remotestreamtimeout');
	my $tries = 3;

	while (!$self && --$tries) {

		$log->info("connecting to $params->{host}:$params->{port}");

		# Following is taken from S:F:RemoteStream, we must do ourselves to avoid using any webproxy
		$self = $class->SUPER::new(
			LocalAddr => $main::localStreamAddr,
			Timeout	  => $timeout,
		);

		if (!$self) {
			$log->error("Couldn't create socket binding to $main::localStreamAddr - $!");
			next;
		};

		${*$self}{'_sel'} = IO::Select->new($self);

		my $error;

		Slim::Utils::Network::blocking($self, 0)   || do { $error = "Couldn't set non-blocking on socket!" };

		my $in_addr = inet_aton($params->{'host'}) || do { $error = "Couldn't resolve IP address for: $params->{host}" };

		$self->connect(pack_sockaddr_in($params->{'port'}, $in_addr)) || do {

			my $errnum = 0 + $!;
			
			if ($errnum != EWOULDBLOCK && $errnum != EINPROGRESS && $errnum != EINTR) {
				
				$error = "Can't open socket to [$params->{host}:$params->{port}]: $errnum: $!";
				
			} else {
				
				() = ${*$self}{'_sel'}->can_write($timeout) || do { 
					
					$error = "Timeout on connect to [$params->{host}:$params->{port}]: $errnum: $!";
				}
			};

		} unless $error;

		if ($error) {

			$log->error($error);

			close $self;
			undef $self;
		}
	}

	if (!$self) {

		$log->warn("failed to connect to $params->{host}:$params->{port}");

		return undef;

	} else {

		$log->info("connected to: " . $self->peerhost . ":" . $self->peerport);
	}

	${*$self}{'song'}    = $args->{'song'};
	${*$self}{'client'}  = $args->{'client'};
	${*$self}{'url'}     = $args->{'url'};

	${*$self}{'params'} = $params;# params which are fixed for this instance
	${*$self}{'vars'}   = {       # variables which hold state for this instance:
		'inBuf'         => '',    #  buffer of received rtmp packets/partial packets
		'outBuf'        => '',    #  buffer of processed audio
		'inCache'       => [],    #  cache of received packets by chunk channel
		'sendChunkSize' => 128,   #  fragmentation size for sending (does not change)
		'recvChunkSize' => 128,   #  fragmentation size for recieving (server likely to change)
		'receivedBytes' => 0,     #  total bytes received
		'ackWindow'     => 20480, #  ack window size
		'nextAck'       => 20480, #  when next ack is due
		'streamingId'   => undef, #  id of the streaming session (only non 0 streamId)
		'ourToken'      => undef, #  random token sent during handshake
		'ts_epoch'      => 0,     #  epoch for timestamps for this session
		'ts_prev'       => undef, #  previous timestamp (for bitrate measurement)
	};

	${*$self}{'contentType'} = $transcoder->{'streamformat'};

	$self->openConnection;

	$song->pluginData('icon' => $params->{'icon'}) if $params->{'icon'};
	$song->pluginData('info' => $params->{'desc'}) if $params->{'desc'};

	$song->duration($params->{'duration'}) if $params->{'duration'};

	Slim::Music::Info::setBitrate($song->track->url, $params->{'br'} * 1000) if $params->{'br'};

	return $self;
}

sub isRemote { 1 }

sub isAudio { 1 }

sub canSeek {
	my ($class, $client, $song) = @_;

	return $song->duration ? 1 : 0;
}

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	
	return { timeOffset => $newtime };
}

sub contentType {
	my $self = shift;

	return ${*$self}{'contentType'};
}

sub getIcon {
	my ($class, $url) = @_;

	my $handler;

	if ( ($handler = Slim::Player::ProtocolHandlers->iconHandlerForURL($url)) && ref $handler eq 'CODE' ) {
		return &{$handler};
	}
	
	return Plugins::BBCiPlayer::Plugin->_pluginDataFor('icon');
}

sub getMetadataFor {
	my $class  = shift;
	my $client = shift;
	my $url    = shift;

	if (my $song = $client->currentSongForUrl($url)) {

		if ($song->pluginData('info')) {
			return {
				artist => $song->pluginData('info'),
				cover  => $song->pluginData('icon'),
				icon   => $song->pluginData('icon'),
			};
		} else {
			return {
				title  => $song->pluginData('track'),
				artist => $song->pluginData('artist'),
				cover  => $song->pluginData('icon'),
				icon   => $song->pluginData('icon'),
			};
		}

	}

	# non streaming url - see if we can extract metadata from the url
	my $p = $class->unpackUrl($url);

	return {
		artist => $p->{'desc'},
		cover  => $p->{'icon'},
		icon   => $p->{'icon'},
	};
}	

sub updateOnStream {
	my ($class, $song, $cb, $ecb) = @_;

	my $params = $class->unpackUrl($song->streamUrl);
	
	if ($params->{'update'} && $params->{'ttl'} && $params->{'ttl'} < time()) {

		$log->info("param ttl expired updating");

		$params->{'update'}->update($song, $params, $cb, $ecb);

	} else {

		$cb->();
	}
}

sub params {
	my $self = shift;
	return ${*$self}{'params'};
}
	
sub vars {
	my $self = shift;
	return ${*$self}{'vars'};
}

sub song {
	my $self = shift;
	return ${*$self}{'song'};
}

sub state {
	my $self = shift;

	return ${*$self}{'state'} unless @_;

	my $oldState = ${*$self}{'state'};
	my $newState = shift;

	$log->info("$oldState -> $newState") if $oldState;

	${*$self}{'state'} = $newState;
}

sub timestamp {
	my $classOrSelf = shift;

	my $now = Time::HiRes::time();

	my $epoch = blessed($classOrSelf) ? $classOrSelf->vars->{'ts_epoch'} ||= $now : $now;

	return int( ($now - $epoch) * 1000 );
}

sub formatRTMP {
	my $class = shift;
	my $rtmp = shift;

	return
		encode_u8 ($rtmp->{'chunkChan'} & 0x7f) .
		encode_u24($class->timestamp) .
		encode_u24(length($rtmp->{'body'}) & 0xffffff) . 
		encode_u8 ($rtmp->{'type'} & 0xff) . 
		encode_u32le($rtmp->{'streamId'} & 0xffffffff) .
		$rtmp->{'body'};
}

sub sendRTMPPacket {
	my $self = shift;
	my $rtmp = shift;

	# NB: We send all rtmp packets using header format 0, i.e. without any header compression

	$log->debug("sending rtmp: chunkChan: $rtmp->{chunkChan} type: $rtmp->{type} streamId: $rtmp->{streamId}");

	if ($log->is_debug && $rtmp->{'type'} == 20) {
		$log->debug(Data::Dump::dump(amfParse($rtmp->{'body'})));
	}

	my $bytes = 
		encode_u8 ($rtmp->{'chunkChan'} & 0x7f) .
		encode_u24($self->timestamp) .
		encode_u24(length($rtmp->{'body'}) & 0xffffff) . 
		encode_u8 ($rtmp->{'type'} & 0xff) . 
		encode_u32le($rtmp->{'streamId'} & 0xffffffff);

	my $sent = $self->syswrite($bytes);

	if ($sent != length($bytes)) {

		$log->error("couldn't send full packet");
		$self->close;
	}

	$bytes = $rtmp->{'body'};

	while (my $len = length($bytes)) {
		if ($len > $self->vars->{'sendChunkSize'}) {
			$len = $self->vars->{'sendChunkSize'};
		}
		my $chunk = substr($bytes, 0, $len);
		$bytes    = substr($bytes, $len);

		my $sent = $self->syswrite($chunk);

		if ($sent != length($chunk)) {

			$log->error("couldn't send full packet");
			$self->close;
		}

		if (length($bytes)) {
			$self->syswrite( encode_u8( ($rtmp->{'chunkChan'} & 0x7f) | 0xc0 ) );
		}
	}
}

sub connectPacket {
	my $class = shift;
	my $app   = shift;
	my $swfurl= shift;
	my $tcurl = shift;
		
	return {
		chunkChan => 0x03,
		type      => 20,
		streamId  => 0,
		body      => 
			amfFormatString('connect') . 
			amfFormatNumber(1) .
			amfFormatObject({
				app         => $app,
				swfUrl      => $swfurl,
				tcUrl       => $tcurl,
				audioCodecs => 0x0404, # AAC and MP3 only
				videoCodecs => 0x0000, # no video
				flashVer    => $flashVer,
			}),
	};
}

sub createStreamPacket {
	my $class = shift;

	return {
		chunkChan => 0x03,
		type      => 20,
		streamId  => 0,
		body      => 
			amfFormatString('createStream') .
			amfFormatNumber(2) .
			amfFormatNull(),
	};
}

sub subscribePacket {
	my $class = shift;
	my $subscribe = shift;

	return {
		chunkChan => 0x03,
		type      => 20,
		streamId  => 0,
		body      =>
			amfFormatString('FCSubscribe') .
			amfFormatNumber(0) .
			amfFormatNull() .
			amfFormatString($subscribe),
	};
}

sub playPacket {
	my $class = shift;
	my $streamingId = shift;
	my $streamname = shift;
	my $live = shift;
	my $start = shift;

	return {
		chunkChan => 0x08,
		type      => 20,
		streamId  => $streamingId,
		body      =>
			amfFormatString('play') .
			amfFormatNumber(0) .
			amfFormatNull() .
			amfFormatString($streamname) .
			amfFormatNumber( $live ? -1000 : ($start || 0) * 1000 ),
	};
}

sub ackPacket {
	my $class = shift;
	my $ack = shift;

	return {
		chunkChan => 0x02,
		type      => 3,
		streamId  => 0,
		body      => encode_u32($ack),
	};
}

# this does not appear to change anything...
sub setBufferLengthPacket {
	my $class = shift;
	my $streamingId = shift;
	my $bufferSize = shift;

	return {
		chunkChan => 0x02,
		type      => 4,
		streamId  => 0,
		body      => 
			encode_u16(3) .
			encode_u32($streamingId) .
			encode_u32($bufferSize),
	};
}

sub openConnection {
	my $self = shift;

	# initate the handshake by sending the C0 and C1 packets

	# C0
	my $c0 = chr(0x03);

	# C1
	my $ourToken = '';
	for (my $i = 0; $i < 1528; $i++) {
		$ourToken .= chr( rand(255) );
	}

	my $c1 = encode_u32($self->timestamp). chr(0x00) x 4 . $ourToken;

	$self->vars->{'ourToken'} = $ourToken;

	$self->syswrite( $c0 . $c1 );

	$self->state('hsAwaitS0');

	Slim::Networking::Select::addRead($self, \&processRTMP);

	return $self;
}

sub close {
	my $self = shift;

	$log->info("close");

	Slim::Networking::Select::removeRead($self);

	$self->SUPER::close;
}

my $handshakeHandlers = {

	hsAwaitS0 => [ 1,
				 sub {
					 my $self = shift;
					 my $s0 = shift;

					 return ($s0 eq chr(0x03)) ? 'hsAwaitS1' : undef;
				 }, ],
	
	hsAwaitS1 => [ 1536,
				 sub {
					 my $self = shift;
					 my $s1 = shift;

					 my ($time1, $null) = unpack("NN", $s1);

					 my $c2 = pack("NN", $time1, $self->timestamp) . substr($s1, 8);

					 $self->send($c2);

					 return 'hsAwaitS2';
				 }, ],

	hsAwaitS2 => [ 1536,
				 sub {
					 my $self = shift;
					 my $s2 = shift;

					 my ($time1, $time2) = unpack("NN", $s2);

					 my $rand = substr($s2, 8);

					 if ($rand eq $self->vars->{'ourToken'}) {

						 my $p = $self->params;

						 $self->sendRTMPPacket( $self->connectPacket( $p->{'app'}, $p->{'swfurl'}, $p->{'tcurl'} ) );

						 return 'sentConnect';

					 } else {

						 return undef;
					 }
				 }, ],
};

my $rtmpHandlers = {

	'1' => sub {
		my $self = shift;
		my $rtmp = shift;

		my $chunk = $self->vars->{'recvChunkSize'} = decode_u32(substr($rtmp->{'body'}, 0, 4));

		$log->info("message type 1 - set recv chunk size to $chunk");
	},

	'2' => sub {
		my $self = shift;
		my $rtmp = shift;

		my $chan = decode_u32(substr($rtmp->{'body'}, 0, 4));

		$log->info("message type 2 - abort for chunk channel $chan");

		$self->vars->{'inCache'}->[$chan] = undef;
	},

	'3' => sub {
		my $self = shift;
		my $rtmp = shift;

		my $seq = decode_u32(substr($rtmp->{'body'}, 0, 4));

		$log->info("message type 3 - ack received $seq");
	},

	'4' => sub { 
		my $self = shift;
		my $rtmp  = shift;
		
		my $event = decode_u16(substr($rtmp->{'body'}, 0, 2));
		my $data  = substr($rtmp->{'body'}, 2, 0);
		
		if ($event == 0) {
			
			$log->info("message type 4 - user control message $event: Stream Begin");

		} elsif ($event == 1) {
			
			$log->info("message type 4 - user control message $event: EOF - exiting");

			$self->close;
			
		} elsif ($event == 2) {
			
			$log->info("message type 4 - user control message $event: StreamDry");
			
		} elsif ($event == 4) {
			
			$log->info("message type 4 - user control message $event: Stream Is Recorded");
			
		} elsif ($event == 6) {
			
			$log->info("message type 4 - user control message $event: Ping Request - sending response");
			
			$self->sendRTMPPacket({
				chunkChan => 0x02,
				type      => 4,
				streamId  => 0,
				body      => encode_u16(7) . $data,
			});
			
		} else {
			
			$log->debug("message type 4 - user control message $event: ignored");
		}

	 },

	 '5' => sub { 
		my $self = shift; 
		my $rtmp = shift;

		my $window = decode_u32(substr($rtmp->{'body'}, 0, 4));
		
		$log->info("message type 5 - window ack size: $window - ignore");
	 },

	 '6' => sub { 
		my $self = shift; 
		my $rtmp = shift;

		my $window = decode_u32(substr($rtmp->{'body'}, 0, 4));
		my $limit  = decode_u8 (substr($rtmp->{'body'}, 4, 1));
		
		$log->info("message type 6 - set peer BW: $window limit type $limit - sending response");
		
		$self->vars->{'ackWindow'} = $window / 2;
		
		# send back a window ack packet
		$self->sendRTMPPacket({
			chunkChan => 0x02,
			type      => 5,
			streamId  => 0,
			body      => encode_u32($window),
		});
	 },

	 '8' => sub {
		my $self = shift; 
		my $rtmp = shift;

		my $v = $self->vars;

		my $firstword = decode_u32(substr($rtmp->{'body'}, 0, 4));

		# AAC
		if (($firstword & 0xFFFF0000) == 0xAF010000) {

			if ($log->is_debug) {
				my $delta = $rtmp->{'timestamp'} - $v->{'ts_prev'};
				my $br = "n/a";
				if (!$delta) {
					$v->{'len_prev'} = $rtmp->{'length'};
				} else {
					$br = int(($rtmp->{'length'} + ($v->{'len_prev'} || 0)) * 8 / $delta);
					$v->{'ts_prev'} = $rtmp->{'timestamp'};
					$v->{'len_prev'} = 0;
				}
				$log->debug("message type 8 - AAC audiodata, len: $rtmp->{length} timestamp: $rtmp->{timestamp} bitrate: $br");
			}

			my $header = $v->{'adtsbase'};

			# add framesize dependant portion	
			my $framesize = $rtmp->{'length'} - 2 + 7;
			$header |= (
				"\x00\x00\x00" . 
				chr( (($framesize >> 11) & 0x03) ) . 
				chr( (($framesize >> 3)  & 0xFF) ) . 
				chr( (($framesize << 5)  & 0xE0) )
			);

			# add header and data to output buf
			$v->{'outBuf'} .= $header . substr($rtmp->{'body'}, 2);

		# AAC Config 	
		} elsif (($firstword & 0xFFFF0000) == 0xAF000000) {

			my $profile  = 1; # hard code to 1 rather than ($firstword & 0x0000f800) >> 11;
			my $sr_index = ($firstword & 0x00000780) >>  7;
			my $channels = ($firstword & 0x00000078) >>  3;

			$log->debug("message type 8 - AAC config: profile: $profile sr_index: $sr_index channels: $channels");

			$v->{'adtsbase'} =
				chr( 0xFF ) .
				chr( 0xF9 ) .
				chr( (($profile << 6) & 0xC0) | (($sr_index << 2) & 0x3C) | (($channels >> 2) & 0x1) ) .
				chr( (($channels << 6) & 0xC0) ) .
				chr( 0x00 ) . 
				chr( ((0x7FF >> 6) & 0x1F) ) .
				chr( ((0x7FF << 2) & 0xFC) );

		# MP3	
		} elsif (($firstword & 0xF0000000) == 0x20000000) {

			$log->debug("message type 8 - MP3 audiodata, len: $rtmp->{length} timestamp: $rtmp->{timestamp}");

			$v->{'outBuf'} .= substr($rtmp->{'body'}, 1);

		} else {

			$log->info("message type 8 - unrecognised audio, len: $rtmp->{length} timestamp: $rtmp->{timestamp}");

		}

		if ($self->state ne 'Playing') {

			if (!$self->params->{'live'} || $rtmp->{'timestamp'} > $liveStartTS) {

				# take ourselves off select, rely on data being pulled by calls to sysread
				Slim::Networking::Select::removeRead($self);

				$self->state('Playing');

			} elsif ($self->state ne 'liveBuffering') {
				
				$self->state('liveBuffering');
			}
		}

	 },

	'18' => sub {
		my $self = shift;
		my $rtmp = shift;

		my $res = amfParse($rtmp->{'body'});

		my $metaName = $res->[0];

		$log->info("message type 18 - metadata: $metaName");
		$log->is_debug && $log->debug(Data::Dump::dump($res));

		if ($metaName eq 'onMetaData' && ref $res->[1] eq 'HASH' && $res->[1]->{'duration'}) {
			$log->info("updating duration: " . $res->[1]->{'duration'});
			$self->song->duration($res->[1]->{'duration'});
		}
	 },

	'20' => sub {
		my $self = shift;
		my $rtmp = shift;

		my $res = amfParse($rtmp->{'body'});

		my $commandName = $res->[0];

		my $v = $self->vars;

		my $p = $self->params;

		$log->info("message type 20 - command message: $commandName");

		$log->is_debug && $log->debug(Data::Dump::dump($res));

		my $state = $self->state;

		if ($commandName eq '_result') {

			if ($state eq 'sentConnect') {

				$log->info("sending createStream");

				$self->sendRTMPPacket( $self->createStreamPacket );

				$self->state('sentCreateStream');

			} elsif ($state eq 'sentCreateStream') {

				$v->{'streamingId'} = $res->[3];

				if ($p->{'subscribe'}) {

					$log->info("sending FCSubscribe");

					$self->sendRTMPPacket( $self->subscribePacket($p->{'subscribe'}) );

					$self->state('sentFCSubscribe');

				} else {

					$log->info("sending play");

					$self->sendRTMPPacket( $self->playPacket( $v->{'streamingId'}, $p->{'streamname'}, $p->{'live'}, $p->{'start'} ) );

					$self->state('sentPlay');
				}
			}

		} elsif ($commandName eq '_error') {

			$log->warn("stream error - closing");

			$log->is_info && $log->info(Data::Dump::dump($res));
			
			$self->close;

		} elsif ($commandName eq 'onFCSubscribe') {

			if ($state eq 'sentFCSubscribe') {

				$log->info("sending play");
				
				$self->sendRTMPPacket( $self->playPacket( $v->{'streamingId'}, $p->{'streamname'}, $p->{'live'}, $p->{'start'} ) );

				$self->state('sentPlay');
			}

		} elsif ($commandName eq 'onStatus') {

			if (ref $res->[3] eq 'HASH') {

				my $level = $res->[3]->{'level'};
				my $code  = $res->[3]->{'code'};

				$log->info("$level $code");

				if ($code =~ /NetStream\.Failed|NetStream\.Play\.Failed|NetStream\.Play\.StreamNotFound|NetConnection\.Connect\.InvalidApp|NetStream\.Play\.Complete|NetStream\.Play\.Stop/) {

					$log->info("closing");

					$log->is_info && $log->info(Data::Dump::dump($res));

					$self->close;
				}
			}
		}

	},

};

sub sysread {
	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];

	if (!$self->processRTMP) {

		$log->info("processRTMP returned 0 - input socket closed");

		$self->close;

		return 0;
	}

	if (!$self->connected) {

		$log->info("input socket not connected");

		$self->close;

		return 0;
	}

	my $v = $self->vars;

	my $len = length($v->{'outBuf'});

	if ($len > 0 && $self->state eq 'Playing') {

		my $bytes = min($len, $maxBytes);

		$_[1] = substr($v->{'outBuf'}, 0, $bytes);

		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);

		return $bytes;

	} else {

		$! = EWOULDBLOCK;
		return undef;
	}
}

sub processRTMP {
	my $self = shift;

	my $v = $self->vars;

	my $readmore;

	do {

		$readmore = 0;

		my $len = length($v->{'inBuf'});

		my $new = CORE::sysread($self, $v->{'inBuf'}, 4096, $len);
		
		if (defined $new) {
			
			if ($new > 0) {
				
				$len += $new;
				
				$v->{'receivedBytes'} += $new;
				
			} else {
				
				# end of stream
				return 0;
			}
		}
		
		if ($self->state =~ /hsAwait/) {
			
			# handshake phase

			my $state = $self->state;
			
			my $expect  = $handshakeHandlers->{ $state }->[0];
			my $handler = $handshakeHandlers->{ $state }->[1];
			
			if ($len >= $expect) {
				
				my $packet = substr($v->{'inBuf'}, 0, $expect);
				
				$v->{'inBuf'} = substr($v->{'inBuf'}, $expect);
				
				my $newState = $handler->($self, $packet) || do {
					
					$log->error("$state - error in handshake");
					
					# close session
					$self->close;
					return 0;
				};

				$self->state($newState);

				$readmore = 1;
			}
			
		} elsif ($len) {
			
			# process rtmp packets
			
			my $header0 = decode_u8(substr($v->{'inBuf'}, 0, 1));
			my $chan    = $header0 & 0x3f;
			my $fmt     = ($header0 & 0xc0) >> 6;
			my $info;
			my $body;
			
			my $inCache = $v->{'inCache'}->[$chan] ||= {};
			
			#print "header0: $header0 fmt: $fmt chan: $chan\n";
			if ($chan == 0 || $chan == 1) {
				# implementation is limited to 1 byte chunk headers
				$log->error("don't support channels > 63");
				$self->close;
				return 0;
			}
			
			if ($fmt == 0 && $len >= 12) {
				
				my $t0len = decode_u24(substr($v->{'inBuf'}, 4, 3));
				my $read  = min($t0len, $v->{'recvChunkSize'}) + 12;
				my $ts    = decode_u24(substr($v->{'inBuf'}, 1, 3));
				my $header = 12;

				if ($ts == 0xffffff) {
					if ($len >= 16) {
						$ts = decode_u32(substr($v->{'inBuf'}, 12, 4));
					}
					$read   += 4;
					$header += 4;
				}
				
				if ($len >= $read) {
					
					$info = {
						chunkChan => $chan,
						type      => decode_u8 (substr($v->{'inBuf'}, 7, 1)),
						timestamp => $ts,
						length    => $t0len,
						streamId  => decode_u32le(substr($v->{'inBuf'}, 8, 4)),
					};
					
					my $frag = substr($v->{'inBuf'}, $header, $read - $header);
					$v->{'inBuf'} = substr($v->{'inBuf'}, $read);
					
					if ($read == $t0len + $header) {
						$body = $frag;
					} else {
						$inCache = $v->{'inCache'}->[$chan] = {
							info   => $info,
							body   => $frag,
							remain => $t0len + $header - $read,
						};
					}
					
					$readmore = 1;
				}
				
			} elsif ($fmt == 1 && $len >= 8) {

				my $t1len = decode_u24(substr($v->{'inBuf'}, 4, 3));
				my $read  = min($t1len, $v->{'recvChunkSize'}) + 8;
				my $delta = decode_u24(substr($v->{'inBuf'}, 1, 3));
 				my $header = 8;

				if ($delta == 0xffffff) {
					if ($len >= 12) {
						$delta = decode_u32(substr($v->{'inBuf'}, 8, 4));
					}
					$read   += 4;
					$header += 4;
				}
				
				if ($len >= $read) {
					
					$info = $inCache->{'info'};
					$info->{'type'} = decode_u8 (substr($v->{'inBuf'}, 7, 1));
					$info->{'timestamp'} += $delta;
					$info->{'length'} = $t1len;
					# streamId is cached version, (or not set if no preceeding chunk)
					$info->{'delta'} = $delta;
					
					my $frag = substr($v->{'inBuf'}, $header, $read - $header);
					$v->{'inBuf'} = substr($v->{'inBuf'}, $read);

					if ($read == $t1len + $header) {
						$body = $frag;
					} else {
						$inCache->{'body'} = $frag;
						$inCache->{'remain'} = $t1len + $header - $read;
					}

					$readmore = 1;
				}
				
			} elsif ($fmt == 2 && $len >= 4 && $inCache->{'info'}) {
				
				my $t2len = $inCache->{'info'}->{'length'};
				my $read  = min($t2len, $v->{'recvChunkSize'}) + 4;
				my $delta = decode_u24(substr($v->{'inBuf'}, 1, 3));
 				my $header = 4;

				if ($delta == 0xffffff) {
					if ($len >= 8) {
						$delta = decode_u32(substr($v->{'inBuf'}, 4, 4));
					}
					$read   += 4;
					$header += 4;
				}
				
				if ($len >= $read) {
			
					$info = $inCache->{'info'};
					$info->{'timestamp'} += $delta;
					# type, length, streamId is cached version
					$info->{'delta'} = $delta;
					
					my $frag = substr($v->{'inBuf'}, $header, $read - $header);
					$v->{'inBuf'} = substr($v->{'inBuf'}, $read);
			
					if ($read == $t2len + $header) {
						$body = $frag;
					} else {
						$inCache->{'body'} = $frag;
						$inCache->{'remain'} = $t2len + $header - $read;
					}
		
					$readmore = 1;
				}
				
			} elsif ($fmt == 3 && $inCache->{'remain'}) {

				my $read = min($inCache->{'remain'}, $v->{'recvChunkSize'}) + 1;
				
				if ($len >= $read) {
					
					my $frag = substr($v->{'inBuf'}, 1, $read - 1);
					$v->{'inBuf'} = substr($v->{'inBuf'}, $read);
					
					$inCache->{'body'}   .= $frag;
					$inCache->{'remain'} -= ($read - 1);
					
					if (!$inCache->{'remain'}) {
						$info = $inCache->{'info'};
						$body = $inCache->{'body'};
					}

					$readmore = 1;
				}
				
			} elsif ($fmt == 3 && $inCache->{'info'}) {

				my $t3len = $inCache->{'info'}->{'length'};
				my $read  = min($t3len, $v->{'recvChunkSize'}) + 1;

				if ($len >= $read) {
					
					$info = $inCache->{'info'};
					$info->{'timestamp'} += $info->{'delta'};
					# type, length, streamId is cached version
					
					my $frag = substr($v->{'inBuf'}, 1, $read - 1);
					$v->{'inBuf'} = substr($v->{'inBuf'}, $read);

					if ($read == $t3len + 1) {
						$body = $frag;
					} else {
						$inCache->{'body'} = $frag;
						$inCache->{'remain'} = $t3len + 1 - $read;
					}

					$readmore = 1;
				}
				
			}
			
			if ($body) {
				
				# cache the current packet
				$inCache->{'info'} = $info;
				
				my $rtmp = $info;
				$rtmp->{'body'} = $body;
				
				if (my $handler = $rtmpHandlers->{ $rtmp->{'type'} }) {
					
					$handler->($self, $rtmp);
					
				} else {

					$log->debug("unhandled packet type: " . $rtmp->{'type'});
					$log->is_debug && $log->debug(Data::Dump::dump($rtmp));
				}
			}

			if ($v->{'receivedBytes'} > $v->{'nextAck'}) {

				$log->debug("sending ack");
				
				$self->sendRTMPPacket( $self->ackPacket($v->{'receivedBytes'}) );
				
				$v->{'nextAck'} += $v->{'ackWindow'};
			}
			
		}

	} while ($readmore);

	return 1;
}


# Basic raw io encoding/decoding (based on Data::AMF::IO)

use constant ENDIAN => unpack('S', pack('C2', 0, 1)) == 1 ? 'BIG' : 'LITTLE';

# special case for ARM doubles which flip high and low 32 bits compared to normal little endian
use constant ARM_MIXED  => unpack("h*", pack ("d", 1)) eq "00000ff300000000" ? 1 : 0;

$log->debug("Endian: " . ENDIAN . ", ARM Mixed: " . ARM_MIXED);

sub encode_utf8 { encode_u16(bytes::length($_[0])) . $_[0] }

sub encode_number {
    return swapWords(swapBytes(pack('d', $_[0]))) if ARM_MIXED;
    return pack('d>', $_[0]) if $] >= 5.009002;
    return pack('d', $_[0])  if ENDIAN eq 'BIG';
    return swapBytes(pack('d', $_[0]));
}

sub decode_number {
    return unpack('d', swapBytes(swapWords($_[0]))) if ARM_MIXED;
    return unpack('d>', $_[0]) if $] >= 5.009002;
    return unpack('d', $_[0])  if ENDIAN eq 'BIG';
    return unpack('d', swapBytes($_[0]));
}

sub encode_u8  { pack('C', $_[0]) }
sub encode_u16 { pack('n', $_[0]) }
sub encode_u24 { substr(pack('N', $_[0]), 1, 3) }
sub encode_u32 { pack('N', $_[0]) }

sub encode_u32le { pack('V', $_[0]) }

sub encode_s16  {
    return pack('s>', $_[0]) if $] >= 5.009002;
    return pack('s', $_[0])  if ENDIAN eq 'BIG';
    return swapBytes(pack('s', $_[0]));
}

sub decode_utf8 { substr($_[0], 2) }

sub decode_u8  { unpack('C', $_[0]) }
sub decode_u16 { unpack('n', $_[0]) }
sub decode_u24 { unpack('N', ("\0" . $_[0]) ) }
sub decode_u32 { unpack('N', $_[0]) }

sub decode_u32le { unpack('V', $_[0]) }

sub decode_s16 {
    return unpack('s>', $_[0]) if $] >= 5.009002;
    return unpack('s', $_[0])  if ENDIAN eq 'BIG';
    return unpack('s', swapBytes($_[0]));
}

sub swapBytes { join '', reverse split '', $_[0] }

sub swapWords { return ( substr($_[0], 4, 4) . substr($_[0], 0, 4) ) }


# AMF0 formatting & parsing
# supports the subset of AMF0 needed to send RTMP commands and decode response
# (inspired by Data::AMF::IO which is more comprehensive but requires Moose)

sub amfFormatNumber { chr(0x00) . encode_number($_[0]) }

sub amfFormatBool   { chr(0x01) . chr($_[0] ? 0x01 : 0x00) }

sub amfFormatString { chr(0x02) . encode_utf8($_[0]) }

sub amfFormatNull   { chr(0x05) }
	
sub amfFormatObject {
	# support strings and numbers only in this implementation
    my $obj = shift;

	my $res = chr(0x03); # start of object

    for my $key (keys %$obj) {
		$res .= encode_utf8($key);
		my $val = $obj->{$key};
		if (looks_like_number($val)) {
			$res .= amfFormatNumber($val);
		} elsif (defined $val) {
			$res .= amfFormatString($val);
		} else {
			$res .= amfFormatNull($val);
		}
    }

	$res .= chr(0x00) . chr(0x00) . chr(0x09); # end object

	return $res;
}

sub amfParse {
	my $amf = shift;
	my @res;

	while (length($amf)) {
		push @res, _parse_one($amf);
	}

	return \@res;
}

my $parsers = {
	0 => sub { # number
		my $val = decode_number(substr($_[0], 0, 8));
		$_[0] = substr($_[0], 8);
		return $val;
	},
	1 => sub { # bool
		my $val = decode_u8(substr($_[0], 0, 1)) ? 0 : 1;
		$_[0] = substr($_[0], 1);
		return $val;
	},
	2 => sub { # string
		my $len = decode_u16(substr($_[0], 0, 2));
		my $val = substr($_[0], 2, $len);
		$_[0] = substr($_[0], 2 + $len);
		return $val;
	},
	3 => \&_parse_obj,
	# 4 - movieclip, not used in AMF0
	5 => sub { # null
		return undef;
	},
	6 => sub { # undefined
		return undef;
	},
	# 7 - reference - not supported
	8 => sub { # ecma array
		$_[0] = substr($_[0], 4); # skip count
		return _parse_obj($_[0]);
	},
	# 9 - end of object marker
	10=> sub { # strict array
		my $count = decode_u32(substr($_[0], 0, 4));
		$_[0] = substr($_[0], 4);
		my @res;
		for (1..$count) {
			push @res, _parse_one($_[0]);
		}
		return \@res;
	},
};

sub _parse_obj {
	my $obj = {};
	while (1) {
		my $key_len = decode_u16(substr($_[0], 0, 2));
		$_[0] = substr($_[0], 2);
		if ($key_len == 0) {
			$_[0] = substr($_[0], 1); # obj end marker
			return $obj;
		}
		my $key = substr($_[0], 0, $key_len);
		$_[0] = substr($_[0], $key_len);
		$obj->{ $key } = _parse_one($_[0]);
	}
}

sub _parse_one {
	return undef if !length($_[0]);

	my $type = decode_u8(substr($_[0], 0, 1));
	$_[0] = substr($_[0], 1);

	if ($parsers->{$type}) {
		return $parsers->{$type}->($_[0]);
	} else {
		$log->error("no parser for type: $type truncating");
		$_[0] = '';
		return 'unknown';
	}
}


###############
# stuff for direct streaming....

sub slimprotoFlags { 
	my ($class, $client, $url, $isDirect) = @_;

	return $isDirect ? 0x20 : 0x00;
}

sub canDirectStream {
	my ($class, $client, $url) = @_;

	# use the streamUrl as it may have been updated by updateOnStream
	my $song = $client->streamingSong;
	$url = ($song->can('streamUrl') ? $song->streamUrl : $song->{'streamUrl'}) || $url;

	# check if player can support direct streaming and if we should use it (no sync and pref not disabled)
	if ($client->can('canDecodeRtmp') && $client->canDecodeRtmp && Slim::Player::Protocols::HTTP->canDirectStream($client, $url)) {

		$log->info("directstream rtmp $url");

		$log->debug(Data::Dump::dump($class->unpackUrl($url)));

		return $url;
	}

	return undef;
}

sub requestString {
	my ($class, $client, $url, undef, $seekdata) = @_;

	my $song = $client->streamingSong;
	my $p = $class->unpackUrl($url);

	my $start;

	$song->pluginData('icon' => $p->{'icon'}) if $p->{'icon'};
	$song->pluginData('info' => $p->{'desc'}) if $p->{'desc'};

	$song->duration($p->{'duration'}) if $p->{'duration'};

	Slim::Music::Info::setBitrate($song->track->url, $p->{'br'} * 1000) if $p->{'br'};

	if (!$p->{'live'} && (my $newtime = $seekdata->{'timeOffset'})) {

		$start = $newtime;

		if($song->can('startOffset')) {
			$song->startOffset($newtime);
		} else {
			$song->{startOffset} = $newtime;
		}
		
		$client->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	my %params;
	my $meta = ($log->is_debug || (!$p->{'live'} && !$p->{'duration'})) ? "send" : "none";

	if ($client->canDecodeRtmp == 2) {

		# client supports formating amf0 itself
		%params = (
			'app'        => $p->{'app'},
			'swfurl'     => $p->{'swfurl'},
			'tcurl'      => $p->{'tcurl'},
			'streamname' => $p->{'streamname'},
			'live'       => $p->{'live'},
			'meta'       => $meta,
		);
		$params{start}   = $start if $start;
		$params{subname} = $p->{'subscribe'} if $p->{'subscribe'};

	} else {

		# format amf0 serialised object for client, assume the streamId will always be 1
		my $streamingId = 1;
		%params = (
			'connect' => $class->formatRTMP( $class->connectPacket( $p->{'app'}, $p->{'swfurl'}, $p->{'tcurl'} ) ),
			'create'  => $class->formatRTMP( $class->createStreamPacket ),
			'play'    => $class->formatRTMP( $class->playPacket( $streamingId, $p->{'streamname'}, $p->{'live'}, $start ) ),
			'meta'    => $meta,
		);
		$params{subscribe} = $class->formatRTMP( $class->subscribePacket($p->{'subscribe'}) ) if $p->{'subscribe'};
	}

	return join('&', map { "$_=" . encode_base64($params{$_}, '') } keys %params) . '&';
}

sub handlesStreamHeaders {
	my ($class, $client, $headers) = @_;

	$log->debug("sending cont message to player");

	$client->sendContCommand(0, 0);

	return 1;                    # 7.6 terminate header processing
}

sub handlesStreamHeadersFully {} # 7.5 terminate header processing

sub parseMetadata {
	my ($class, $client, $song, $metadata) = @_;

	my $meta = amfParse($metadata);

	$log->is_debug && $log->debug(Data::Dump::dump($meta));

	if ($meta->[0] eq 'onStatus' && ref $meta->[3] eq 'HASH' && $meta->[3]->{'code'} &&	$meta->[3]->{'code'} eq 'NetStream.Play.Start' &&
		$client->canDecodeRtmp == 1) {

		$log->debug("sending cont message to player");

		$client->sendContCommand(0, 0);
	}

	if ($meta->[0] eq 'onMetaData' && ref $meta->[1] eq 'HASH') {

		if ($meta->[1]->{'duration'}) {
			$log->debug("updating duration");
			$song->duration($meta->[1]->{'duration'});
		}

		if ($meta->[1]->{'audiodatarate'}) {
			$log->debug("updating bitrate");
			Slim::Music::Info::setBitrate($song->track->url, $meta->[1]->{'audiodatarate'} * 1000);
		}
	}
}

1;
