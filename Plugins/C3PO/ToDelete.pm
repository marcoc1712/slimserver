# $Id$

# This program is part of the C-3PO Plugin. 
#
# See Plugin.pm for credits, license terms and others.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
package Plugins::C3PO::ToDelete;

use strict;

use Data::Dump;
use File::Spec::Functions qw(:ALL);

sub start{
	my $options=shift;
	my $prefs=shift;


}
#The LMS way.
sub pipeCommand{
	my $command=shift;
	
	Plugins::C3PO::Logger::debugMessage(qq(INFO: Command is: $command));

	my $pipeline;
	if (main::ISWINDOWS) {
	
		#Win32::SetChildShowWindow(0);
		$pipeline = FileHandle->new;
		my $pid = $pipeline->open($command);

		#main::INFOLOG && $log->info('Use pipeline In WINDOWS (FileHandle): command', $command);

		# XXX Bug 15650, this sets the priority of the cmd.exe process but not the actual
		# transcoder process(es).
		#my $handle;
		#if ( Win32::Process::Open( $handle, $pid, 0 ) ) {
		#	$handle->SetPriorityClass( Slim::Utils::OS::Win32::getPriorityClass() || Win32::Process::NORMAL_PRIORITY_CLASS() );
		#}

		#Win32::SetChildShowWindow();
	} else {
		$pipeline = FileHandle->new($command);
		#main::INFOLOG && $log->info('Use pipeline (FileHandle): command', $command);
	}

}
#return the command to shell.
sub returnCommand{
	my $command=shift;
	
	Plugins::C3PO::Logger::debugMessage(qq(INFO: Command is: $command));
	
	print STDOUT ($command);
	exit;
}
1;

