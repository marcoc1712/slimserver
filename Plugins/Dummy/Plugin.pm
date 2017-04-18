#!/usr/bin/perl
# $Id$
#
# Handles server side file type conversion and resampling.
# Replace custom-convert.conf.
#
# To be used mainly with Squeezelite-R2 
# (https://github.com/marcoc1712/squeezelite/releases)
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
################################################################################

package Plugins::Dummy::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

if ( main::WEBUI ) {
	require Plugins::Dummy::Settings;
}

my $class;
my $preferences = preferences('plugin.dummy');
my $serverPreferences = preferences('server');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.dummy',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_DUMMY',
} );

#
###############################################
## required methods

sub getDisplayName {
	return 'PLUGIN_DUMMY';
}
	
sub initPlugin {
	$class = shift;

	$class->SUPER::initPlugin(@_);
	
	if (main::INFOLOG && $log->is_info) {
		$log->info('initPlugin');
	}

	if ( main::WEBUI ) {
		Plugins::Dummy::Settings->new($class);
	}

	$preferences->init({
			text			    => "",
			slider				=> 5,
			checkbox			=> undef,
			select				=> "A",
            flags               => { a => 'on',
                                     b => undef,
                                     c => 'on',
                                     d => undef,
                                     e =>  'on',
                                     f => undef,  
                                },
	});
	
}

sub settingsChanged{
	my $class = shift;
		
	if (main::DEBUGLOG && $log->is_debug) {	
			$log->debug('settings saved');
	}
}

1;
