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

my $logfile = IO::File->new('status.log', 'a');
$logfile->autoflush(1);

$mech->agent('Mozilla/6.0 (Linux; U; en; rv:1.8.2.3)');

my $formatter = HTML::FormatText->new(leftmargin => 0, rightmargin => 120);

my $index = get_index();

my $tree = HTML::TreeBuilder->new_from_content( $index );
#print $formatter->format( $tree );

my @elements = $tree->look_down( _tag => 'div', id => qr/^u_/ );

my @post_data;
for my $post (@elements) {
  #use DDP; p $post->as_XML_indented;
  my @children = $post->content_list;

  push @post_data, [ map { trim( $_->format($formatter) ) } @children ];

    #poster => trim($divs[0]->format($formatter)),
	#my $text = $formatter->format( $post );
	#$text =~ s/\n+/ /gms;
	#print "$text\n";
}
use DDP; p @post_data;


sub get_index {
	while(1) {
		try {
			print "Getting index\n";
			$mech->get("http://m.facebook.com/");
			if ( capture { $mech->form_with_fields( qw/ email pass / ) } ) {
				print $logfile "@{[DateTime->now]} : Logging in...\n";
				print "@{[time]} : Logging in...\n";
				$mech->submit_form( with_fields => { email => $user, pass => $pass, persistent => 1 } );
			}
		} catch {
			warn $_;
		};
		last if $mech->success;
		sleep 5;
	}
	my $index_content = $mech->content;
	$index_content;
}


sub trim {
  $_[0] =~ s/(^\s+)|(\s+$)//gr;
}

