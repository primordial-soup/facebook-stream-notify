#!/usr/bin/env perl

use strict;
no warnings;# "recursion";
use WWW::Mechanize;
use YAML qw/LoadFile DumpFile/;
use File::HomeDir;
use File::Spec;
use JSON::XS;
use URI;
use URI::QueryParam;
use Try::Tiny;

use HTTP::Cookies;

use HTML::TreeBuilder::XPath;
use HTML::FormatText;
use DateTime;
use IO::File;

use Sys::SigAction qw(timeout_call);
use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8 decode_utf8);
use utf8::all;
use Capture::Tiny ':all';

my $config = LoadFile(File::Spec->catfile( File::HomeDir->my_home, ".fbpc.rc"));
my $user = $config->{user} or die "no user in config";
my $pass = $config->{pass} or die "no password in config";

my $cookie_file = File::Spec->catfile( File::HomeDir->my_home, ".fbcookie");
my $cookie_jar = HTTP::Cookies->new( file => $cookie_file, autosave => 1 );

my $mech = WWW::Mechanize->new( cookie_jar => $cookie_jar );

my $logfile = IO::File->new('ticker.log', 'a');
$logfile->autoflush(1);

my $conn;

#$mech->agent('Mozilla/5.0 (Windows; U; Windows NT 5.1; en; rv:1.9.2.3) Gecko/20100401');
$mech->agent('Mozilla/6.0 (Linux; U; en; rv:1.8.2.3)');

my $last_time = time;
my $reload_in = 60*60; # 1 hour

my $formatter = HTML::FormatText->new(leftmargin => 0, rightmargin => 120);

start();

sub start {
	load_index();
	ticker_pull();
}

sub load_index {
	get_index();
	sleep 300 while reconnect() == -1;
}

sub get_index {
	#capture_stderr {
		while(1) {
			try {
				print "Getting index\n";
				$mech->get("http://www.facebook.com/");
				if ( $mech->form_with_fields( qw/ email pass / ) ) {
					print $logfile "@{[DateTime->now]} : Logging in...\n";
					print "@{[time]} : Logging in...\n";
					$mech->submit_form( with_fields => { email => $user, pass => $pass, persistent => 1 } );
				}
			} catch { warn $_; };
			last if $mech->success;
			sleep 5;
		}
	#};
	my $index_content = $mech->content;
	#use DDP; p $index_content;


	#if( $index_content =~ /(^.*seq.*$)/m ) {
		#print "seq: $1\n";
	#}


	if( $index_content =~ /(^.*onPageletArrive.*user_channel.*$)/m ) {
		my $line = $1;
		$line =~ /onPageletArrive\((.*)\)/;
		my $data = $1;
		my $data_json = decode_json($data);
		#use DDP; p $data_json;
		$conn->{user_channel} = $data_json->{jsmods}{define}[0][2]{channelConfig}{user_channel};
		$conn->{seq} = $data_json->{jsmods}{define}[0][2]{channelConfig}{seq};
		$conn->{server_time} = $data_json->{jsmods}{define}[2][2]{serverTime};
	}
	if ( $index_content =~ /"fb_dtsg"\s*:\s*"([^"]+)"/ ) {
		$conn->{fb_dtsg} = $1;
	}
	$conn->{user} = ($conn->{user_channel} =~ /p_(\d+)/)[0];
	$conn->{start_time} = time;
	$conn->{clientid} = clientid();
	use DDP; p $conn;
}

############### RECONNECT ###############
sub reconnect {
	do {
	# https://www.facebook.com/ajax/presence/reconnect.php?__user=1353108048&__a=1&__req=1&reason=6&fb_dtsg=AQA0H5hC
	my $reconnect_uri = URI->new('https://www.facebook.com/ajax/presence/reconnect.php');
	my $reconnect_query = $reconnect_uri->clone;
	$reconnect_query->query_form(
		__user=> $conn->{user},
		__a => 1,
		__req => 1,
		reason => 6,
		fb_dtsg => $conn->{fb_dtsg},
	);
	use DDP; p $reconnect_query;
	try {
		$mech->get($reconnect_query);
	} catch {
		warn $_; 
		return -1;
	};
	my $reconnect_data = get_json_for($mech->content);
	return -1 unless $reconnect_data;
	$conn->{seq} = $reconnect_data->{payload}{seq};
	#$conn->{which_host} = $reconnect_data->{payload}{max_conn};
	$conn->{which_host} = int(rand(6)+1);
	#use DDP; p $reconnect_data;
	use DDP; p $conn;
	}
	if 1;
}

############### TICKER MORE ###############
do {
my $uri = URI->new("https://www.facebook.com/ajax/ticker.php?more_pager=1&oldest=1358477536&source=fst");
$mech->post($uri);
use DDP; p $mech->content;
}
if 0;

############### TICKER PULL ###############
sub ticker_pull {
	do {
	my $channel_uri = URI->new("https://$conn->{which_host}-pct.channel.facebook.com/pull");
	my $count = 10;
		#while ( $count --> 0 ) {
		while ( 1 ) {
			if ( time - $last_time > $reload_in ) {
				load_index();
				$last_time = time;
				next;
			}
			my $pull_uri = $channel_uri->clone;
			$pull_uri->query_form(
				channel => $conn->{user_channel},
				seq => $conn->{seq},
				partition => 0,
				clientid => $conn->{clientid},
				idle => 0,
				state => 'active');
			#use DDP; p $pull_uri;
			while(1) {
				try { 
					$mech->get($pull_uri);
				} catch {warn $_;};
				last if $mech->success;
				sleep 30;
			}
			my $data = get_json_for($mech->content);
			next unless $data;
			use DDP; print $logfile p($data, colored => 1);
			$conn->{seq} = $data->{seq};
			my $msg = $data->{t};
			$msg .= " : " . ( join ", ", map { $_->{type} } @{$data->{ms}}  );
			use DDP; print $logfile p($msg, colored => 1), "\n";
			if( $data->{t} eq 'msg' ) {
				for my $msg (@{$data->{ms}}) {
					my $html = $msg->{story_xhp};
					# $msg->{type} eq "ticker_update:home"
					next unless $html;
					my $time = DateTime->from_epoch( epoch => $msg->{story_time} );
					my $tree = HTML::TreeBuilder::XPath->new();
					$tree->parse($html);
					my $info = [$tree->findnodes( q{//div[@class="tickerFeedMessage"]} )]->[0];
					my $text = $formatter->format($info) =~ s/\n\Z//sgr;
					$text =~ s/\n+/    /sg;
					print "$time : $text\n"; print $logfile "$time : $text\n";
				}
			}
		}
	}
	if 1;
}

############### NOTIFICATIONS ###############
do {
my $notifications_uri = URI->new("https://www.facebook.com/ajax/notifications/get.php");
my $pull_uri = $notifications_uri->clone;
$pull_uri->query_form(
	time => time, #now
	#time => 0,
	user => $conn->{user},
	version => 2,
	locale => 'en_GB',
	earliest_time => $conn->{start_time}, # - (60*60*1),
	__user => $conn->{user},
	__a => 1,
	__req => 9,
	#__req => '8c',
	);
use DDP; p $pull_uri;
#$mech->get("https://www.facebook.com/ajax/notifications/get.php?time=1358643612&user=1353108048&version=2&locale=en_GB&earliest_time=1358631923&__user=1353108048&__a=1&__req=9");
        #GET https://www.facebook.com/ajax/notifications/get.php?time=0         &user=1353108048&version=2&locale=en_GB&earliest_time=1358584293&__user=1353108048&__a=1&__req=8c
$mech->get($pull_uri);
#use DDP; p $mech->content;
	try {
		my $data = get_json_for($mech->content);
		my $notifications = $data->{payload}{notifications};
		my $dump_data;
		for my $note_id (keys $notifications) {
			my $time = $notifications->{$note_id}{time};
			my $html = $notifications->{$note_id}{markup};
			my $unread = $notifications->{$note_id}{unread};
			my $tree = HTML::TreeBuilder::XPath->new();
			$tree->parse($html);
			my $info = [$tree->findnodes( q{//div[@class="info"]} )]->[0];
			my $text = $formatter->format($info) =~ s/\n\Z//sgr;
			push @$dump_data, { 
				text =>  $text,
				time => DateTime->from_epoch( epoch => $time ),
				unread => $unread,
				id => $note_id,
			};
		}
		use DDP; p $dump_data;
		# https://www.facebook.com/ajax/notifications/mark_read.php?seen=1&alert_ids%5B0%5D=94471790&asyncSignal=2451&__user=1353108048&__a=1&__req=a&fb_dtsg=AQA0H5hC
		my $mark_read_uri = URI->new("https://www.facebook.com/ajax/notifications/mark_read.php");
		for my $note_info (@$dump_data) {
			next unless $note_info->{unread};
			my $read_uri = $mark_read_uri->clone;
			$read_uri->query_form(
				seen => 1,
				'alert_ids[0]' => $note_info->{id},
				asyncSignal => 2451,
				__user => $conn->{user},
				__a => 1,
				__req => 'a',
				fb_dtsg => $conn->{fb_dtsg},
			);
			use DDP; p $read_uri;
			$mech->get($read_uri);
		}

	} catch {
		die "$_";
	};
}
if 1;


do {
#$mech->get("https://pixel.facebook.com/ajax/log_ticker_render.php?sidebar_mode=false&asyncSignal=3112&__user=1353108048&__a=1&__req=3&fb_dtsg=AQDsHBWm");
# https://1-pct.channel.facebook.com/pull?channel=p_1353108048&seq=5227&partition=0&clientid=44d7f7d9&cb=iimq&idle=111
#$mech->post("https://www.facebook.com/ajax/feed/ticker/multi_story");
$mech->get("https://2-pct.channel.facebook.com/pull?channel=p_1353108048&seq=3397&partition=0&clientid=1c2b34c0&cb=42l&idle=4&state=active");
use DDP; p $mech->content;
$mech->dump_headers;
#use DDP; p $mech->cookie_jar;
use DDP; &p([length($mech->content)]);
use DDP; p decode_json($mech->content) if $mech->content =~ /json/;
}
if 0;

# update stream
# https://www.facebook.com/ajax/intent.php?filter=h_chr&newest=1358736799&ignore_self=true&load_newer=true&request_type=2&__user=1353108048&__a=1&__req=w

#$mech->get(q,https://pct.channel.facebook.com/probe?mode=stream&format=json,);
#$mech->get(q,https://2-pct.channel.facebook.com/pull?channel=p_1353108048&seq=16704&partition=0&clientid=4aa8cb4f&cb=kksi&idle=1&state=active&mode=stream&format=json,);

sub get_json_for {
	my ($js) = @_;
	$js =~ s/\Qfor (;;);\E//g;
	try {
		decode_json($js);
	} catch {
		return undef;
	};
}

sub clientid {
	sprintf("%x", time + int(rand()*4294967295))
}


