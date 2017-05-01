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

package Plugins::Recorder::DataStore;

use strict;
use warnings;
use Data::Dump qw(dump);

use utf8; 
use JSON::PP;

sub new{
    my $class 	= shift;
    my $file    = shift;
    my $default = shift;

    my $self = bless {
                file => $file,
                default => $default,
                error => undef,
                data => {},
             }, $class;

    $self->_readJSON();       
    return $self;
}

sub get{
    my $self = shift;

    if ($self->getError() || ! $self->{data}) {return undef;}
    return $self->{data};
}

sub write{
    my $self     	= shift;
    my $inRef 		= shift;
   
    if (! $inRef){ $inRef = $self->get();}
   
    if ($self->_writeJSON($inRef)){

        $self->_readJSON();	
        return 1;
    }
    return undef;
}

sub getError{
    my $self	= shift;
    return  $self->{error};
}
################################################################################
#
################################################################################
sub _writeJSON{
    my $self   = shift;
    my $data   = shift;
    
    my $file   =  $self->{file};

    my $json = JSON::PP->new;
   
    my $json_txt =  $json->pretty->encode($data);
    #my $json_txt = encode_json $data;
    
    my $fh;
    if (! open($fh, '>', $file)) {
        $self->{error} = ("ERROR: Failure opening '$file' - $!");
        return 0;
    }
    
    #print $fh header('application/json');
    print $fh $json_txt;
    
    close $fh;

}
sub _readJSON{
    my $self 	= shift;
    
    my $file = $self->{file};
    
    if ((! -e $file) || ! -r $file) {

        $self->{data}= $self->{default};
        $self->{error} = undef; 
 
        return 1
    }
    my $result="";
    if (open(my $fh, '<', $file)) {
        while (my $row = <$fh>) {
            chomp $row;
            $result = $result." ".$self->_trim($row);
        }
    } else{
        
        $self->{error} = ("ERROR: Failure reading $file - $!");
        return 0;
    } 
    my $json = JSON::PP->new;
    $self->{data} = $json->decode($result);
    $self->{error} = undef;

    return 1;
}

sub _trim{
	my $class = shift;
	my ($val) = shift;

  	if (defined $val) {

    	$val =~ s/^\s+//; # strip white space from the beginning
    	$val =~ s/\s+$//; # strip white space from the end
		
    }
    
    return $val || '';         
}
1;