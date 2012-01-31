#! /usr/bin/perl -w
################################################################################
# Copyright 2005-2010 MERETHIS
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
# SVN : $URL:$
# SVN : $Id:$
#
####################################################################################

use strict;
use warnings;
use DBI;
use File::stat;
use Getopt::Long;
use POSIX;

use vars qw($mysql_user $mysql_password $mysql_host $mysql_db $mysql_db_centreon $opt_h $opt_a $data $DBType);
use vars qw ($mysql_database_oreon $mysql_database_ods $mysql_passwd $debug);
my %Relations;

require "@CENTREON_ETC@conf.pm";

$mysql_password = $mysql_passwd;
$mysql_db_centreon = $mysql_database_oreon;

# Retention in days
my $retention = 30;

$debug = 0;

my $centcore_file = "@CENTREON_VARLIB@/centcore.cmd";
my $nagios_file = "@NAGIOS_CMD@/nagios.cmd";

################################################################################

## Init Date
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);

#'''''''''''''''''''''''''''''''''''
# Init MySQL Connexion
#'''''''''''''''''''''''''''''''''''

# Connect to centreon DB
my $dbh_centreon = DBI->connect("DBI:mysql:database=".$mysql_db_centreon.";host=".$mysql_host, $mysql_user, $mysql_password, {'RaiseError' => 1});

# Get DBType
$DBType = getDBType($dbh_centreon);

my $ndo2db;
my $prefix;
my $ndoDB;

if ($DBType == 1) {
	# Get ndo / nagios connexion informations
	my $sth1 = $dbh_centreon->prepare("SELECT * FROM cfg_ndo2db LIMIT 1");
	if (!$sth1->execute) {
	    die "Error:" . $sth1->errstr . "\n";
	}
	$ndo2db = $sth1->fetchrow_hashref();
	$prefix = $ndo2db->{'db_prefix'};
	$ndoDB = $ndo2db->{'db_name'};
} else {
	exit();
}

# Connect to ndo DB
my $dbh;
my $sth1;
if ($DBType == 1) {
	$dbh = DBI->connect("DBI:mysql:database=".$mysql_database_ods.";host=".$mysql_host, $mysql_user, $mysql_password, {'RaiseError' => 1});
} else {
	$dbh = DBI->connect("DBI:mysql:database=".$ndoDB.";host=".$mysql_host, $mysql_user, $mysql_password, {'RaiseError' => 1});
}

# Get id of the localhost poller
$sth1 = $dbh_centreon->prepare("SELECT id FROM nagios_server WHERE `localhost` = '1'");
if (!$sth1->execute()) {
    die "Error:" . $sth1->errstr . "\n";
}
my $localhost = $sth1->fetchrow_hashref();

# Create Buffer with nagios server list.
$sth1 = $dbh_centreon->prepare("SELECT nagios_server_id, host_name FROM ns_host_relation nhr, host h WHERE host_host_id = host_id");
if (!$sth1->execute) {
    die "Error:" . $sth1->errstr . "\n";
}
while (my $relation = $sth1->fetchrow_hashref()) {
    $Relations{$relation->{'host_name'}} = $relation->{'nagios_server_id'};
}

$sth1 = $dbh_centreon->prepare("SELECT pool_host_id FROM mod_dsm_pool ");
if (!$sth1->execute) {
    die "Error:" . $sth1->errstr . "\n";
}
my $str = "";
while (my $relation = $sth1->fetchrow_hashref()) {
	if ($str !~ "") {
		$str .= ",";
	}
    $str .= "'".$relation->{'pool_host_id'}."'";
}

if ($str eq '' && $DBType == 1) {
	print "OK=>".$str."\n";
	exit();
} else {
	;
}

# Comment Purges
my $sth2;
if ($DBType == 1) {
	$sth2 = $dbh->prepare("SELECT hosts.name AS name1, services.description AS name2 FROM hosts, services WHERE hosts.host_id = services.host_id AND services.host_id IN ($str) AND services.state = '4'");
} else {
	$sth2 = $dbh->prepare("SELECT name1, name2 FROM nagios_objects WHERE object_id IN (SELECT service_object_id FROM `nagios_services` WHERE service_object_id NOT IN (SELECT service_object_id FROM `nagios_servicestatus`))");
}
if (!$sth2->execute()) { 
	die "Error:" . $sth2->errstr . "\n";
}
while (my $comments = $sth2->fetchrow_hashref()) {
    #
    # check if it's a service or a host
    #
    if (defined($comments->{'name2'})) {
        # Check if we have to send external command to poller by centcore
        if (defined($Relations{$comments->{'name1'}}) && $Relations{$comments->{'name1'}} == $localhost->{'id'}) {
            # Nagios is on localhost
            my $str = "echo \"[".time()."] PROCESS_SERVICE_CHECK_RESULT;".$comments->{'name1'}.";".$comments->{'name2'}.";0;Initial information\" >> $nagios_file";
            if ($debug) {
                print $str . "\n";
            } else {
                `$str`;
            }
        } else {
            # Nagios is on a poller
            my $str = "echo \"EXTERNALCMD:".$Relations{$comments->{'name1'}}.":[".time()."] PROCESS_SERVICE_CHECK_RESULT;".$comments->{'name1'}.";".$comments->{'name2'}.";0;Initial information\" >> $centcore_file";
            if ($debug) {
                print $str . "\n";
            } else {
                `$str`;
            }
        }
    }
}
exit();
