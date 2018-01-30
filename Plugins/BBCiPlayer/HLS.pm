package Plugins::BBCiPlayer::HLS;

# HLS protocol handler
#
# (c) Triode, 2015, triode1@btinternet.com
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

use base qw(IO::Handle);

use Slim::Utils::Errno;
use Slim::Utils::Log;

use bytes;

use constant PRE_FETCH => 1; # number of chunks to prefetch

my $log = logger('plugin.bbciplayer.hls');

Slim::Player::ProtocolHandlers->registerHandler('hls', __PACKAGE__);

my $codecIds = {
	"mp4a.40.1" => "AAC",
	"mp4a.40.2" => "AAC LC",
	"mp4a.40.5" => "AAC SBR",
};

sub new {
	my $class = shift;
	my $args = shift;

	my $song     = $args->{'song'};
	my $url      = ($song->can('streamUrl') ? $song->streamUrl : $song->{'streamUrl'}) || $args->{'url'};
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $start    = $seekdata->{'timeOffset'};

	if ($start) {
		if($song->can('startOffset')) {
			$song->startOffset($start);
		} else {
			$song->{startOffset} = $start;
		}
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $start);
	}

	$url =~ s/^hls/http/;
	$url =~ s/\|$//;

	$log->debug("open $url $start");

	my $self = $class->SUPER::new;

	${*$self}{'song'} = $song;
	${*$self}{'_chunks'} = [];
	${*$self}{'_pl_noupdate'} = 0;
	${*$self}{'_played'} = 0;

	$self->_fetchPL($url, $start);

	return $self;
}

sub _fetchPL {
	my $self = shift;
	my $url  = shift;
	my $start= shift || 0;

	$log->debug("fetch playlist: $url start: $start");

	${*$self}{'_pl_refetch'} = undef;	

	Slim::Networking::SimpleAsyncHTTP->new(
		\&_parsePL, 
		sub { 
			$log->warn("error fetching $url");
			$self->close; 
		}, 
		{ obj => $self, url => $url, start => $start, cache => 0 },
	)->get($url);
}

sub _parsePL {
	my $http = shift;
	my $self = $http->params('obj');
	my $url  = $http->params('url');
	my $start= $http->params('start');

	my $is_debug = $log->is_debug;

	$is_debug && $log->debug("got: $url start: $start");

	my @lines = split(/\n/, $http->content);

	my $line1 = shift @lines;
	if ($line1 !~ /#EXTM3U/) {
		$log->warn("bad m3u file: $url");
		$self->close;
		return;
	}

	my $duration = 0;
	my $lastint;
	my $chunknum;
	my @chunks = ();

	while (my $line = shift @lines) {

		if ($line =~ /#EXT-X-STREAM-INF:(.*)/) {
			foreach my $params (split(/,/, $1)) {
				if ($params =~ /BANDWIDTH=(\d+)/) {
					$is_debug && $log->debug("bandwidth: $1");
					my $stream = ${*$self}{'song'}->streamUrl;
					my $track  = Slim::Schema::RemoteTrack->fetch($stream);
					$track->bitrate($1);
				} elsif ($params =~ /CODECS="(.*)"/) {
					my $codec = $codecIds->{$1};
					if ($codec) {
						$is_debug && $log->debug("codecs: $1 $codec");
						${*$self}{'song'}->pluginData('codec', $codec);
					}
				}
			}

			my $redurl = shift @lines;
			$is_debug && $log->debug("redirect: $redurl");
			$self->_fetchPL($redurl, $start);
			return;
		}

		if ($line =~ /#EXT-X-MEDIA-SEQUENCE:(\d+)/) {
			$is_debug && $log->debug("#EXT-X-MEDIA-SEQUENCE: $1");
			$chunknum = $1;
			next;
		}

		if ($line =~ /#EXT-X-ENDLIST/) {
			$is_debug && $log->debug("#EXT-X-ENDLIST");
			${*$self}{'_pl_noupdate'} = 1;
		}

		if ($line =~ /#EXTINF:(.*),/) {
			$duration += $1;
			$lastint  =  $1;

			my $chunkurl = shift @lines;

			if ($chunkurl !~ /^http:/) {
				# relative url
				$is_debug && $log->debug("relative url: $chunkurl");
				my ($urlbase) = $url =~ /(.*)\//;
				$chunkurl = $urlbase . "/" . $chunkurl;
				$is_debug && $log->debug("conveted to: $chunkurl");
			}

			if ($chunknum > ${*$self}{'_played'} && (!$start || !defined($duration) || $duration > $start)) {
				push @chunks, { url => $chunkurl, chunknum => $chunknum, len => $1 };
			}
			$chunknum++;
		}
	}

	if (${*$self}{'_pl_noupdate'} && $duration) {
		${*$self}{'song'}->duration($duration);
	}

	if ($log->is_info) {
		$log->info(sub { "existing chunks: [" . join(",", map { $_->{'chunknum'} } @{${*$self}{'_chunks'}}) . "]" });
		$log->info(sub { "new chunks: [" . join(",", map { $_->{'chunknum'} } @chunks) . "]" });
	}

	if (scalar @chunks) {

		if (scalar @{${*$self}{'_chunks'}} > 0) {
			
			# only add on chunks which and more recent than existing chunk list
			for my $new (@chunks) {
				if ($new->{'chunknum'} > ${*$self}{'_chunks'}->[-1]->{'chunknum'}) {
					push @{${*$self}{'_chunks'}}, $new;
				};
			}

			if ($log->is_info) {
				$log->info("merged chunklist now " . scalar @{${*$self}{'_chunks'}} . " chunks");
				$log->info(sub { "chunks: [" . join(",", map { $_->{'chunknum'} } @{${*$self}{'_chunks'}}) . "]" });
			}

		} else {

			# new chunklist - fetch initial chunks
			${*$self}{'_chunks'} = \@chunks;

			$is_debug && $log->debug("new chunklist " . scalar @chunks . " chunks");

			for my $i(0 .. PRE_FETCH) {
				$self->_fetchChunk($chunks[$i]) if $chunks[$i];
			}

			${*$self}{'song'}->owner->master->currentPlaylistUpdateTime(Time::HiRes::time());

		}
	}

	if (!${*$self}{'_pl_noupdate'}) {
		${*$self}{'_pl_refetch'} = time() + ($lastint || 10);
		${*$self}{'_pl_url'}     = $url;
	}
}

sub _fetchChunk {
	my $self  = shift;
	my $chunk = shift;

	if (my $url = $chunk->{'url'}) {
		$log->debug("fetching [$chunk->{chunknum}]: $url");
		$chunk->{'fetching'} = 1;
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$log->is_debug && $log->debug("got [$chunk->{chunknum}] size " . length($_[0]->content));
				delete $chunk->{'fetching'}; 
				$chunk->{'chunkref'} = $_[0]->contentRef;
			},
			sub { 
				$log->warn("error fetching [$chunk->{chunknum}] $url");
				delete $chunk->{'fetching'};
			}, 
		)->get($url);
	}
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

sub contentType { 'aac' }

sub formatOverride { 'aac' }

sub getIcon {
	my ($class, $url) = @_;

	my $handler;

	if ( ($handler = Slim::Player::ProtocolHandlers->iconHandlerForURL($url)) && ref $handler eq 'CODE' ) {
		return &{$handler};
	}
	
	return Plugins::BBCiPlayer::Plugin->_pluginDataFor('icon');
}

sub close {
	my $self = shift;
	${*$self}{'_close'} = 1;
}

sub sysread {
	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];

	if (${*$self}{'_close'}) {
		$log->debug("closing");
		return 0;
	}

	my $chunks = ${*$self}{'_chunks'};
	my $chunkref;
	my $ret = 0;

	if (scalar @$chunks) {
		$chunkref = $chunks->[0]->{'chunkref'};
	} elsif (${*$self}{'_pl_noupdate'}) {
		$log->debug("no chunks left - closing");
		return 0;
	}

	if ($chunkref) {

		$_[1] = "";
		my $nextpos = $chunks->[0]->{'nextpos'} ||= 0;

		while ($nextpos <= length($$chunkref) - 188 && length($_[1]) < $maxBytes - 188) {
			my $pre = unpack("N", substr($$chunkref, $nextpos, 4));
			my $pos = $nextpos + 4;
			$nextpos += 188;
			
			if ($pre & 0x00000020) {
				$pos += 1 + unpack("C", substr($$chunkref, $pos, 1));
			}
			if ($pre & 0x00400000) {
				my ($start, $optlen) = unpack("NxxxxC", substr($$chunkref, $pos, 9));
				if ($start == 0x000001c0) { 
					$pos += 9 + $optlen;
				} else {
					next;
				}
			}
			
			$_[1] .= substr($$chunkref, $pos, $nextpos - $pos);
			$ret  += $nextpos - $pos;
		}

		if ($nextpos >= length($$chunkref)) {
			my $played = shift @$chunks;
			${*$self}{'_played'} = $played->{'chunknum'};
			$log->is_info && $log->info("played [$played->{chunknum}]");
		} else {
			$chunks->[0]->{'nextpos'} = $nextpos;
		}
	
	}

	# refetch playlist if not a fixed list
	if (${*$self}{'_pl_refetch'} && time() > ${*$self}{'_pl_refetch'}) {
		$self->_fetchPL(${*$self}{'_pl_url'});
	}

	# fetch more chunks
	for my $i (0 .. PRE_FETCH) {
		my $new = $chunks->[$i];
		if ($new && !$new->{'chunkref'} && !$new->{'fetching'}) {
			$self->_fetchChunk($new);
			last;
		}
	}
	
	return $ret if $ret;

	# otherwise come back later - use EINTR as we don't have a file handle to put on select
	$! = EINTR;
	return undef;
}

1;
