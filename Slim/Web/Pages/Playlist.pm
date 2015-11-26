package Slim::Web::Pages::Playlist;

# $Id$

# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use File::Spec::Functions qw(:ALL);
use POSIX ();
use Scalar::Util qw(blessed);
use Tie::Cache::LRU::Expires;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Web::Pages;
use Slim::Utils::Prefs;

my $log = logger('player.playlist');

my $prefs = preferences('server');

use constant CACHE_TIME => 300;

tie my %albumCache, 'Tie::Cache::LRU::Expires', EXPIRES => 5, ENTRIES => 5;

sub init {
	
	Slim::Web::Pages->addPageFunction( qr/^playlist\.(?:htm|xml)/, \&playlist );
}

sub playlist {
	my ($client, $params, $callback, $httpClient, $response) = @_;
	
	if (!defined($client)) {

		# fixed faster rate for noclients
		$params->{'playercount'} = 0;
		return Slim::Web::HTTP::filltemplatefile("playlist.html", $params);
	
	} elsif ($client->needsUpgrade() && !$client->isUpgrading()) {

		$params->{'player_needs_upgrade'} = '1';
		return Slim::Web::HTTP::filltemplatefile("playlist_needs_upgrade.html", $params);
	}
	
	# If synced, use the master's playlist
	$client = $client->master();

	$params->{'playercount'} = Slim::Player::Client::clientCount();
	
	my $songcount = Slim::Player::Playlist::count($client);

	$params->{'playlist_items'} = '';
	$params->{'skinOverride'} ||= '';
	
	my $count = $prefs->get('itemsPerPage');

	unless (defined($params->{'start'}) && $params->{'start'} ne '') {

		$params->{'start'} = (int(Slim::Player::Source::playingSongIndex($client)/$count)*$count);
	}

	if ($client->currentPlaylist() && !Slim::Music::Info::isRemoteURL($client->currentPlaylist())) {
		$params->{'current_playlist'} = $client->currentPlaylist();
		$params->{'current_playlist_modified'} = $client->currentPlaylistModified();
		$params->{'current_playlist_name'} = Slim::Music::Info::standardTitle($client,$client->currentPlaylist());
	}

	if (main::DEBUGLOG && $log->is_debug && $client->currentPlaylistRender() && ref($client->currentPlaylistRender()) eq 'ARRAY') {

		$log->debug("currentPlaylistChangeTime : " . localtime($client->currentPlaylistChangeTime()));
		$log->debug("currentPlaylistRender     : " . localtime($client->currentPlaylistRender()->[0]));
		$log->debug("currentPlaylistRenderSkin : " . $client->currentPlaylistRender()->[1]);
		$log->debug("currentPlaylistRenderStart: " . $client->currentPlaylistRender()->[2]);

		$log->debug("skinOverride: $params->{'skinOverride'}");
		$log->debug("start: $params->{'start'}");
	}

	# Only build if we need to - try to return cached html or build page from cached info
	my $cachedRender = $client->currentPlaylistRender();

	if ($songcount > 0 && 
		defined $params->{'skinOverride'} &&
		defined $params->{'start'} &&
		$cachedRender && ref($cachedRender) eq 'ARRAY' &&
		$client->currentPlaylistChangeTime() &&
		$client->currentPlaylistChangeTime() < $cachedRender->[0] &&
		$cachedRender->[1] eq $params->{'skinOverride'} &&
		$cachedRender->[2] eq $params->{'start'} ) {

		if ($cachedRender->[5]) {

			main::INFOLOG && $log->info("Returning cached playlist html - not modified.");

			# reset cache timer to forget cached html
			Slim::Utils::Timers::killTimers($client, \&flushCachedHTML);
			Slim::Utils::Timers::setTimer($client, time() + CACHE_TIME, \&flushCachedHTML);

			return $cachedRender->[5];

		} else {

			main::INFOLOG && $log->info("Rebuilding playlist from cached params.");

			if (Slim::Utils::Misc::getPlaylistDir() && !Slim::Music::Import->stillScanning()) {
				$params->{'cansave'} = 1;
			}

			$params->{'playlist_items'}   = $cachedRender->[3];
			$params->{'pageinfo'}         = $cachedRender->[4];

			return Slim::Web::HTTP::filltemplatefile("playlist.html", $params);
		}
	}

	if (!$songcount) {
		return Slim::Web::HTTP::filltemplatefile("playlist.html", $params);
	}

	my $item;
	my %form;

	if (Slim::Utils::Misc::getPlaylistDir() && !Slim::Music::Import->stillScanning()) {
		$params->{'cansave'} = 1;
	}
	
	$params->{'pageinfo'} = Slim::Web::Pages::Common->pageInfo({
				'itemCount'    => $songcount,
				'currentItem'  => Slim::Player::Source::playingSongIndex($client),
				'path'         => $params->{'webroot'} . $params->{'path'},
				'otherParams'  => "&player=" . Slim::Utils::Misc::escape($client->id()),
				'start'        => $params->{'start'},
				'perPage'      => $params->{'itemsPerPage'},
	});
	
	my ($start,$end);
	$start = $params->{'start'} = $params->{'pageinfo'}{'startitem'};
	$end = $params->{'pageinfo'}{'enditem'};
	
	my $offset = $start % 2 ? 0 : 1; 

	my $currsongind   = Slim::Player::Source::playingSongIndex($client);

	my $itemsPerPage = $prefs->get('itemsPerPage');
	my $composerIn   = $prefs->get('composerInArtists');

	my $titleFormat  = Slim::Music::Info::standardTitleFormat();

	$params->{'playlist_items'} = [];
	$params->{'myClientState'}  = $client;

	# This is a hot loop.
	# But it's better done all at once than through the scheduler.
	my $totalDuration = 0;
	my $itemnum = 0;

	my $shuffled = Slim::Player::Playlist::shuffleList($client);
	my $playlist = Slim::Player::Playlist::playList($client);
	
	$playlist = [ @$playlist[@$shuffled] ] if scalar @$shuffled;

	foreach my $objOrUrl ( @$playlist ) {
		# These should all be objects - but be safe.
		my $track    = $objOrUrl;

		if (!blessed($objOrUrl) || !$objOrUrl->can('id')) {

			$track = Slim::Schema->objectForUrl($objOrUrl) || do {

				logError("Couldn't retrieve objectForUrl: [$objOrUrl] - skipping!");
				next;
			};
		}

		my %form = ();
		
		# See if a protocol handler can provide more metadata
		my $handler = $track->remote ? Slim::Player::ProtocolHandlers->handlerForURL( $track->url ) : undef;
		if ( $handler && $handler->can('getMetadataFor') ) {
			$form{'plugin_meta'} = $handler->getMetadataFor( $client, $track->url );
			
			# Only use cover if it's a full URL
			if ( $form{'plugin_meta'}->{'cover'} && $form{'plugin_meta'}->{'cover'} !~ /^http/ ) {
				delete $form{'plugin_meta'}->{'cover'};
			}
		}

		my $duration;

		$duration = $form{'plugin_meta'}->{duration} if $form{'plugin_meta'};
		$duration ||= $track->secs || 0;
		$totalDuration += $duration;


		if ($itemnum >= $start && $itemnum <= $end) {
	
			$track->displayAsHTML(\%form);
	
			$form{'num'}       = $itemnum;
			$form{'levelName'} = 'track';
			$form{'odd'}       = ($itemnum + $offset) % 2;
			
			if ( !$form{'coverid'} && !$form{'artwork_track_id'} ) {
				$form{'artwork_track_id'} = $form{'album'}->{'artwork'} if $form{'album'};

				my $albumId;
				if (!$form{'artwork_track_id'}) {
					$albumId = $track->albumid;
					$form{'artwork_track_id'} = $albumCache{$albumId};
				}
				
				if (!$form{'artwork_track_id'}) {
					my $sth = Slim::Schema->dbh->prepare_cached("SELECT artwork FROM albums WHERE id = ?");
					
					$sth->execute($albumId);
					
					($form{'artwork_track_id'}) = $sth->fetchrow_array;
					
					$sth->finish;

					$albumCache{$albumId} = $form{'artwork_track_id'};
				}
			}
			
			if ($itemnum == $currsongind) {
				$form{'currentsong'} = "current";
	
				if ( Slim::Music::Info::isRemoteURL( $track->url ) ) {
					# For remote streams, add both the current title and the station title if they differ
					$form{'title'}    = Slim::Music::Info::standardTitle(undef, $track, $form{'plugin_meta'}, $titleFormat) || $track->url;
					my $title_only    = Slim::Music::Info::standardTitle(undef, $track, $form{'plugin_meta'}, 'TITLE');
					my $current_title = Slim::Music::Info::getCurrentTitle($client, $track->url, 'web', $form{'plugin_meta'});
					if ( $current_title && $current_title ne $form{'title'} && $current_title ne $title_only ) {
						$form{'current_title'} = $current_title;
					}
				} else {
					$form{'title'} = Slim::Music::Info::standardTitle(undef, $track, $form{'plugin_meta'}) || $track->url;
				}
	
			} else {
	
				$form{'currentsong'} = undef;
				$form{'title'}    = $form{text} || Slim::Music::TitleFormatter::infoFormat($track, $titleFormat, undef, $form{'plugin_meta'});
			}
			
			# Volatile tracks are not really remote streams. They're always a bit different.
			# I don't like that, but we need to override the plugin_meta's
			$form{'plugin_meta'}->{'title'} = $form{'title'} if $form{'plugin_meta'} && Slim::Music::Info::isVolatileURL($track->url);
			
			$form{'nextsongind'} = $currsongind + (($itemnum > $currsongind) ? 1 : 0);
	
			push @{$params->{'playlist_items'}}, \%form;
		}

		$itemnum++;

		# don't neglect the streams too long
		main::idleStreams() if !($itemnum % 5);
	}

	$params->{'pageinfo'}->{'totalDuration'} = Slim::Utils::DateTime::timeFormat($totalDuration) if $totalDuration;

	main::INFOLOG && $log->info("End playlist build.");

	my $page = Slim::Web::HTTP::filltemplatefile("playlist.html", $params);

	if ($client) {

		# Cache to reduce cpu spike seen when playlist refreshes
		# For the moment cache html for Classic, other skins only cache params
		# Later consider caching as html unless an ajaxRequest
		# my $cacheHtml = !$params->{'ajaxRequest'};
		my $cacheHtml = (($params->{'skinOverride'} || $prefs->get('skin')) eq 'Classic');

		my $time = time();

		$client->currentPlaylistRender([
			$time,
			($params->{'skinOverride'} || ''),
			($params->{'start'}),
			$params->{'playlist_items'},
			$params->{'pageinfo'},
			$cacheHtml ? $page : undef,
		]);

		if ( main::INFOLOG && $log->is_info ) {
			$log->info( sprintf("Caching playlist as %s.", $cacheHtml ? 'html' : 'params') );
		}

		Slim::Utils::Timers::killTimers($client, \&flushCachedHTML);

		if ($cacheHtml) {
			Slim::Utils::Timers::setTimer($client, $time + CACHE_TIME, \&flushCachedHTML);
		}
	}

	return $page;
}

sub flushCachedHTML {
	my $client = shift;

	main::INFOLOG && $log->info("Flushing playlist html cache for client.");
	$client->currentPlaylistRender(undef);
}

1;

__END__
