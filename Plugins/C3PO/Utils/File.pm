#!/usr/bin/perl
#
# @File File.pm
# $Id$
#
# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, version 2

# This code originally lived in slimserver.pl - but with other programs
# needing to use the same @INC, was broken out into a separate package.
#
# 2005-11-09 - dsully

# Modified by Marco Curti <marcoc1712@gmail.com>
# @Created 1-nov-2015 23.53.58
#

package Utils::File;

use strict;

#use File::Spec::Functions;

sub getAncestor{
	my $folder=shift;
	my $lev=shift || 1;
	
	#print $folder."\n";
	
	my ($volume,$directories,$file) =
                       File::Spec->splitpath( $folder, 1 );
	
	my @dirs = File::Spec->splitdir( $directories );

	my $dirs= @dirs;

	@dirs= splice @dirs, 0, $lev*-1;

	return File::Spec->catfile($volume, File::Spec->catdir( @dirs ), $file);
}
sub getParentFolder{
	my $folder=shift;
	return getAncestor($folder,1);
}
1;