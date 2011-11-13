#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use warnings;
use Test::More;

use_ok('HTMLGen');

sub header;
sub footer;

my $h = HTMLGen->new(header => \&header, footer => \&footer);
ok($h, 'object created');
$h->set_title('Page Title');

my $calls;

sub header {
  my ($h) = @_;
  is($h, $h, '... header passed object');
  $calls++;
  '<!-- header -->'
}

sub footer {
  my ($h) = @_;
  is($h, $h, '... footer passed object');
  $calls++;
  '<!-- footer -->'
}

my $h2 = $h->h2('Header');
is($h2, '<h2>Header</h2>', '... content header');

my $input = $h->inputtext(id => 'username', name => 'username');
is($input, '<input name="username" type="text" id="username">',
   '... input text');

my $js = $h->js(type => undef, '!append' => 'appended content');
is($js, '<script>appended content</script>', '... script tag');

is(HTMLGen::entities('&'), '&amp;', '... entities function');
is($h->entities('&'), '&amp;', '... entities method');

is(HTMLGen::unentities('&amp;'), '&', '... unentities function');
is($h->unentities('&amp;'), '&', '... unentities method');

is(HTMLGen::urlencode('/'), '%2F', '... urlencode function');
is($h->urlencode('/'), '%2F', '... urlencode method');

is(HTMLGen::urldecode('%2F'), '/', '... urldecode function');
is($h->urldecode('%2F'), '/', '... urldecode method');


my $list = $h->list([1, "\n2\n"]);
is($list, '<ul>
<li>
1
</li>
<li>
2
</li>
</ul>
', '... a list');

my $p = $h->page('<p>Lorem ipsum...</p>');
is($p, '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Page Title
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<!-- header --><div id="content">
<p>Lorem ipsum...</p>
</div>
<!-- footer -->
</div>
</body>
</html>
', '... page');

is($calls, 2, '... callbacks as expected');

done_testing;
