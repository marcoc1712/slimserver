#!/usr/bin/perl
#
# This program is part of the C-3PO Plugin. 
# See Plugin.pm for credits, license terms and others.
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
#########################################################################

package Plugins::Recorder::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Digest::MD5 qw(md5_hex);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Data::Dump qw(dump);

my $prefs = preferences('plugin.recorder');
my $log   = logger('plugin.recorder');

my $plugin;

sub new {
	my $class = shift;
	$plugin   = shift;

	$class->SUPER::new;
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RECORDER');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/recorder/settings/basic.html');
}
sub prefs {
	return ($prefs, qw(mac codec directory prefix suffix logfile elementSize elementCount delay));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug('Settings - handler');	
	}
	if ($params->{'saveSettings'}){
	
		$class->SUPER::handler( $client, $params );
		$prefs->writeAll();
		$prefs->savenow();
		$plugin->settingsChanged();
	}
	
	return $class->SUPER::handler( $client, $params );
}
1;