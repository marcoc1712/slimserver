package Slim::Player::CapabilitiesHelper;

# $Id$

# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use Slim::Utils::Log;

my $log = logger('player.source');

sub samplerateLimit {
	my $song     = shift;
	
	my $srate = $song->currentTrack()->samplerate;
	
	main::DEBUGLOG && $log->is_debug && $log->debug("current sample rate: $srate");
	
	return undef if ! $srate;

	my $maxRate = 0;
	
	foreach ($song->master()->syncGroupActiveMembers()) {
		my $rate = $_->maxSupportedSamplerate();
		
		main::DEBUGLOG && $log->is_debug && $log->debug(" detected max sample rate: $rate");
		
		if ($rate && ($maxRate && $maxRate > $rate || !$maxRate)) {
			$maxRate = $rate;
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug(" minimum max sample rate: $maxRate");
	
	if ($maxRate && $maxRate < $srate) {
		if (($maxRate % 12000) == 0 && ($srate % 11025) == 0) {
			$maxRate = int($maxRate * 11025 / 12000);
		}
		main::INFOLOG && $log->is_info && $log->info("returned max sample rate: $maxRate");
		return $maxRate;
	}
	
	return undef;
}

sub supportedFormats {
	my $client = shift;
	
	my @supportedformats = ();
	my %formatcounter    = ();

	my @playergroup = $client->syncGroupActiveMembers();

	foreach my $everyclient (@playergroup) {
		foreach my $supported ($everyclient->formats()) {
			$formatcounter{$supported}++;
		}
	}
	
	foreach my $testformat ($client->formats()) {
		if (($formatcounter{$testformat} || 0) == @playergroup) {
			push @supportedformats, $testformat;
		}
	}
	
	return @supportedformats;
}

1;

__END__