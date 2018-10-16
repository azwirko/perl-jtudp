#!/usr/bin/perl

# For Redpitaya & Pavel Demin FT8 code image @ http://pavel-demin.github.io/red-pitaya-notes/sdr-transceiver-ft8

# Gather decodes from FT8 log file /dev/shm/decode-ft8.log file of format 
#    133915 1 0 1 17   0.0  17.0  37.4   3  0.12 10137466 CQ K1RA FM18
# handles msgs: CQ CALL1 GRID, CALL1 CALL2 GRID, CALL1 CALL2 RPT, CALL1 CALL2 RR73, etc.  

# sends WSJT-X UDP packets per definition
#   https://sourceforge.net/p/wsjt/wsjt/HEAD/tree/branches/wsjtx/NetworkMessage.hpp

# caches call signs for up to 15 minutes before resending - see $MINTIME

# v0.7.2 - 2018/04/25 - K1RA@K1RA.us

# Start by using following command line
# ./udp.pl YOURCALL YOURGRID HOSTIP UDPPORT
# ./udp.pl WX1YZ AB12DE 192.168.1.2 2237

use strict;
use warnings;

use IO::Socket;

# minimum number of minutes to cache calls before resending
my $MINTIME = 15;

# Software descriptor and version info
my $ID = "FT8-Skimmer";
my $VERSION = "0.7.2";
my $REVISION = "a";


# check for YOUR CALL SIGN
if( ! defined( $ARGV[0]) || ( ! ( $ARGV[0] =~ /\w\d+\w/)) ) { 
  die "Enter a valid call sign\n"; 
}
my $mycall = uc( $ARGV[0]);

# check for YOUR GRID SQUARE (6 digit)
if( ! defined( $ARGV[1]) || ( ! ( $ARGV[1] =~ /^\w\w\d\d\w\w$/)) ) { 
  die "Enter a valid 6 digit grid\n";
} 
my $mygrid = uc( $ARGV[1]);

# check for HOST IP
if( ! defined( $ARGV[2]) || ( ! ( $ARGV[2] =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)) ) { 
  die "Enter a valid IP address ex: 192.168.1.2\n";
} 
my $peerhost = $ARGV[2];

# check for UDP PORT
if( ! defined( $ARGV[3]) || ( ! ( $ARGV[3] =~ /^\d{2,5}$/)) ) { 
  die "Enter a valid UDP port number ex: 2237\n";
} 
my $peerport = $ARGV[3];

# WSJT-X UDP header
my $header = "ad bc cb da 00 00 00 02 ";
# pack header into byte array
$header = join( "", split(" ", $header));

# Message descriptors
my $msg0 = "00 00 00 00 ";
# pack msg0 into byte array
$msg0 = join( "", split(" ", $msg0));

my $msg1 = "00 00 00 01 ";
# pack msg1 into byte array
$msg1 = join( "", split(" ", $msg1));

my $msg2 = "00 00 00 02 ";
# pack msg2 into byte array
$msg2 = join( "", split(" ", $msg2));

my $msg6 = "00 00 00 06 ";
# pack msg6 into byte array
$msg6 = join( "", split(" ", $msg6));

my $maxschema = "00 00 00 03 ";
# pack maxschema into byte array
$maxschema = join( "", split(" ", $maxschema));

# holds one FT8 decoder log line from /dev/shm/decoder-ft8.log
my $line;

# FT8 decoder log fields
my $gmt;
my $x;
my $snr;
my $dt;
my $freq;
my @rest;
my $call;
my $grid;

# Msg 1 Local station info fields (only used by WSJT-X)
my $mode = "FT8";
my $dxcall = "AB1CDE";
my $report = "+12";
my $txmode = "FT8";
my $txen = 0;
my $tx = 0;
my $dec = 0;
my $rxdf = 1024;
my $txdf = 1024;
my $decall = $mycall;
my $degrid = $mygrid;
my $dxgrid = "AA99";
my $txwat = 0;
my $submode = "";
my $fast = 0;

# contents of FT8 message (CALL1 CALL2 GRID, etc)
my $ft8msg;

# lookup table to determine base FT8 frequency used to calculate Hz offset
my %basefrq = ( 
  "184" => 1840000,
  "357" => 3573000,
  "535" => 5357000,
  "707" => 7074000,
  "1013" => 10136000,
  "1407" => 14074000,
  "1810" => 18100000,
  "2107" => 21074000,
  "2491" => 24915000,
  "2807" => 28074000,
  "5031" => 50313000
);

# used for calculating signal in Hz from base band FT8 frequency
my $base;
my $hz;

# flag to send new spot
my $send;

# decode current and last times
my $time;
my $ltime;
my $secs;

# hash of deduplicated calls per band
my %db;

# call + base key for %db hash array
my $cb;

# minute counter to buffer decode lines
my $min = 0;

# client socket
my $sock;


$| = 1;

# setup tail to watch FT8 decoder log file and pipe for reading
# 193245 1 0 1  0   0.0   0.0  29.0  -2  0.31 14076009 K1HTV K1RA FM18
open( LOG, "< /dev/shm/decode-ft8.log");

# jump to end of file
seek LOG, 0, 2;
      
# Loop forever
while( 1) {

# setup tail to watch FT8 decoder log file and pipe for reading
# 193245 1 0 1  0   0.0   0.0  29.0  -2  0.31 14076009 K1HTV K1RA FM18
#  open( LOG, "tail -f /dev/shm/decode-ft8.log |");
      
# read in lines from FT8 decoder log file 
READ:
  while( $line = <LOG>) {
# check to see if this line says Decoding (end of minute for FT8 decoder)
    if( $line =~ /^Decoding/) { 
# yes - send a heartbeat

# open socket 
      $sock = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerPort => $peerport,
        PeerAddr => $peerhost,
      ) or die "Could not create socket: $!\n";

# Msg 0 - Heartbeat
      print $sock ( pack( "H*", $header) .
                    pack( "H*", $msg0) . 
                    pack( "N*", length( $ID)) . 
                    pack( "A*", $ID) .
                    pack( "H*", $maxschema) . 
                    pack( "N*", length( $VERSION)) . 
                    pack( "A*", $VERSION) . 
                    pack( "N*", length( $REVISION)) . 
                    pack( "A*", $REVISION)
      );

# close socket
      $sock->close();

# check if its been one hour decoding
      if( $min++ >= 60) {

# yes - loop thru cache on call+baseband keys
        foreach $cb ( keys %db) {
# extract last time call was seen        
          ( $ltime) = split( "," , $db{ $cb});

# check if last time seen > 1 hour        
          if( time() >= $ltime + 3600) {
# yes - purge record
            delete $db{ $cb};
          }
        }
# reset 60 minute timer
        $min = 0;
        }
    } # end of a FT8 log decoder minute capture
    
# check if this is a valid FT8 decode line beginning with 6 digit time stamp    
    if( ! ( $line =~ /^\d{6}\s/) ) { 
# no - go to read next line from decoder log
      next READ; 
    }
    
# looks like a valid line split into variable fields
# print $line;
    ($gmt, $x, $x, $x, $x, $x, $x, $x, $snr, $dt, $freq, @rest)= split( " ", $line);

# extract HHMM
    $gmt =~ /(\d\d)(\d\d)(\d\d)/;
    $secs = ( ( $1 * 3600) + ( $2 * 60) + $3) * 1000;

# get UNIX time since epoch  
    $time = time();
    
# determine base frequency for this FT8 band decode    
    $base = int( $freq / 10000);

# make freq an integer  
    $freq += 0;

# make the FT8 message by appending remainder of line into one variable, space delimited  
    $ft8msg = join( " ", @rest);
  
# Here are all the various FT8 message scenarios we will recognize, extract senders CALL & GRID
# CQ CALL LLnn 
    if( $ft8msg =~ /^CQ\s([\w\d\/]{3,})\s(\w\w\d\d)/) {
      $call = $1;
      $grid = $2;
# CQ [NA,DX,xx] CALL LLnn  
    } elsif ( $ft8msg =~ /^CQ\s\w{2}\s([\w\d\/]{3,})\s(\w\w\d\d)/) {
      $call = $1;
      $grid = $2;  
# CALL1 CALL2 [R][-+]nn
    } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\sR*[\-+][0-9]{2}/) {
      $call = $1;
      $grid = "";
# CALL1 CALL2 RRR
    } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\sRRR/) {
      $call = $1;
      $grid = "";
# CALL1 CALL2 RR73 or 73
    } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\sR*73/) {
      $call = $1;
      $grid = "";
# CALL1 CALL2 GRID
    } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\s(\w\w\d\d)/) {
      $call = $1;
      $grid = $2;
    } else {
# we didn't match any message scenario so skip this line
      next READ;
    }

# does the call have at least one number in it
    if( ! ( $call =~ /\d/) ) { 
# no - maybe be TNX, NAME, QSL, so skip this line
      next READ; 
    }
    
# check cache if we have NOT seen this call on this band yet  
    if( ! defined( $db{ $call.$base}) ) { 
# yes - set flag to send it to client(s) 
      $send = 1;

# save to hash array using a key of call+baseband 
      $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
    } else {
# no - we have seen before - get last time call was sent to client
      ( $ltime) = split( ",", $db{ $call.$base});

# test if current time is > first time seen + MINTIME since we last sent to client
      if( time() >= $ltime + ( $MINTIME* 60) ) {
# yes - set flag to send it to client(s) 
        $send = 1;

# resave to hash array with new time
        $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
      } else {
# no - don't resend or touch time 
        $send = 0;
      }
    } # end cache check

# make sure call has at least one number in it
    if ( $call =~ /\d/ && $send ) {
      $hz = int( $freq - $basefrq{ $base});

# send spot

# open socket
      $sock = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerPort => $peerport,
        PeerAddr => $peerhost,
      ) or die "Could not create socket: $!\n";

# Msg 1 - Location station info
      print $sock ( pack( "H*", $header) .
                    pack( "H*", $msg1) . 
                    pack( "N*", length( $ID)) . 
                    pack( "A*", $ID) .
                    pack( "N*", 0) .
                    pack( "N*", $basefrq{ $base}) . # pack( "N*", $freq) . send standard FT8 freq for RBN/Aggregator
                    pack( "N*", length( $mode)) . 
                    pack( "A*", $mode) .
                    pack( "N*", length( $dxcall)) . 
                    pack( "A*", $dxcall) .
                    pack( "N*", length( $report)) . 
                    pack( "A*", $report) .
                    pack( "N*", length( $txmode)) . 
                    pack( "A*", $txmode) .
                    pack( "h", $txen) .
                    pack( "h", $tx) .
                    pack( "h*", $dec) .
                    pack( "N*", $rxdf) .
                    pack( "N*", $txdf) .
                    pack( "N*", length( $decall)) . 
                    pack( "A*", $decall) .
                    pack( "N*", length( $degrid)) . 
                    pack( "A*", $degrid) .
                    pack( "N*", length( $dxgrid)) . 
                    pack( "A*", $dxgrid) .
                    pack( "h", $txwat) .
                    pack( "N*", length( $submode)) . 
                    pack( "A*", $submode) .
                    pack( "h", $fast)
      );

# close socket
      $sock->close();

# open socket
      $sock = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerPort => $peerport,
        PeerAddr => $peerhost,
      ) or die "Could not create socket: $!\n";

# Msg 2 - FT8 decode message
      print $sock ( pack( "H*", $header) .
                    pack( "H*", $msg2) . 
                    pack( "N*", length( $ID)) . 
                    pack( "A*", $ID) .
                    pack( "h", 1) .
                    pack( "N*", $secs) .
                    pack( "N*", $snr) .
                    pack( "d>", $dt) .
                    pack( "N*", $hz) .
                    pack( "N*", length( $mode)) . 
                    pack( "A*", $mode) .
                    pack( "N*", length( $ft8msg)) . 
                    pack( "A*", $ft8msg) .
                    pack( "h", 0) .
                    pack( "h", 0)
      );

# close socket
      $sock->close();

    } # end send valid call decode
    
  } # while LOG line
  
  sleep 1;
# reset EOF flag
  seek LOG, 0, 1;

} # repeat forever
