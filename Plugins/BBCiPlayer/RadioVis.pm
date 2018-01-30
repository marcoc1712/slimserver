package Plugins::BBCiPlayer::RadioVis;

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

use base qw(Slim::Utils::Accessor);

use Scalar::Util qw(weaken);

use Slim::Networking::Async;
use Slim::Utils::Errno;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

__PACKAGE__->mk_accessor( rw   => qw(path state async session buf text) );
__PACKAGE__->mk_accessor( weak => qw(song) );

my $log   = logger('plugin.bbciplayer.radiovis');
my $prefs = preferences('plugin.bbciplayer');

sub new {
	my $ref   = shift;
	my $path  = shift;
	my $song  = shift;

	my $self = $ref->SUPER::new;

	$log->info("radiovis: " . $path);

	my $weakself = $self;
	weaken($weakself); # to ensure object gets destroyed as this is stored inside parser

	my $connect = join("\n", (
		"CONNECT",
		"host: radiovis.external.bbc.co.uk",
		"",
		"\x00",
	));

	my $subscribe = "";

	if ($prefs->get('radiovis_txt')) {
		$subscribe .= join("\n", (
			"SUBSCRIBE",
			"destination: /topic/" . $path . "/text",
			"",
			"\x00"));
	}

	if ($prefs->get('radiovis_slide')) {
		$subscribe .= join("\n", (
			"SUBSCRIBE",
			"destination: /topic/" . $path . "/image",
			"",
			"\x00"));
	}

	$self->session(int(rand(1000000)));
	$self->path($path);
	$self->state('connect');
	$self->buf("");
	$self->song($song);
	$self->async(Slim::Networking::Async->new);

	$log->debug("send connect");

	# connect to stomp server
	$self->async->write_async( {
		host        => "radiovis.external.bbc.co.uk",
		port        => 61613,
		content_ref => \$connect,
		Timeout     => preferences('server')->get('remotestreamtimeout') || 10,
		skipDNS     => 0,
		onError     => sub {
			my $sock = shift;
			$log->warn($_[1] || "error disconnecting");
			$sock->disconnect;
		},
		onRead      => sub {
			my $sock = shift;
			my $buf;
			my $read = sysread($sock->socket, $buf, 4096);
			if ($read) {
				$buf = $weakself->buf . $buf;
				while ($buf =~ /(.*?)\x00/s) {
					my $frame = $1;
					$buf = substr($buf, length($frame) + 2);
					if ($weakself->state eq 'connect' && $frame =~ /^CONNECTED/) {
						$log->debug("send subscribe");
						Slim::Networking::Select::writeNoBlock($sock->socket, \$subscribe);
						$weakself->state('message');
					} elsif ($weakself->state eq 'message' && $frame =~ /^MESSAGE/) {
						while (my ($headerline, $remain) = $frame =~ /(.*?)\n(.*)/s) {
							$frame = $remain;
							if ($headerline eq "") {
								last;
							}
						}
						$log->info("body: $frame");
						if ($frame =~ /^TEXT\s+(.*)/) {
							$weakself->gotinfo({ type => 'text', text => $1 });
						}
						if ($frame =~ /^SHOW\s+(.*)/) {
							$weakself->gotinfo({ type => 'slide', slide => $1 });
						}
					} else {
						$log->debug("discard frame: $frame");
					}
				}
				$weakself->buf($buf) if $weakself;
			} elsif (defined $read || $! != EWOULDBLOCK) {
				$log->warn("disconnecting, sysread returned: $read [$!]");
				$sock->disconnect;
			}
		},
	} );

	# swap the lines functions for all synced players
	if ($prefs->get('radiovis_txt')) {
		for my $client ($song->owner->allPlayers) {
			
			$log->debug("storing lines functions for $client");
			
			my $info = $client->pluginData('radiovis') || {};
			
			$info->{'session'}  = $self->session;
			$info->{'custom'} ||= $client->customPlaylistLines;
			$info->{'lines2'} ||= $client->lines2periodic;
			
			$client->pluginData('radiovis', $info);
			
			$client->customPlaylistLines(\&ourNowPlayingLines);
			$client->lines2periodic(\&ourNowPlayingLines);
			
			if (Slim::Buttons::Common::mode($client) =~ /playlist|screensaver/) {
				# force our lines if already in Playlist display
				$client->lines(\&ourNowPlayingLines);
			}
		}
	}

	# set title for url in case getCurrentTitle is called (avoiding standardTitle as we mix up artist title etc)
	Slim::Music::Info::setCurrentTitle($song->can('streamUrl') ? $song->streamUrl : $song->{'streamUrl'}, $song->track->title);

	return $self;
}

sub gotinfo {
	my $self = shift;
	my $info = shift;
	my $song = $self->song || return;

	if (!$song->owner->isPlaying) {
		# force destruction of radiovis object if no longer playing
		$song->pluginData->{'radiovis'} = undef;
		return;
	}

	# estimate the delay of the audio chain
	my $client  = $song->owner->master;
	my $bitrate = $song->streambitrate() || 128000;
	
	my $decodeBuffer = $client->bufferFullness() / ( int($bitrate / 8) );
	my $outputBuffer = $client->outputBufferFullness() / (44100 * 8);

	my $delay = $outputBuffer + $decodeBuffer;

	$log->info("$info->{type}: displaying in $delay seconds: $info->{text}");

	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $delay, \&update, $info);
}

sub update {
	my $self = shift;
	my $info = shift;
	my $song = $self->song || return;

	$log->info("$info->{type}: displaying now");

	if ($info->{'type'} eq 'text') {
	
		# not supported by radiovis feed
		if ($info->{'text'} =~ /Now playing: (.*?) by (.*?)\.$/) {
			
			$song->pluginData('track'  => $1);
			$song->pluginData('artist' => $2);
			$song->pluginData->{'info'} = undef; # need to do this to clear key
			
		} else {

			$song->pluginData('info' => $info->{'text'});
		}
		
		$self->text($info->{'text'});

	} elsif ($info->{'type'} eq 'slide') {

		$song->pluginData('icon' => $info->{'slide'});
	}

	$song->owner->master->currentPlaylistUpdateTime(Time::HiRes::time());

	my $notify = Slim::Utils::Versions->compareVersions($::VERSION, "7.5") >= 0 ? [ 'newmetadata' ] : [ 'playlist', 'newsong' ];
	
	Slim::Control::Request::notifyFromArray($song->owner->master, $notify);
}

sub ourNowPlayingLines {
	my $client = shift;
	my $args   = shift || {};

	if (!Slim::Buttons::Playlist::showingNowPlaying($client) && !$args->{'screen2'}) {
		# fall through to show other items in playlist
		return Slim::Buttons::Playlist::lines($client, $args);
	}

	my $parts;

	my $song = $client->streamingSong;

	if (!$args->{'trans'} && $song && $song->pluginData && (my $self = $song->pluginData->{'radiovis'})) {

		my ($complete, $queue) = $client->scrollTickerTimeLeft($args->{'screen2'} ? 2 : 1);
		my $title =  $client->streamingSong->track->title;
		my $ticker = $complete == 0 ? $self->text : "";
		
		if ($prefs->get('livetxt_classic_line') == 0) {
			# scrolling on top line
			$parts = {
				line    => [ undef, $title ],
				overlay => [ undef, $client->symbols('notesymbol') ], 
				ticker  => [ $ticker, undef ],
			};
		} else {
			# scrolling on bottom line (normal scrolling line)
			$parts = {
				line    => [ $title, undef ],
				ticker  => [ undef, $ticker ],
			};

			$client->nowPlayingModeLines($parts);
		}

		# special cases for Transporter second display
		if ($args->{'screen2'}) {
			$parts = { screen2 => $parts };
		} elsif ($client->display->showExtendedText) {
			$parts->{'screen2'} = {};
		}

	} else {

		$parts = $client->currentSongLines($args);
	}

	return $parts;
}

sub DESTROY {
	my $self  = shift;
	my $path  = $self->path;
	
	$log->info("close: $path");

	$self->async->disconnect;

	for my $client (Slim::Player::Client::clients()) {

		my $info = $client->pluginData('radiovis');
		
		next unless $info && $info->{'session'} == $self->session;

		$log->debug("restoring lines functions for $client");

		# reset current lines if in playlist mode
		if (Slim::Buttons::Common::mode($client) =~ /playlist|screensaver/) {
			$client->lines($info->{'custom'} || \&Slim::Buttons::Playlist::lines);
		}

		$client->customPlaylistLines($info->{'custom'});
		$client->lines2periodic($info->{'lines2'});
	}
}

1;
