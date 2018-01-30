package Plugins::BBCiPlayer::iPlayer;

# Plugin to play live and on demand BBC radio streams
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

use XML::Simple;
use URI::Escape qw(uri_unescape);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.bbciplayer');
my $prefs = preferences('plugin.bbciplayer');

Slim::Player::ProtocolHandlers->registerHandler('iplayer', __PACKAGE__);

use constant TTL_EXPIRE => 10;

sub isRemote { 1 }

# convert iplayer url into playlist of placeholder tracks which link to each playlist url without actually scanning
# each placeholder is only scanned when trying to play it so we avoid scanning multiple playlists for one item
sub scanUrl {
	my ($class, $url, $args) = @_;

	$log->info("$url");

	my $song  = $args->{'song'};
	my $track = $song->track;
	my $client = $args->{'client'};

	my ($type, $params) = $url =~ /iplayer:\/\/(live|aod)\?(.*)$/;
	my %params = map { $_ =~ /(.*?)=(.*)/; $1 => $2; } split(/&/, $params);

	my $playlist = Slim::Schema::RemoteTrack->fetch($url, 1);

	$song->pluginData(baseUrl => $url);

	my @prefOrder = $class->prefOrder($client, $type);

	$log->info("baseUrl: $url type: $type prefOrder:" . join(',', @prefOrder));

	# allow title to be overridden in iplayer url, or use existing title
	my $title = uri_unescape($params{'title'}) || Slim::Music::Info::getCurrentTitle($client, $url) || Slim::Music::Info::title($url);
	my $desc  = uri_unescape($params{'desc'});
	my $icon = $params{'icon'};

	if ($title) {
		$playlist->title($title);
	}

	# convert pref order into playlist of ordered placeholder tracks which link to urls to scan
	# the playback code will call getNextTrack for each placeholder and allow it to be scanned when needed
	my @placeholders;

	for my $t (@prefOrder) {

		if ($params{$t}) {
			push @placeholders, { t => $t, url => "iplayer://$type?$t=$params{$t}&type=$t" };
		}

		if ($t =~ /flashaac|flashmp3|wma/ && $params{'ms'}) {
			push @placeholders, { t => $t, url => "iplayer://$type?ms=$params{ms}&type=$t" };
		}
	}

	my @pl;

	for my $placeholder (@placeholders) {

		$log->info("placeholder: $placeholder->{url}");

		my $ct = $placeholder->{'t'};
		$ct =~ s/flash//;
		$ct =~ s/hls/aac/;

		push @pl, Slim::Schema::RemoteTrack->updateOrCreate($placeholder->{'url'}, {
			title        => $title,
			secs         => $params{'dur'},
			content_type => $ct,
		});
	}

	$playlist->setTracks(\@pl);
	$song->_playlist(1);

	$args->{'cb'}->($playlist);

	Slim::Utils::Timers::killTimers($client, \&_checkStream);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&_checkStream, $url);
}

sub getNextTrack {
	my $class= shift;
	my $song = shift;
	my $cb   = shift;
	my $ecb  = shift;

	my $track   = $song->currentTrack();
	my $baseUrl = $song->pluginData('baseUrl');

	my ($type, $handler, $url, $t) = $track->url =~ /iplayer:\/\/(live|aod)\?(.*?)=(.*?)&type=(.*)/;

	$log->info("scanning: $type: $handler $url for $t");

	my $callback = sub {
		my ($obj, $error) = @_;

		if ($obj) {

			my $playlist = Slim::Schema::RemoteTrack->fetch($baseUrl)->tracksRef;
			my $pl;

			if (ref $obj eq 'ARRAY') {
				$pl = $obj;
			} elsif (blessed $obj) {
				$pl = $obj->isa('Slim::Schema::RemotePlaylist') ? $obj->tracksRef : [ $obj ];
			}

			$log->info("scanned: $url");

			if (scalar @$pl) {

				my $highBr;
				my @highPl;
				my @lowPl;

				for my $foundTrack (@$pl) {
					$log->info(" found: " . $foundTrack->url . " bitrate: " . $foundTrack->bitrate);
					$highBr ||= $foundTrack->bitrate;
					if (!$highBr || $foundTrack->bitrate == $highBr) {
						push @highPl, $foundTrack;
					} else {
						push @lowPl, $foundTrack;
					}
				}

				# find ourselves in the existing playlist and splice in new high bitrate track objects after our placeholder
				# add remaining tracks to end of playlist so if all formats have been parsed we try lower bitrates 
				my $i = 0;
				for my $entry (@$playlist) {
					if ($entry->url eq $track->url) {
						$log->info("adding " . scalar @highPl . " tracks at placeholder, " . scalar @lowPl . " at end of playlist");
						splice @$playlist, $i+1, 0, @highPl;
						push @$playlist, @lowPl;
						last;
					}
					++$i;
				}
				
				# move on to first new track
				$song->_getNextPlaylistTrack();
				
				$cb->();
				return;
			}

		} elsif ($error) {
			$log->warn("error: $error");
		}

		$log->warn("no track objects found!");

		# move on to next placeholder track and recurse
		if ($song->_getNextPlaylistTrack()) {

			$class->getNextTrack($song, $cb, $ecb);
			return;
		}
		
		# no tracks left - return error
		$ecb->();
	};

	if ($handler =~ /hls/){
		# adjust url so protocol handler logic will pick hls handler
		$url =~ s/^http/hls/;
		$url =~ s/$/\|/;
		
		my $obj = Slim::Schema::RemoteTrack->updateOrCreate($url, {
			title        => $track->title,
			secs         => $track->secs,
			content_type => 'aac',
		});

		$callback->($obj);
		return;
	}

	if ($handler =~ /aac|wma|mp3/) {
		Slim::Utils::Scanner::Remote->scanURL($url, { cb => $callback, song => $song, title => $track->title });
		return;
	}

	if ($handler eq 'ms') {
		Slim::Networking::SimpleAsyncHTTP->new(
			\&_msParse, 
			sub { 
				$log->warn("error fetching ms");
				$ecb->(); 
			}, 
			{ 
				cache   => 1, # allow cacheing of responses
				expires => TTL_EXPIRE,
				cb      => $callback,
				song    => $song,
				args    => { 
					title => $track->title, url => $url, type => $type, t => $t, dur => $track->secs,
				},
			},
		)->get($url);
		return;
	}

	$ecb->();
}

sub _checkStream {
	my ($client, $url) = @_;

	my $sc = $client->master->controller;
	my $streaming = $sc->streamingSong;

	if ($sc->streamingSong && $streaming->track->url eq $url) {

		$log->info("consecutiveErrors: $sc->{consecutiveErrors} songElapsed: " . $sc->playingSongElapsed);

		if ($sc->{'consecutiveErrors'} == 0 && $sc->playingSongElapsed >= 2) {

			$log->info("stream playing - disabling playlist state");

			$streaming->_playlist(0);

		} else {

			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&_checkStream, $url);
		}
	}
}

sub _msParse {
	my $http = shift;
	my $cb   = $http->params('cb');
	my $song = $http->params('song');
	my $args = $http->params('args');
	my $update = $http->params('update');

	$log->info("parsing: " . $http->url);

	my $xml = eval { XMLin($http->contentRef, KeyAttr => undef, ForceArray => 'media' ) };
	if ($@) {
		$log->error("error: $@");
		$cb->();
		return;
	}

	my @streams;
	my $swf = '';

	for my $media (@{$xml->{'media'} || []}) {

		my ($type) = $media->{'type'} =~ /audio\/(.*)/;

		for my $c (@{$media->{'connection'} || []}) {

			if ($c->{'protocol'} eq 'http') {

				next unless ($type =~ /wma|x\-ms\-asf/ && $args->{'t'} eq 'wma' || 
							 $type eq 'mp4' && $args->{'t'} eq 'aac');

				push @streams, {
					type    => $args->{'t'},
					service => $media->{'service'},
					br      => $media->{'bitrate'},
					url     => $c->{'href'},
				};

			} elsif ($c->{'protocol'} eq 'rtmp') {

				if ($c->{'supplier'} eq 'akamai') {

					next unless ($type eq 'mp4'  && ($update || $args->{'t'} eq 'flashaac') || 
								 $type eq 'mpeg' && ($update || $args->{'t'} eq 'flashmp3'));

					my ($ct) = $args->{'t'} =~ /flash(aac|mp3)/;
					my $live = $c->{'application'} && $c->{'application'} eq 'live';
					my $appl = $c->{'application'} || "ondemand";

					push @streams, {
						type    => $args->{'t'},
						service => $media->{'service'},
						ct      => $ct,
						br      => $media->{'bitrate'},
						url     => Plugins::BBCiPlayer::RTMP->packUrl({
							host       => $c->{'server'},
							port       => 1935,
							swfurl     => $swf,
							streamname => "$c->{identifier}?$c->{authString}" . ($live ? "&aifp=v001" : ""),
							subscribe  => $live ? "$c->{identifier}" : undef,
							tcurl      => "rtmp://$c->{server}:1935/$appl?_fcs_vhost=$c->{server}&$c->{authString}",
							app        => "$appl?_fcs_vhost=$c->{server}&$c->{authString}",
							live       => $live,
							ct         => $ct,
							br         => $media->{'bitrate'},
							url        => "$args->{url}#$media->{service}",
							duration   => $args->{'dur'},
							update     => __PACKAGE__,
							ttl        => time() + TTL_EXPIRE,
						}),
					};

				} elsif ($c->{'supplier'} eq 'limelight') {

					next unless $type eq 'mp4' && ($update || $args->{'t'} eq 'flashaac');
					
					push @streams, {
						type    => 'flashaac',
						service => $media->{'service'},
						ct      => 'aac',
						br      => $media->{'bitrate'},
						url     => Plugins::BBCiPlayer::RTMP->packUrl({
							host       => $c->{'server'},
							port       => 1935,
							swfurl     => $swf,
							streamname => "$c->{identifier}",
							tcurl      => "rtmp://$c->{server}:1935/$c->{application}?$c->{authString}",
							app        => "$c->{application}?$c->{authString}",
							ct         => 'aac',
							br         => $media->{'bitrate'},
							url        => "$args->{url}#$media->{service}",
							duration   => $args->{'dur'},
							update     => __PACKAGE__,
							ttl        => time() + TTL_EXPIRE,
						}),
					};

				}
			}
		}
	}

	# refresh rtmp params only
	if ($update) {
		for my $stream (@streams) {
			if ($stream->{'service'} eq $update->{'stream'}) {
				$log->info("updated stream: $stream->{url}");
				$song->streamUrl($stream->{'url'});
				Slim::Music::Info::setRemoteMetadata($stream->{'url'}, {
					bitrate => $stream->{'br'},
					ct      => $stream->{'ct'},
				});
			}
		}
		$update->{'cb'}->();
		return;
	}

	# sort into bitrate order, preferring higher bitrates
	@streams = sort { $b->{'br'} <=> $a->{'br'} } @streams;
	
	my @tracks;
	my $pending = 0;

	for my $stream (@streams) {

		if ($stream->{'type'} eq 'wma') {

			++$pending;
			Slim::Utils::Scanner::Remote->scanURL($stream->{'url'}, { song => $song, cb => sub {
				my ($obj, $error) = @_;
				push @tracks, $obj->isa('Slim::Schema::RemotePlaylist') ? $obj->tracks : $obj;
				if (!--$pending) {
					$cb->(\@tracks);
				}
			} });

		} else {

			push @tracks, Slim::Music::Info::setRemoteMetadata($stream->{'url'}, {
				title   => $args->{'title'},
				bitrate => $stream->{'br'},
				ct      => $stream->{'ct'},
			}),
		}
	}

	if ($pending == 0) {
		$cb->(\@tracks);
	}
}

sub update {
	my $class = shift;
	my $song  = shift;
	my $params= shift;
	my $cb    = shift;
	my $ecb   = shift;

	my ($url, $stream) = $params->{'url'} =~ /(.*)#(.*)/;
	$url ||= $params->{'url'};

	$log->info("update: $url $stream");

	Slim::Networking::SimpleAsyncHTTP->new(
		\&_msParse,
		sub { 
			$log->warn("unable to fetch xml feed: " . shift->url);
			$ecb->();
		},  
		{ song => $song, update => { stream => $stream, cb => $cb }, args => { url => $params->{'url'} } }
	)->get($url);
}

sub getMetadataFor {
	my $class  = shift;
	my $client = shift;
	my $url    = shift;

	my ($type, $params) = $url =~ /iplayer:\/\/(live|aod)\?(.*)$/;
	my %params = map { $_ =~ /(.*?)=(.*)/; $1 => $2; } split(/&/, $params);

	if ($client && (my $song = $client->currentSongForUrl($url))) {

		my $icon = $song->pluginData('icon') || $params{'icon'};
		$icon =~ s/256x144/480x270/;

		my $stream = $song->streamUrl;
		my $track  = Slim::Schema::RemoteTrack->fetch($stream);

		if ($client->isPlaying && !$song->pluginData('radiovis') && ($prefs->get('radiovis_txt') || $prefs->get('radiovis_slide')) && 
			$params{'radiovis'}) {
		
			require Plugins::BBCiPlayer::RadioVis;
		
			# store radiovis object in song so we close livetext when song is destroyed
			$song->pluginData('radiovis' => Plugins::BBCiPlayer::RadioVis->new($params{'radiovis'}, $song));
		}

		my $title = uri_unescape($params{'title'}) || Slim::Music::Info::getCurrentTitle($client, $url) ||Slim::Music::Info::title($url);
		
		# work around icy bitrates being too high on bbc servers - modified version of S:S:RemoteTrack->prettyBitRate
		my $bitrate  = $track && $track->bitrate;
		my $mode = defined $track->vbr_scale ? 'VBR' : 'CBR';

		if ($bitrate) {
			$bitrate /= 1000;
			$bitrate = $bitrate > 1000 ? $bitrate / 1000 : $bitrate;
			$bitrate = int ($bitrate) . Slim::Utils::Strings::string('KBPS') . ' ' . $mode;
		}

		if ($song->pluginData('icon')) {
			$icon = $song->pluginData('icon');
		}

		my $codec = $song->pluginData('codec');

		if ($song->pluginData('info')) {
			return {
				title    => $title,
				artist   => $song->pluginData('info'),
				cover    => $icon,
				icon     => $icon,
				type     => $codec || ($track && $track->content_type),
				bitrate  => $bitrate,
				duration => $track && $track->secs,
			};
		} else {
			return {
				title    => $song->pluginData('track')  || $title,
				artist   => $song->pluginData('artist') || uri_unescape($params{'desc'}),
				cover    => $icon,
				icon     => $icon,
				type     => $codec || ($track && $track->content_type),
				bitrate  => $bitrate,
				duration => $track && $track->secs,
			};
		}

	}

	return {
		artist => uri_unescape($params{'desc'}),
		cover  => $params{'icon'},
		icon   => $params{'icon'},
	};
}

sub prefOrder {
	my $class = shift;
	my $client = shift;
	my $type  = shift;

	my @prefOrder;

	my @playerFormats = exists &Slim::Player::CapabilitiesHelper::supportedFormats 
		? Slim::Player::CapabilitiesHelper::supportedFormats($client) 
		: $client->formats;

	my $transcode = $prefs->get('transcode');

	for my $format (split(/,/, $prefs->get("prefOrder_$type"))) {

		my $testFormat = $format;
		$testFormat =~ s/flash//;
		$testFormat =~ s/hls/aac/;

		for my $playerFormat (@playerFormats) {

			if ($testFormat eq $playerFormat ||
				($transcode && exists &Slim::Player::TranscodingHelper::checkBin && 
				 Slim::Player::TranscodingHelper::checkBin("$testFormat-$playerFormat-*-*")) ) {

				push @prefOrder, $format;
				last;
			}
		}
	}

	return @prefOrder;
}

1;
