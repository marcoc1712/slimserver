package Plugins::BBCiPlayer::Plugin;

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

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(:ALL);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::BBCiPlayer::iPlayer;
use Plugins::BBCiPlayer::RTMP;
use Plugins::BBCiPlayer::HLS;

my $prefs = preferences('plugin.bbciplayer');

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.bbciplayer',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.bbciplayer.rtmp',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.bbciplayer.hls',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.bbciplayer.livetxt',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

$prefs->migrate(2, sub {
	$prefs->set('prefOrder_live', 'hls,mp3,flashaac,flashmp3');
	$prefs->set('prefOrder_aod', 'hls,mp3,flashaac,flashmp3');
	1;
});

sub initPlugin {
	my $class = shift;

	$prefs->init({ prefOrder_live => 'hls,mp3,flashaac,flashmp3', prefOrder_aod => 'hls,mp3,flashaac,flashmp3',
				   transcode => 1, radiovis_txt => 1, radiovis_slide => 0, livetxt_classic_line => 0, is_app => 0 });

	my $file = catdir( $class->_pluginDataFor('basedir'), 'menu.opml' );

	$class->SUPER::initPlugin(
		feed   => Slim::Utils::Misc::fileURLFromPath($file),
		tag    => 'bbciplayer',
		is_app => $class->can('nonSNApps') && $prefs->get('is_app') ? 1 : undef,
		menu   => 'radios',
		weight => 1,
	);

	if (!$::noweb) {
		require Plugins::BBCiPlayer::Settings;
		Plugins::BBCiPlayer::Settings->new;
	}

	# hide iplayer:// and hls:// urls from track info displays...
	my $trackInfoUrl = Slim::Menu::TrackInfo->getInfoProvider->{'url'};
	my $old = $trackInfoUrl->{'func'};

	$trackInfoUrl->{'func'} = sub {
		my $info = &$old(@_);
		return undef if $info->{'label'} eq 'URL' && $info->{'name'} =~ /^iplayer:\/\/|^hls:\/\//;
		return $info;
	};
}

sub getDisplayName { 'PLUGIN_BBCIPLAYER' }

sub playerMenu { shift->can('nonSNApps') && $prefs->get('is_app') ? undef : 'RADIO' }

1;
