package Plugins::BBCiPlayer::Settings;

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

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return 'PLUGIN_BBCIPLAYER';
}

sub page {
	return 'plugins/BBCiPlayer/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.bbciplayer'), qw(prefOrder_live prefOrder_aod transcode
												 radiovis_txt radiovis_slide livetxt_classic_line 
												 is_app));
}

sub beforeRender {
	my $class = shift;
	my $params= shift;

	if ($params->{'prefs'}->{'pref_prefOrder_live'} =~ /flash/ || $params->{'prefs'}->{'pref_prefOrder_aod'} =~ /flash/) {
		require Plugins::BBCiPlayer::RTMP;
	}

	$params->{'show_app'} = Slim::Plugin::Base->can('nonSNApps');

	my %fmtmap = (
		hls      => 'HLS',
		mp3      => 'MP3',
		flashaac => 'FlashAAC',
		flashmp3 => 'FlashMP3',
	);

	my @opts = (
		'hls,mp3,flashaac,flashmp3',
		'hls,mp3',
		'hls',
	);

	my @prefOpts = ();

	for my $opt (@opts) {
		push @prefOpts, { opt => $opt, disp => join(" > ", map { $fmtmap{$_} } split(/,/, $opt)) };
	}

	$params->{'opts'} = \@prefOpts;
}

1;
