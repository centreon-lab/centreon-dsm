#! /usr/bin/perl
################################################################################
# Copyright 2005-2009 MERETHIS
# Centreon is developped by : Julien Mathis and Romain Le Merlus under
# GPL Licence 2.0.
# 
# This program is free software; you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation ; either version 2 of the License.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A 
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with 
# this program; if not, see <http://www.gnu.org/licenses>.
# 
# Linking this program statically or dynamically with other modules is making a 
# combined work based on this program. Thus, the terms and conditions of the GNU 
# General Public License cover the whole combination.
# 
# As a special exception, the copyright holders of this program give MERETHIS 
# permission to link this program with independent modules to produce an executable, 
# regardless of the license terms of these independent modules, and to copy and 
# distribute the resulting executable under terms of MERETHIS choice, provided that 
# MERETHIS also meet, for each linked independent module, the terms  and conditions 
# of the license of that module. An independent module is a module which is not 
# derived from this program. If you modify this program, you may extend this 
# exception to your version of the program, but you are not obliged to do so. If you
# do not wish to do so, delete this exception statement from your version.
# 
# For more information : contact@centreon.com
# 
# SVN : $URL$
# SVN : $Id$
#
####################################################################################

use strict;
use DBI;
use File::Path qw(mkpath);
use vars qw($mysql_database_oreon $mysql_database_ods $mysql_host $mysql_user $mysql_passwd $ndo_conf $LOG $NAGIOSCMD $CECORECMD $LOCKDIR $MAXDATAAGE);

$LOG = "/var/lib/centreon/trap-dynamic.log";

$NAGIOSCMD = "/usr/local/nagios/var/rw/nagios.cmd";
$CECORECMD = "/var/lib/centreon/centcore.cmd";

$LOCKDIR = "/var/lib/centreon/tmp/";
$MAXDATAAGE = 60;

#require "@CENTREON_ETC@/conf.pm";
require "/etc/centreon/conf.pm";

# log files management function
sub writeLogFile($){
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time());
    open (LOG, ">> ".$LOG) || print "can't write $LOG: $!";

    # Add initial 0 if value is under 10
    $hour = "0".$hour if ($hour < 10);
    $min = "0".$min if ($min < 10);
    $sec = "0".$sec if ($sec < 10);
    $mday = "0".$mday if ($mday < 10);
    $mon += 1;
    $mon = "0".$mon if ($mon < 10);

    print LOG "$mday/$mon/".($year+1900)." $hour:$min:$sec - ".$_[0]."\n";
    close LOG or warn $!;
}

# Set arguments
my $host_name = $ARGV[0];
my $output = $ARGV[2];
my $timeRequest = $ARGV[1];

my $dbh = DBI->connect("dbi:mysql:".$mysql_database_oreon.";host=".$mysql_host, $mysql_user, $mysql_passwd) or die "Data base connexion impossible : $mysql_database_oreon => $! \n";

# Connect to NDO databases
my $sth2 = $dbh->prepare("SELECT db_host,db_name,db_port,db_prefix,db_user,db_pass FROM cfg_ndo2db");
if (!$sth2->execute) {
    writeLogFile("Error when getting drop and perfdata properties : ".$sth2->errstr."");
}
$ndo_conf = $sth2->fetchrow_hashref();
undef($sth2);

my $dbh2 = DBI->connect("dbi:mysql:".$ndo_conf->{'db_name'}.";host=".$ndo_conf->{'db_host'}, $ndo_conf->{'db_user'}, $ndo_conf->{'db_pass'});
if (!defined($dbh2)) {
    print "ERROR : ".$DBI::errstr."\n";
    print "Data base connexion impossible : ".$ndo_conf->{'db_name'}." => $! \n";
}

# Get module trap on this host
my $confDSM;
$sth2 = $dbh->prepare("SELECT pool_prefix FROM mod_dsm_pool mdp, host h WHERE mdp.pool_host_id = h.host_id AND h.host_name LIKE '".$ARGV[0]."'");
if (!defined($sth2)) {
    print "ERROR : ".$DBI::errstr."\n";
}
if ($sth2->execute()){
    $confDSM = $sth2->fetchrow_hashref();
} else {
    print "Can get DSM informations $!\n";
    exit(1);
}

# Get slot free
my $request = "SELECT no.name1, no.name2 ".
    "FROM ".$ndo_conf->{'db_prefix'}."servicestatus nss , ".$ndo_conf->{'db_prefix'}."objects no, ".$ndo_conf->{'db_prefix'}."services ns ".
    "WHERE no.object_id = nss.service_object_id AND no.name1 like '".$ARGV[0]."' AND no.object_id = ns.service_object_id ".
    "AND nss.current_state = 0 AND no.name2 LIKE '".$confDSM->{'pool_prefix'}."%' ";
$sth2 = $dbh2->prepare($request);
if (!defined($sth2)) {
    print "ERROR : ".$DBI::errstr."\n";
}
if (!$sth2->execute()){
    print("Error when getting perfdata file : " . $sth2->errstr . "");
    return "";
}

# Sort Data
my $data;
my @hash;
my @hash2;
my $i;
while ($data = $sth2->fetchrow_hashref()) {
    $i = $data->{'name2'};
    $i =~ s/$confDSM->{'pool_prefix'}//g;
    $hash[$i] = $data->{'name2'};
    @hash2 = sort {$a <=> $b} @hash;
}
undef($data);

sub getHostID($$) {
    my $con = $_[1];
    
    # Request
    my $sth2 = $con->prepare("SELECT `host_id` FROM `host` WHERE `host_name` = '".$_[0]."' AND `host_register` = '1'");
    if (!$sth2->execute) {
	writeLogFile("Error:" . $sth2->errstr . "\n");
    }
    
    my $data_host = $sth2->fetchrow_hashref();
    my $host_id = $data_host->{'host_id'};
    $sth2->finish();
    
    # free data
    undef($data_host);
    undef($con);
    
    # return host_id
    return $host_id;
}

sub getHostPoller($$) {
    my $con = $_[1];
    my $sth2 = $con->prepare("SELECT ns.id, ns.localhost FROM nagios_server ns, ns_host_relation nsh WHERE nsh.host_host_id = '".$_[0]."' AND ns.id = nsh.nagios_server_id");
    if (!$sth2->execute) {
        writeLogFile("Error:" . $sth2->errstr . "\n");
    }
    my $data_poller = $sth2->fetchrow_hashref();
    undef($sth2);
    return $data_poller;
}

# Check Temporary lock files directory
if (!-d $LOCKDIR){ 
    writeLogFile("Cannot fine temporary lock files directory. I create it : $LOCKDIR.");
    mkpath($LOCKDIR);
}

# Purge Slot locks
my @fileList = glob($LOCKDIR."/*");
foreach (@fileList) {
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = lstat($_);
    if (time() - $mtime > $MAXDATAAGE) {
	writeLogFile("remove old lock file: ".$_." (normal behavior)");
	unlink($_);
    }
}

############################################
# Send data to Nagios serveurs
foreach my $str (@hash2) {
    # Check if I can use this slot
    if (length($str) && !-e $LOCKDIR."-$str") {
	my $time_now = time();
	my $host_id = getHostID($host_name, $dbh);
	my $data_poller = getHostPoller($host_id, $dbh);

	# Write Tempory lock
	if (system("touch ".$LOCKDIR."$str.lock")) {
	    writeLogFile("Cannot write lock file... Be carefull, some data can be loose.");
	}

	# Build external command
	my $externalCMD = "[$timeRequest] PROCESS_SERVICE_CHECK_RESULT;$host_name;$str;2;$output";
	if ($data_poller->{'localhost'} == 0) {
	    my $externalCMD = "EXTERNALCMD:".$data_poller->{'id'}.":".$externalCMD;
	    writeLogFile("Send external command : $externalCMD");
	    if (system("echo '$externalCMD' >> $CECORECMD")) {
		writeLogFile("Cannot Write external command for centcore");
	    }
	} else {
	    writeLogFile("Send external command : $externalCMD");
	    if (system("echo '$externalCMD' >> $NAGIOSCMD")) {
		writeLogFile("Cannot Write external command for local nagios");
	    }
	}
	exit 0;
    } else {
	if (-e $LOCKDIR."-$str") {
	    ;#print "$str : already used !";
	}
    }
}

# Put data in cache

