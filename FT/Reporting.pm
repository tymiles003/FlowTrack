# This module handles some of the longer term statistics gathering.
# RRD Graphs, tracking common talkers, etc.  It deals with the secondary data
#
package FT::Reporting;
use strict;
use warnings;
use parent qw{FT::FlowTrack};
use Carp;
use Data::Dumper;
use Log::Log4perl qw{get_logger};
use Net::IP;
use List::Util;

use FT::Configuration;
use FT::FlowTrack;
use FT::IP;

#
# Tune scoring
#

# How much to increment the score when we see a talker pair
our $SCORE_INCREMENT = 0;

# The multiplier for the last update time (i.e. $SCORE_DECREMENT * (time - last_update))
our $SCORE_DECREMENT = .5;

# This is used to add a bit more weight to pairs with a bunch of flows
# SCORE += int(total_flows/$SCORE_FLOWS)
our $SCORE_BYTES = 1_000;

#
# All new really does here is create an FT object, and initialize the configuration
sub new
{
    my $class = shift;
    my ($config) = @_;

    return $class->SUPER::new( $config->{data_dir}, $config->{internal_network} );

}

sub runReports
{
    my $self   = shift;
    my $logger = get_logger();

    $self->updateRecentTalkers();
    $self->purgeRecentTalkers();
    return;
}

#
# This routine gets all of the talker pairs that we've seen in the last reporting_interval
# and returns the list of flows keyed by buildTrackerKey
#
# Each record contains:
# total bytes for the talker pair
# total packets for the talker pair
# internal address for the talker pair
# external address for the talker pair
# list of flows for the talker pair
#
#
# Single record looks like:
# '3232235877-520965706' => {
#     'flows' => [
#                  {
#                    'protocol' => 6,
#                    'bytes' => 5915,
#                    'src_port' => 58950,
#                    'flow_id' => 2938843,
#                    'packets' => 77,
#                    'dst_port' => 80,
#                    'src_ip' => 3232235877,
#                    'dst_ip' => 520965706,
#                    'fl_time' => '1358003193.06847'
#                  }
#                ],
#     'total_packets' => 77,
#     'total_bytes' => 5915,
#     'external_ip' => 520965706,
#     'internal_ip' => 3232235877
#   },
#
sub getFlowsByTalkerPair
{
    my $self               = shift();
    my $duration           = shift();
    my $logger             = get_logger();
    my $config             = FT::Configuration::getConf();
    my $reporting_interval = $duration // $config->{reporting_interval};
    my $ret_struct;

    my $flows = $self->getFlowsForLast($reporting_interval);

    foreach my $flow (@$flows)
    {
        my $key = $self->buildTalkerKey( $flow->{src_ip}, $flow->{dst_ip} );

        # If the src ip is internal assume that the dst is external, this
        # might not actually be the case for internal flows
        if ( $self->isInternal( $flow->{src_ip} ) )
        {
            $ret_struct->{$key}{internal_ip} = $flow->{src_ip};
            $ret_struct->{$key}{external_ip} = $flow->{dst_ip};
        }
        elsif ( $self->isInternal( $flow->{dst_ip} ) )
        {
            $ret_struct->{$key}{internal_ip} = $flow->{dst_ip};
            $ret_struct->{$key}{external_ip} = $flow->{src_ip};
        }
        else
        {
            $logger->debug("ODD: Both src and dst were external");
            next;
        }

        # Update Total Bytes (init if not defined)
        if ( !defined( $ret_struct->{$key}{total_bytes} ) )
        {
            $ret_struct->{$key}{total_bytes} = $flow->{bytes};
        }
        else
        {
            $ret_struct->{$key}{total_bytes} += $flow->{bytes};
        }

        # Update total packets (init if not defined)
        if ( !defined( $ret_struct->{$key}{total_packets} ) )
        {
            $ret_struct->{$key}{total_packets} = $flow->{packets};
        }
        else
        {
            $ret_struct->{$key}{total_packets} += $flow->{packets};
        }

        push( @{ $ret_struct->{$key}{flows} }, $flow );
    }

    return $ret_struct;
}

#
# Takes two IP addresses (integers) and returns the string
# internal-external
#
# if both are internal returns
# lowest_internal-higest_internal
sub buildTalkerKey
{
    my $self   = shift;
    my $logger = get_logger();
    my ( $ip_a, $ip_b ) = @_;

    # IP A is internal IP B isn't
    if ( $self->isInternal($ip_a) && !$self->isInternal($ip_b) )
    {
        return $ip_a . "-" . $ip_b;
    }

    # IP B is internal IP A isn't
    elsif ( $self->isInternal($ip_b) && !$self->isInternal($ip_a) )
    {
        return $ip_b . "-" . $ip_b;
    }

    # Both A & B are internal, return with lowest ip first
    elsif ( $self->isInternal($ip_a) && $self->isInternal($ip_b) )
    {
        return $ip_a < $ip_b ? $ip_a . "-" . $ip_b : $ip_b . "-" . $ip_a;
    }

}

#
# Updates the scoring in the recent talkers database
#
#
sub updateRecentTalkers
{
    my $self   = shift();
    my $logger = get_logger();

    my $recent_flows   = $self->getFlowsByTalkerPair();
    my $recent_talkers = $self->getRecentTalkers();
    my $scored_flows;
    my $update_sql;

    if ( !defined($recent_flows) && !defined($recent_talkers) )
    {
        return;
    }

    $update_sql = qq{
        INSERT OR REPLACE INTO 
            recent_talkers (id, internal_ip, external_ip, score, last_update)
        VALUES
            (?,?,?,?,?)
    };

    # Age the scores
    # load all of our existing talker pairs into the return struct
    # decrement the score for each of them  (we'll add to it later)
    foreach my $talker_pair ( keys %$recent_talkers )
    {
        $scored_flows->{$talker_pair} = $recent_talkers->{$talker_pair};
        $scored_flows->{$talker_pair}{score} =
          $scored_flows->{$talker_pair}{score} -
          int( ( $SCORE_DECREMENT * ( time - $recent_talkers->{$talker_pair}{last_update} ) ) );
    }

    #
    # Score is updated here
    #

    # Now go through all of our recent flows and update ret_struct;
    foreach my $recent_pair ( keys %$recent_flows )
    {
        # setup the scored flow record
        if ( !exists( $scored_flows->{$recent_pair} ) )
        {
            $scored_flows->{$recent_pair}{internal_ip} = $recent_flows->{$recent_pair}{internal_ip};
            $scored_flows->{$recent_pair}{external_ip} = $recent_flows->{$recent_pair}{external_ip};
            $scored_flows->{$recent_pair}{score}       = 0;
        }

        my @flow_bytes = map $_->{bytes}, @{ $recent_flows->{$recent_pair}{flows} };

        unless ( List::Util::sum(@flow_bytes) < 500 )
        {
            # Add the average traffic for the recent flows to the score
            $scored_flows->{$recent_pair}{score} +=
              int( $recent_flows->{$recent_pair}{total_bytes} / scalar( @{ $recent_flows->{$recent_pair}{flows} } ) );
        }
    }

    # Now do the DB updates
    # TODO: Bulk insert the data
    my $dbh = $self->_initDB();
    my $sth = $dbh->prepare($update_sql)
      or $logger->warning( "Couldn't prepare:\n\t $update_sql\n\t" . $dbh->errstr );

    foreach my $scored_flow ( keys %$scored_flows )
    {
        $sth->execute( $scored_flows->{$scored_flow}{internal_ip} . $scored_flows->{$scored_flow}{external_ip},
                       $scored_flows->{$scored_flow}{internal_ip},
                       $scored_flows->{$scored_flow}{external_ip},
                       $scored_flows->{$scored_flow}{score}, time )
          or $logger->warning( "Couldn't execute: " . $dbh->errstr );
    }

    return;

}

#
# Loads data from the recent_talkers database
#
sub getRecentTalkers
{
    my $self       = shift();
    my $logger     = get_logger();
    my $dbh        = $self->_initDB();
    my $ret_struct = {};

    my $sql = qq{
         SELECT * FROM recent_talkers ORDER BY score DESC, last_update DESC
    };

    my $sth = $dbh->prepare($sql) or $logger->warn( "Couldn't prepare:\n $sql\n" . $dbh->errstr );
    $sth->execute() or $logger->warning( "Couldn't execute" . $dbh->errstr );

    while ( my $talker_ref = $sth->fetchrow_hashref )
    {
        $ret_struct->{ $talker_ref->{internal_ip} . "-" . $talker_ref->{external_ip} } = $talker_ref;
    }

    return $ret_struct;
}

#
# This routine returns the list of the top x recent talkers
# top x is defined as, top talkers sorted by time then score
# so we see the most recent active top talkers
#
sub getTopRecentTalkers
{
    my $self = shift();
    my ($limit) = @_;

    my $logger = get_logger();
    my $dbh    = $self->_initDB();
    my $ret_list;

    my $sql = qq{
        SELECT * FROM recent_talkers ORDER BY score, last_update DESC LIMIT ?
    };

    my $sth = $dbh->prepare($sql) or $logger->warn( "Couldn't prepare:\n $sql\n" . $dbh->errstr );
    $sth->execute($limit);

    while ( my $recent_talker = $sth->fetchrow_hashref )
    {
        push( @$ret_list, $recent_talker );
    }

    return $ret_list;
}

#
# purge old data from recent_talkers
#
sub purgeRecentTalkers
{
    my $self   = shift();
    my $logger = get_logger();
    my $dbh    = $self->_initDB();
    my $rows_deleted;
    my $sql = qq {
        DELETE FROM recent_talkers WHERE id NOT IN (
            SELECT id FROM recent_talkers
            ORDER BY score DESC
            LIMIT 21
        )
    };

    my $sth = $dbh->prepare($sql) or $logger->logconfess( 'failed to prepare:' . $DBI::errstr );
    $rows_deleted = $sth->execute();

    $logger->info( "purgeRecentTalkers purged: " . $rows_deleted );
}

1;
