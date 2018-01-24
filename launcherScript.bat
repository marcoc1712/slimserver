setlocal
set ipaddr=192.168.1.110
set server=F:\\Sviluppo\\slimserver\\slimserver.pl
set squeezedir="C:\\ProgramData\\Squeezebox"
set prefsdir=%squeezedir%\\prefs
set cachedir=%squeezedir%\\cache
set logdir=%squeezedir%\\logs
cmd.exe /c ""C:\\Perl\\bin\\perl.exe" "%server%" --playeraddr %ipaddr% --streamaddr %ipaddr% --httpaddr %ipaddr% --cliaddr %ipaddr% --prefsdir "%prefsdir%" --cachedir "%cachedir%" --logdir "%logdir%""
 