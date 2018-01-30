package Plugins::BBCiPlayer::BBCXMLParser;

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

use Slim::Utils::Log;

use XML::Simple;
use Date::Parse;
use URI::Escape qw(uri_escape_utf8 uri_unescape);

my $log = logger('plugin.bbciplayer');

# split option string into options and filters
# valid options are:
# filter:<name>=<regexp> - filter to only include where <name> matches <regexp> 
# byday                  - include by day menus
# bykey                  - include menus grouped by brand/serial/title
# nocache                - don't cache parsed result [cacheing is per url so may need to turn off]
# reversedays            - list days in reverse order (use with byday)
# reverse                - list entries in reverse order (in list or by key display)

sub _getopts {
	my $class  = shift;
	my $optstr = shift;
	my $opts   = shift;
	my $filters= shift;

	for my $opt (split /\&/, $optstr) {
		if    ($opt =~ /filter:(.*)=(.*)/) { $filters->{lc($1)} = $2 }
		elsif ($opt =~ /(.*)=(.*)/       ) { $opts->{lc($1)}    = $2 } 
		else                               { $opts->{lc($opt)}  =  1 }
	}
}

sub parse {
    my $class  = shift;
    my $http   = shift;
	my $optstr = shift;

    my $params = $http->params('params');
    my $url    = $params->{'url'};
	my $opts   = {};
	my $filters= {};

	$class->_getopts($optstr, $opts, $filters);

	my $xml = eval {
		XMLin( 
			$http->contentRef,
			KeyAttr    => 'type',
			GroupTags  => { links => 'link', parents => 'parent' },
			ForceArray => [ 'parent' ]
		)
	};

	if ($@) {
		$log->error("$@");
		return;
	}

	my @weekdays = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);

	my $today = (localtime())[3];

	my %byDay;
	my %byKey;
	my %list;

	my %filter;

	# parse xml response into menu entries

	ENTRY: for my $entry (@{$xml->{'entry'}}) {

		my $title = $entry->{'title'};  

		# move info to top level of entry so we can filter on it
		$entry->{'url'} = $entry->{'links'}->{'content'};
		for my $info (keys %{$entry->{'parents'}}) {
			$entry->{ lc($info) } = $entry->{'parents'}->{ $info }->{'content'};
		}

		# filter out entries which don't match the filter criteria specified by $optstr
		for my $filter (keys %$filters) {
			if (!$entry->{$filter} || $entry->{$filter} !~ $filters->{$filter}) {
				$log->info("ignoring $title [$filter=$entry->{$filter} filter=$filters->{$filter}]");
				next ENTRY;
			}
		}

		my $now        = time();
		my $availStart = str2time($entry->{'availability'}->{'start'});
		my $availEnd   = str2time($entry->{'availability'}->{'end'});

		# don't include if the program is not available now (feed includes programs which can't be played)
		if ($availStart > $now || $availEnd < $now) {
			$log->info("ignoring $title [start=$availStart end=$availEnd now=$now]");
			next ENTRY;
		}

		my $start = str2time($entry->{'broadcast'}->{'start'});
		my $duration = $entry->{'broadcast'}->{'duration'};
		my ($min, $hour, $day, $wday) = (localtime($start))[1,2,3,6];

		# Strip dates from the title
		if ($title =~ /(.*?), \d+\/\d+\/\d+/) {
			$title = $1;
		}

		$log->is_info && $log->info("$title $weekdays[$wday] $hour:$min $entry->{url}");

		# group by key - brand/series/title
		my $key;
		if ($opts->{'bykey'}) {
			if    ($entry->{'brand'} ) { $key = $entry->{'brand'};  $filter{$key} = "?filter:brand=$key";  }
			elsif ($entry->{'series'}) { $key = $entry->{'series'}; $filter{$key} = "?filter:series=$key"; }
			else                       { $key = $title;             $filter{$key} = "?filter:title=$key";  }
		}

		my $icon = $entry->{'images'}->{'image'};

 		my $url = "iplayer://aod?hls=$entry->{url}&dur=$duration&icon=$icon&title=" . uri_escape_utf8($title) .
			"&desc=" . uri_escape_utf8($entry->{'synopsis'}) . "&icon=$icon";

		$byDay{$day}{$start} = {
			'name'        => sprintf("%02d:%02d %s", $hour, $min, $title),
			'url'         => $url,
			'icon'        => $icon,
			'type'        => 'audio',
			'description' => $entry->{'synopsis'},
		} if ($opts->{'byday'});

		$byKey{$key}{$start} = {
			'name'        => sprintf("%02d:%02d %s", $hour, $min, $day == $today ? 'Today' : $weekdays[$wday]),
			'url'         => $url,
			'icon'        => $icon,
			'type'        => 'audio',
			'description' => $entry->{'synopsis'},
		} if ($opts->{'bykey'});

		$list{$start} = {
			'name'        => sprintf("%02d:%02d %s - %s", $hour, $min, $day == $today ? 'Today' : $weekdays[$wday], $title),
			'url'         => $url,
			'icon'        => $icon,
			'type'        => 'audio',
			'description' => $entry->{'synopsis'},
		} unless ($opts->{'byday'} || $opts->{'bykey'});

	}

	# create menus

	my @menu;

	# create the by day menu
	if ($opts->{'byday'}) {

		my $first = $opts->{'reversedays'} ? $today : ($today - 15) % 32;
		my $day = $first;

		do {
			my @submenu;
			my $wday;

			my @times = sort keys %{$byDay{$day}};
			
			for my $time (@times) {
				push @submenu, $byDay{$day}{$time};
				$wday ||= (localtime($time))[6];
			}

			if (@submenu) {
				push @menu, {
					'name'  => $day == $today ? 'Today' : $weekdays[$wday],
					'items' => \@submenu,
					'icon'  => Plugins::BBCiPlayer::Plugin->_pluginDataFor('icon'),
					'type'  => 'opml',
				};
			}
			
			$day = $opts->{'reversedays'} ? ($day - 1) % 32 : ($day + 1) % 32;
			
		} while ($day != $first);
	}

	# create the by brand/series/title menu entries, promoting single entrys to top level
	if ($opts->{'bykey'}) {

		for my $key (sort keys %byKey) {

			my @times = $opts->{'reverse'} ? reverse sort keys %{$byKey{$key}} : sort keys %{$byKey{$key}};

			if (scalar @times == 1) {

				# only one entry of this title - put it at the top level
				$byKey{$key}{$times[0]}->{'name'} = $key;
				push @menu, $byKey{$key}{$times[0]};
				
			} else {
				
				my @submenu;
				my $icon = Plugins::BBCiPlayer::Plugin->_pluginDataFor('icon');
				
				# create sub menu ordered by start date
				for my $time (@times) {
					push @submenu, $byKey{$key}{$time};
					$icon = $byKey{$key}{$time}->{'icon'} if $byKey{$key}{$time}->{'icon'};
				}
				
				push @menu, {
					'name'    => $key,
					'items'   => \@submenu,
					'type'    => 'opml',
					'icon'    => $icon,
					# add info to allow this menu to be bookmarked as a favorite
					# - fetched means it is not fetched again while browsing into this menu
					'url'     => "$url?$key",
					'parser'  => 'Plugins::BBCiPlayer::BBCXMLParser' . $filter{$key},
					'fetched' => 1,
				};
			}
		}
	}

	# add in list entries (if byday, bykey not used)
	my @times = $opts->{'reverse'} ? reverse sort keys %list : sort keys %list;
	
	for my $time (@times) {
		push @menu, $list{$time};
	}

	# return xmlbrowser hash
	return {
		'name'    => $params->{'feedTitle'},
		'items'   => \@menu,
		'type'    => 'opml',
		'nocache' => $opts->{'nocache'},
	};
}

1;
