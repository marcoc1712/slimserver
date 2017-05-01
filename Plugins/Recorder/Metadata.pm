#!/usr/bin/perl
# $Id$
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

package Plugins::Recorder::Metadata;

use strict;
use warnings;

use Data::Dump qw(dump);
use Time::Local;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Buttons::Playlist;
use Slim::Player::ProtocolHandlers;
use Slim::Music::Info;

use Plugins::Recorder::DataStore;

my $prefs = preferences('plugin.recorder');
my $log   = logger('plugin.recorder');

################################################################################
# 
################################################################################
sub new{   
    my $class    = shift;
    my $client   = shift;
    my $file     = shift || undef;
    
    my $timeString = _getTimeString();
    
    my $self = bless {
        _player     => $client->id(),
    }, $class;
    
    if (!$file){
        
        $self->_init($client);
        
        my $filename = "ind_".$timeString.".dat";
        my $base = $prefs->get('directory');
        
        $self->{_file} = File::Spec->catfile( $base, $filename );
        $self->{_time} = $timeString;

        $self->_write();

    } else {
        
        $self->{_file} = $file;
        my $name = File::Basename::basename($file);
        $self->{_time} = substr($name,4,15);
       
        $self->_load();
        
    }
        
    return $self;
}
################################################################################
#
################################################################################
sub getTitle{
    my $self = shift;
    
    return $self->{_title};
}
sub getArtist{
    my $self = shift;
    
    return $self->{_artist};
}
sub getAlbum{
    my $self = shift;
    
    return $self->{_album};
}
sub getTrackNo{
    my $self = shift;
    
    return $self->{_track};
}
sub getYear{
    my $self = shift;
    
    return $self->{_year};
}
sub getPlayer{
    my $self = shift;
    
    return $self->{_player};
}
sub getTime{
    my $self = shift;
    
    return $self->{_time};
}
sub getFile{
    my $self = shift;
    
    return $self->{_file};
}
################################################################################
#
################################################################################

sub _init{
    my $self = shift;
    my $client = shift;
    
    my $index           = Slim::Buttons::Playlist::browseplaylistindex($client);
    
    $self->{_song}      = Slim::Player::Playlist::song($client,  $index);
    $self->{_isRemote}  = $self->{_song}->isRemoteURL;
    $self->{_track}     = $index+1;
    
    my $meta;
    
    if ( $self->{_isRemote} ) {
        my $handler = Slim::Player::ProtocolHandlers->handlerForURL($self->{_song}->url);

        if ( $handler && $handler->can('getMetadataFor') ) {
            $meta = $handler->getMetadataFor( $client, $self->{_song}->url );
            
            if ( $meta->{title} ) {
                $self->{_title} = Slim::Music::Info::getCurrentTitle( $client, $self->{_song}->url, 0, $meta );
            }
        }
    }

    
    if ( !$self->{_title} ) {
        $self->{_title} = Slim::Music::Info::standardTitle($client, $self->{_song});
    }
    
    if ( $self->{_song} && ! $self->{_isRemote}) {
 
        $self->{_album}  = Slim::Music::Info::displayText($client, $self->{_song}, 'ALBUM');
        $self->{_artist} = Slim::Music::Info::displayText($client, $self->{_song}, 'ARTIST');
        $self->{_year}   = Slim::Music::Info::displayText($client, $self->{_song}, 'YEAR');
    
    } elsif (  $self->{_song} && $meta) {

        $self->{_album}  = Slim::Music::Info::displayText($client, $self->{_song}, 'ALBUM', $meta);
        $self->{_artist} = Slim::Music::Info::displayText($client, $self->{_song}, 'ARTIST', $meta);
        $self->{_year}   = Slim::Music::Info::displayText($client, $self->{_song}, 'YEAR', $meta);
    } 
    
    return 1;
}

sub _load{
    my $self = shift;
    
    my $file = $self->{_file};
    my $datastore= Plugins::Recorder::DataStore->new($file,undef);
    my $meta = $datastore->get();
    my $error = $datastore->getError();
    if (!$meta && $error){
        
        $log->warn ("$error");
        return 0;
    }

    $self->{_title}  = $meta->{title};
    $self->{_album}  = $meta->{album};
    $self->{_artist} = $meta->{artist};
    $self->{_year}   = $meta->{year};
    $self->{_track}  = $meta->{track};
    
    return 1;
}
sub _write {
    my $self = shift;
    
    my $meta=();
    
    $meta->{player}      = $self->{_player};
    $meta->{'time'}      = $self->{_time};
    $meta->{title}       = $self->{_title};
    $meta->{album}       = $self->{_album};
    $meta->{artist}      = $self->{_artist};
    $meta->{year}        = $self->{_year};
    $meta->{track}       = $self->{_track};
    
    my $datastore= Plugins::Recorder::DataStore->new($self->{_file}, $meta);
    if (!$datastore->write($meta)){
        $log->warn ($datastore->getError());
        return 0;
    }
   
    return 1;
}
sub _getTimeString {
    my $time = shift || time;
    
    return POSIX::strftime('%Y%m%d_%H%M%S', localtime($time));
    
}
1;