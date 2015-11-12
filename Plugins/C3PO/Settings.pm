package Plugins::C3PO::Settings;

# See plugin.pm for description and terms of use.

use strict;
use base qw(Slim::Web::Settings);

use Digest::MD5 qw(md5_hex);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

require Plugins::C3PO::Shared;

my $prefs = preferences('plugin.C3PO');
my $log   = logger('plugin.C3PO');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_C3PO_MODULE_NAME');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/C3PO/settings/basic.html');
}

sub prefs {
	return ($prefs, Plugins::C3PO::Shared::getSharedPrefNameList());		  
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	return $class->SUPER::handler( $client, $params );
}
1;