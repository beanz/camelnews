#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use warnings;
use constant {
  USE_REAL_SERVER => $ENV{CAMEL_NEWS_TEST_LIVE_REDIS},
};
use HTTP::Request::Common;
use Plack::Test;
use Test::More;
use Test::Differences; unified_diff;
use AnyEvent;
use JSON;
use Test::SharedFork;
use lib 't/lib';
use AnyEvent::MockRedis;

$|=1;

my $j = JSON->new;
my $time = time - 90;
my $ktime = time + 3600;
my $host;
my $port;
my $pid;
unless (USE_REAL_SERVER) {
  my $connections = connections();
  my $server;
  eval { $server = AnyEvent::MockRedis->new(connections => $connections, timeout => 10); };
  plan skip_all => "Failed to create dummy server: $@" if ($@);
  ($host, $port) = $server->connect_address;
  $pid = fork;
  unless ($pid) {
    if ($pid == 0) {
      $server->finished_cv->recv;
      exit;
    } else {
      die $!;
    }
  }
}

my $cf = 't/'.$$.'.cfg';
END {
  unlink $cf if (defined $cf);
}

open my $fh, '>', $cf or
  die "Failed to write temporary configuration file: $!\n";
my $c = slurp('etc/app_config.pl');
unless (USE_REAL_SERVER) {
  $c =~ s/RedisPort => \K\d+/$port/;
  $c =~ s/RedisHost => \K'[^']+'/'$host'/;
}
$c =~ s/NewsSubmissionBreak => [^,]+,//;
$c =~ s/PreventCreateUserTime => [^,]+,//;
print $fh $c;
close $fh;

$ENV{CAMEL_NEWS_CONFIG} = $cf;
my $app = do 'bin/app.psgi';
die $@ if $@;
test_psgi $app, sub {
  my $cb = shift;
  my $res = $cb->(GET 'http://localhost/not-found');
  ok(!$res->is_success, 'not found');
  is($res->code, 404, '... status code');
  #is($res->content, 'Not found', '... content');

  $res = $cb->(POST 'http://localhost/api/create_account',
               Content => [
                           username => 'user1',
                           password => 'password1',
                          ]);
  ok($res->is_success, 'create_account');
  is($res->code, 200, '... status code');
  my $json =
    check_json($res->content, [ '"status":"ok"', qr!"auth":"[0-9a-f]{40}"! ]);
  my %headers = ( Cookie => 'auth='.$json->{auth} );

  $res =
    $cb->(GET 'http://localhost/api/login?username=user1&password=password1');
  ok($res->is_success, 'login correct password');
  is($res->code, 200, '... status code');
  $json = check_json($res->content,
                     [ '"status":"ok"',
                       qr!"auth":"[0-9a-f]{40}"!,
                       qr!"apisecret":"[0-9a-f]{40}"! ]);
  my $apisecret = $json->{apisecret};

  $res = $cb->(POST 'http://localhost/api/submit', %headers,
               Content => [
                           apisecret => $apisecret,
                           title => 'Test Article',
                           text => 'some text',
                           url => '',
                           news_id => '-1',
                          ]);
  ok($res->is_success, '/api/submit');
  is($res->code, 200, '... status code');
  $json = check_json($res->content, [ '"status":"ok"', '"news_id":1' ]);

  $res = $cb->(GET 'http://localhost/');
  ok($res->is_success, 'root - success');
  is($res->code, 200, '... status code');
  my $c = $res->content;
  check_content($c, '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Top news - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a></nav> <nav id="account"><a href="/login">login / register</a></nav></header><div id="content">
<h2>Top news</h2><section id="newslist"><article data-news-id="1"><a href="#up" class="uparrow">&#9650;</a> <h2><a href="/news/1">Test Article</a></h2> <address></address><a href="#down" class="downarrow">&#9660;</a><p>1 up and 0 down, posted by <username><a href="/user/user1">user1</a></username> some time ago <a href="/news/1">0 comments</a></p></article>
</section>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
', '... content');

  my ($css) = ($c =~ m!<link[^>]+href="([^"]+/style\.css?[^"]+)"[^>]*>!);
  $res = $cb->(GET 'http://localhost'.$css);
  ok($res->is_success, 'style.css - success');
  is($res->code, 200, '... status code');
  is($res->content, slurp('public/css/style.css'), '... content');

  my ($js) = ($c =~ m!<script[^>]+src="([^"]+/app\.js?[^"]+)"[^>]*>!);
  $res = $cb->(GET 'http://localhost'.$js);
  ok($res->is_success, 'app.js - success');
  is($res->code, 200, '... status code');
  is($res->content, slurp('public/js/app.js'), '... content');

  $res = $cb->(GET 'http://localhost/rss');
  ok($res->is_success, 'rss - success');
  is($res->code, 200, '... status code');
  check_content($res->content,
'<rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0"><channel><title>
Lamer News
</title>
<link>
http://localhost/
</link>
<description>Description pending</description><item><title>
Test Article
</title>
<guid>http://localhost/news/1</guid><link>
http://localhost/news/1
</link>
<description><![CDATA[<a href="http://localhost/news/1">Comments</a>]]></description> <comments>http://localhost/news/1</comments></item>
</channel></rss>',
     '... content');

  $res = $cb->(GET 'http://localhost/latest');
  ok(!$res->is_success, 'latest - success');
  is($res->code, 302, '... status code');
  check_location($res, '/latest/0');

  $res = $cb->(GET 'http://localhost/latest/0');
  ok($res->is_success, 'latest/0 - success');
  is($res->code, 200, '... status code');
  check_content($res->content, '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Latest news - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a></nav> <nav id="account"><a href="/login">login / register</a></nav></header><div id="content">
<h2>Latest news</h2><section id="newslist"><article data-news-id="1"><a href="#up" class="uparrow">&#9650;</a> <h2><a href="/news/1">Test Article</a></h2> <address></address><a href="#down" class="downarrow">&#9660;</a><p>1 up and 0 down, posted by <username><a href="/user/user1">user1</a></username> some time ago <a href="/news/1">0 comments</a></p></article>
</section>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
', '... content');

  $res = $cb->(GET 'http://localhost/replies');
  ok(!$res->is_success, 'replies not logged in');
  is($res->code, 302, '... status code');
  check_location($res, '/login');

  $res = $cb->(GET 'http://localhost/saved/0');
  ok(!$res->is_success, 'saved not logged in');
  is($res->code, 302, '... status code');
  check_location($res, '/login');

  $res =
    $cb->(GET 'http://localhost/usercomments/user2/0');
  ok(!$res->is_success, 'usercomments w/invalid user');
  is($res->code, 404, '... status code');
  is($res->content, 'Non existing user', '... content');

  $res = $cb->(GET 'http://localhost/submit');
  ok(!$res->is_success, 'submit not logged in');
  is($res->code, 302, '... status code');
  check_location($res, '/login');

  $res = $cb->(GET 'http://localhost/logout');
  ok(!$res->is_success, 'logout not logged in');
  is($res->code, 302, '... status code');
  check_location($res, '/');

  $res = $cb->(GET 'http://localhost/news/1');
  ok($res->is_success, 'news/1');
  is($res->code, 200, '... status code');
  check_content($res->content, '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Test Article - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a></nav> <nav id="account"><a href="/login">login / register</a></nav></header><div id="content">
<section id="newslist"><article data-news-id="1"><a href="#up" class="uparrow">&#9650;</a> <h2><a href="/news/1">Test Article</a></h2> <address></address><a href="#down" class="downarrow">&#9660;</a><p>1 up and 0 down, posted by <username><a href="/user/user1">user1</a></username> some time ago <a href="/news/1">0 comments</a></p></article>
</section><topcomment><article style="margin-left:0px" id="1-" data-comment-id="1-" class="comment"><span class="avatar"><img src="http://gravatar.com/avatar/d41d8cd98f00b204e9800998ecf8427e?s=48&amp;d=mm"></span><span class="info"><span class="username"><a href="/user/user1">user1</a></span> some time ago.    </span><pre>some text</pre></article></topcomment><br>
<div id="comments">
</div>
<script>
       $(function() {
         $("input[name=post_comment]").click(post_comment);
       });
     </script>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
', '... content');

  $res = $cb->(GET 'http://localhost/news/2');
  ok(!$res->is_success, 'news/2 non-existent');
  is($res->code, 404, '... status code');
  is($res->content, '404 - This news does not exist.', '... content');

  $res = $cb->(GET 'http://localhost/comment/1/2');
  ok(!$res->is_success, 'comment/1/2 non-existent comment');
  is($res->code, 404, '... status code');
  is($res->content, '404 - This comment does not exist.', '... content');

  $res = $cb->(GET 'http://localhost/comment/2/2');
  ok(!$res->is_success, 'comment/2/2 non-existent news');
  is($res->code, 404, '... status code');
  is($res->content, '404 - This news does not exist.', '... content');

  $res = $cb->(GET 'http://localhost/reply/1/1');
  ok(!$res->is_success, 'reply not logged in');
  is($res->code, 302, '... status code');
  check_location($res, '/login');

  $res = $cb->(GET 'http://localhost/editcomment/1/1');
  ok(!$res->is_success, 'editcomment not logged in');
  is($res->code, 302, '... status code');
  check_location($res, '/login');

  $res = $cb->(GET 'http://localhost/editnews/1');
  ok(!$res->is_success, 'editnews not logged in');
  is($res->code, 302, '... status code');
  check_location($res, '/login');

  $res = $cb->(GET 'http://localhost/user/user1');
  ok($res->is_success, 'user/user1');
  is($res->code, 200, '... status code');
  $c = $res->content;
  $c =~ s/\d+ points/some points/;
  check_content($c, '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
user1 - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a></nav> <nav id="account"><a href="/login">login / register</a></nav></header><div id="content">
<div class="userinfo">
<span class="avatar"><img src="http://gravatar.com/avatar/d41d8cd98f00b204e9800998ecf8427e?s=48&amp;d=mm"></span> <h2>user1</h2><pre></pre><ul>
<li>
<b>created </b>0 days ago
</li>
<li>
<b>karma </b>some points
</li>
<li>
<b>posted news </b>1
</li>
<li>
<b>posted comments </b>0
</li>
<li>
<a href="/usercomments/user1/0">user comments</a>
</li>
</ul>
</div>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
', '... content');

  $res = $cb->(GET 'http://localhost/user/user2');
  ok(!$res->is_success, 'user/user2 no such user');
  is($res->code, 404, '... status code');
  is($res->content, 'Non existing user', '... content');

  $res = $cb->(GET 'http://localhost/login');
  ok($res->is_success, 'login');
  is($res->code, 200, '... status code');
  check_content($res->content, '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Login - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a></nav> <nav id="account"><a href="/login">login / register</a></nav></header><div id="content">
<div id="login">
<form name="f"><label for="username">
username
</label>
<input name="username" type="text" id="username"><label for="password">
password
</label>
<input name="password" type="password" id="password"><br>
<input value="1" name="register" type="checkbox">create account<br>
<input value="Login" name="do_login" type="submit"></form>
</div>
<div id="errormsg">
</div>
<script>
      $(function() {
        $("form[name=f]").submit(login);
      });
    </script>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
', '... content');

  $res =
    $cb->(GET 'http://localhost/api/login?username=user1&password=incorrect');
  ok($res->is_success, 'login incorrect password');
  is($res->code, 200, '... status code');
  $json = check_json($res->content,
                     [
                      '"status":"err"',
                      '"error":"No match for the specified username / password pair."',
                     ]);

  $res = $cb->(GET 'http://localhost/saved/0', %headers);
  ok($res->is_success, 'saved');
  is($res->code, 200, '... status code');
  check_content($res->content, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Saved news - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a><a href="/replies" class="replies">replies</a></nav> <nav id="account"><a href="/user/user1">user1 (karma)</a> | <a href="/logout?apisecret=~.$apisecret.q~">logout</a></nav></header><div id="content">
<h2>Your saved news</h2><section id="newslist"><article data-news-id="1"><a href="#up" class="uparrow voted">&#9650;</a> <h2><a href="/news/1">Test Article</a></h2> <address> <a href="/editnews/1">[edit]</a></address><a href="#down" class="downarrow disabled">&#9660;</a><p>1 up and 0 down, posted by <username><a href="/user/user1">user1</a></username> some time ago <a href="/news/1">0 comments</a></p></article>
</section>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>var apisecret = '~.$apisecret.q~';</script><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

  $res = $cb->(GET 'http://localhost/replies', %headers);
  ok($res->is_success, 'replies');
  is($res->code, 200, '... status code');
  check_content($res->content, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Your threads - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a><a href="/replies" class="replies">replies</a></nav> <nav id="account"><a href="/user/user1">user1 (karma)</a> | <a href="/logout?apisecret=~.$apisecret.q~">logout</a></nav></header><div id="content">
<h2>Your threads</h2><div id="comments">
</div>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>var apisecret = '~.$apisecret.q~';</script><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

  $res = $cb->(GET 'http://localhost/submit', %headers);
  ok($res->is_success, 'submit');
  is($res->code, 200, '... status code');
  check_content($res->content, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Submit a new story - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a><a href="/replies" class="replies">replies</a></nav> <nav id="account"><a href="/user/user1">user1 (karma)</a> | <a href="/logout?apisecret=~.$apisecret.q~">logout</a></nav></header><div id="content">
<h2>Submit a new story</h2><div id="submitform">
<form name="f"><input value="-1" name="news_id" type="hidden"><label for="title">
title
</label>
<input value="" name="title" type="text" id="title" size="80"><br>
<label for="url">
url
</label>
<br>
<input value="" name="url" type="text" id="url" size="60"><br>
or if you don't have an url type some text<br>
<label for="text">
text
</label>
<textarea name="text" id="text" rows="10" cols="60"></textarea><input value="Submit" name="do_submit" type="button"></form>
</div>
<div id="errormsg">
</div>
<p>Submitting news is simpler using the <a href="javascript:window.location=%22http://lamernews.com/submit?u=%22+encodeURIComponent(document.location)+%22&amp;t=%22+encodeURIComponent(document.title)">bookmarklet</a> (drag the link to your browser toolbar)</p><script>
          $(function() {
            $("input[name=do_submit]").click(submit);
          });
      </script>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>var apisecret = '~.$apisecret.q~';</script><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

  $res = $cb->(POST 'http://localhost/api/submit', %headers,
               Content => [
                           apisecret => $apisecret,
                           title => 'New article',
                           text => 'Another article',
                           url => '',
                           news_id => '-1',
                          ]);
  ok($res->is_success, '/api/submit');
  is($res->code, 200, '... status code');
  $json = check_json($res->content, [ '"status":"ok"', '"news_id":2' ]);

  $res = $cb->(POST 'http://localhost/api/postcomment', %headers,
               Content => [
                           apisecret => $apisecret,
                           news_id => '2',
                           comment_id => '-1',
                           parent_id => '-1',
                           comment => 'comment',
                          ]);
  ok($res->is_success, '/api/postcomment');
  is($res->code, 200, '... status code');
  $json = check_json($res->content,
                     [ '"status":"ok"', qr!"news_id":"?2"?!, '"comment_id":1',
                       qr!"parent_id":"?-1"?!, '"op":"insert"',
                     ]);

  $res = $cb->(GET 'http://localhost/usercomments/user1/0', %headers);
  ok($res->is_success, 'usercomments user1');
  is($res->code, 200, '... status code');
  check_content($res->content, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
user1 comments - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a><a href="/replies" class="replies">replies</a></nav> <nav id="account"><a href="/user/user1">user1 (karma)</a> | <a href="/logout?apisecret=~.$apisecret.q~">logout</a></nav></header><div id="content">
<h2>user1 comments</h2><div id="comments">
<article style="margin-left:0px" id="2-1" data-comment-id="2-1" class="comment"><span class="avatar"><img src="http://gravatar.com/avatar/d41d8cd98f00b204e9800998ecf8427e?s=48&amp;d=mm"></span><span class="info"><span class="username"><a href="/user/user1">user1</a></span> some time ago. <a href="/comment/2/1" class="reply">link</a> <a href="/reply/2/1" class="reply">reply</a> 1 points <a href="#up" class="uparrow voted">&#9650;</a> <a href="#down" class="downarrow disabled">&#9660;</a><a href="/editcomment/2/1" class="reply">edit</a> (some minutes left)</span><pre>comment</pre></article>
</div>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>var apisecret = '~.$apisecret.q~';</script><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

  $res = $cb->(GET 'http://localhost/editnews/2', %headers);
  ok($res->is_success, 'editnews/2');
  is($res->code, 200, '... status code');
  check_content($res->content, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Edit news - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a><a href="/replies" class="replies">replies</a></nav> <nav id="account"><a href="/user/user1">user1 (karma)</a> | <a href="/logout?apisecret=~.$apisecret.q~">logout</a></nav></header><div id="content">
<article data-news-id="2"><a href="#up" class="uparrow voted">&#9650;</a> <h2><a href="/news/2">New article</a></h2> <address> <a href="/editnews/2">[edit]</a></address><a href="#down" class="downarrow disabled">&#9660;</a><p>1 up and 0 down, posted by <username><a href="/user/user1">user1</a></username> some time ago <a href="/news/2">1 comments</a></p></article>
<div id="submitform">
<form name="f"><input value="2" name="news_id" type="hidden"><label for="title">
title
</label>
<input value="New article" name="title" type="text" id="title" size="80"><br>
<label for="url">
url
</label>
<br>
<input value="" name="url" type="text" id="url" size="60"><br>
or if you don't have an url type some text<br>
<label for="text">
text
</label>
<textarea name="text" id="text" rows="10" cols="60">Another article</textarea><br>
<input value="1" name="del" type="checkbox">delete this news<br>
<input value="Edit" name="edit_news" type="button"></form>
</div>
<div id="errormsg">
</div>
<script>
            $(function() {
                $("input[name=edit_news]").click(submit);
            });
        </script>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>var apisecret = '~.$apisecret.q~';</script><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

  $res = $cb->(POST 'http://localhost/api/submit', %headers,
               Content => [
                           apisecret => $apisecret,
                           title => 'Newish article',
                           text => 'Another article (edited)',
                           url => '',
                           news_id => '2',
                          ]);
  ok($res->is_success, '/api/submit');
  is($res->code, 200, '... status code');
  $json = check_json($res->content, [ '"status":"ok"', '"news_id":2' ]);

  $res = $cb->(POST 'http://localhost/api/create_account',
               Content => [
                           username => 'user2',
                           password => 'password2',
                          ]);
  ok($res->is_success, 'create_account correct password');
  is($res->code, 200, '... status code');
  $json =
    check_json($res->content,
               [ '"status":"ok"', qr!"auth":"[0-9a-f]{40}"! ]);
  if ($json->{apisecret}) {
    like($json->{apisecret}, qr!^[0-9a-f]{40}$!, '... apisecret');
  } else {
    diag "/api/create_account doesn't return apisecret, nevermind\n";
  }

  my %headers2 = ( Cookie => 'auth='.$json->{auth} );

  $res = $cb->(GET 'http://localhost/reply/2/1', %headers2);
  ok($res->is_success, 'reply/2/1');
  is($res->code, 200, '... status code');
  $c = $res->content;
  ok($c =~ m!var apisecret = '([0-9a-f]{40})'!, '... apisecret');
  my $apisecret2 = $1; # note this is to handle the mock case

  check_content($c, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Reply to comment - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a><a href="/replies" class="replies">replies</a></nav> <nav id="account"><a href="/user/user2">user2 (karma)</a> | <a href="/logout?apisecret=~.$apisecret2.q~">logout</a></nav></header><div id="content">
<article data-news-id="2"><a href="#up" class="uparrow">&#9650;</a> <h2><a href="/news/2">Newish article</a></h2> <address></address><a href="#down" class="downarrow">&#9660;</a><p>1 up and 0 down, posted by <username><a href="/user/user1">user1</a></username> some time ago <a href="/news/2">1 comments</a></p></article>
<article style="margin-left:0px" id="2-1" data-comment-id="2-1" class="comment"><span class="avatar"><img src="http://gravatar.com/avatar/d41d8cd98f00b204e9800998ecf8427e?s=48&amp;d=mm"></span><span class="info"><span class="username"><a href="/user/user1">user1</a></span> some time ago. <a href="/comment/2/1" class="reply">link</a> <a href="/reply/2/1" class="reply">reply</a> 1 points <a href="#up" class="uparrow">&#9650;</a> <a href="#down" class="downarrow">&#9660;</a></span><pre>comment</pre></article><form name="f"><input value="2" name="news_id" type="hidden"><input value="-1" name="comment_id" type="hidden"><input value="1" name="parent_id" type="hidden"><textarea name="comment" rows="10" cols="60"></textarea><br>
<input value="Reply" name="post_comment" type="button"></form><div id="errormsg">
</div>
<script>
      $(function() {
        $("input[name=post_comment]").click(post_comment);
      });
    </script>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>var apisecret = '~.$apisecret2.q~';</script><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

  $res = $cb->(POST 'http://localhost/api/postcomment', %headers2,
               Content => [
                           apisecret => $apisecret2,
                           news_id => '2',
                           comment_id => '-1',
                           parent_id => '1',
                           comment => 'a reply',
                          ]);
  ok($res->is_success, '/api/postcomment');
  is($res->code, 200, '... status code');
  $json = check_json($res->content,
                     [ '"status":"ok"', qr!"news_id":"?2"?!, '"comment_id":2',
                       qr!"parent_id":"?1"?!, '"op":"insert"',
                     ]);

  $res = $cb->(POST 'http://localhost/api/votenews', %headers2,
               Content => [
                           apisecret => $apisecret2,
                           news_id => '2',
                           vote_type => "up",
                          ]);
  ok($res->is_success, '/api/votenews');
  is($res->code, 200, '... status code');
  is($res->content, '{"status":"ok"}', '... content');

  $res = $cb->(POST 'http://localhost/api/votecomment', %headers2,
               Content => [
                           apisecret => $apisecret2,
                           comment_id => '2-1',
                           vote_type => 'down',
                          ]);
  ok($res->is_success, '/api/votecomment');
  is($res->code, 200, '... status code');
  $json = check_json($res->content, [ '"status":"ok"', '"comment_id":"2-1"' ]);

  $res = $cb->(GET 'http://localhost/editcomment/2/2', %headers2);
  ok($res->is_success, '/editcomment/2/2');
  is($res->code, 200, '... status code');
  check_content($res->content, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Edit comment - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a><a href="/replies" class="replies">replies</a></nav> <nav id="account"><a href="/user/user2">user2 (karma)</a> | <a href="/logout?apisecret=~.$apisecret2.q~">logout</a></nav></header><div id="content">
<article data-news-id="2"><a href="#up" class="uparrow voted">&#9650;</a> <h2><a href="/news/2">Newish article</a></h2> <address></address><a href="#down" class="downarrow disabled">&#9660;</a><p>2 up and 0 down, posted by <username><a href="/user/user1">user1</a></username> some time ago <a href="/news/2">2 comments</a></p></article>
<article style="margin-left:0px" id="2-2" data-comment-id="2-2" class="comment"><span class="avatar"><img src="http://gravatar.com/avatar/d41d8cd98f00b204e9800998ecf8427e?s=48&amp;d=mm"></span><span class="info"><span class="username"><a href="/user/user2">user2</a></span> some time ago. <a href="/comment/2/2" class="reply">link</a> <a href="/reply/2/2" class="reply">reply</a> 1 points <a href="#up" class="uparrow voted">&#9650;</a> <a href="#down" class="downarrow disabled">&#9660;</a><a href="/editcomment/2/2" class="reply">edit</a> (some minutes left)</span><pre>a reply</pre></article><form name="f"><input value="2" name="news_id" type="hidden"><input value="2" name="comment_id" type="hidden"><input value="-1" name="parent_id" type="hidden"><textarea name="comment" rows="10" cols="60">a reply</textarea><br>
<input value="Edit" name="post_comment" type="button"></form><div id="errormsg">
</div>
<note>Note: to remove the comment remove all the text and press Edit.</note><script>
      $(function() {
        $("input[name=post_comment]").click(post_comment);
      });
    </script>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>var apisecret = '~.$apisecret2.q~';</script><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

  $res = $cb->(POST 'http://localhost/api/delnews', %headers,
               Content => [
                           apisecret => $apisecret,
                           news_id => '2',
                          ]);
  ok($res->is_success, '/api/delnews');
  is($res->code, 200, '... status code');
  $json = check_json($res->content, [ '"status":"ok"', '"news_id":-1' ]);

  $res = $cb->(POST 'http://localhost/api/postcomment', %headers,
               Content => [
                           apisecret => $apisecret,
                           news_id => '2',
                           comment_id => '1',
                           parent_id => '-1',
                           comment => '',
                          ]);
  ok($res->is_success, '/api/postcomment');
  is($res->code, 200, '... status code');
  $json = check_json($res->content,
                     [ '"status":"ok"', qr!"news_id":"?2"?!, '"comment_id":1',
                       qr!"parent_id":"?-1"?!, '"op":"delete"',
                     ]);

  $res = $cb->(GET 'http://localhost/news/2');
  ok($res->is_success, 'news/2 deleted');
  is($res->code, 200, '... status code');
  check_content($res->content, '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Newish article - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a></nav> <nav id="account"><a href="/login">login / register</a></nav></header><div id="content">
<section id="newslist"><article class="deleted">[deleted news]</article></section><br>
<div id="comments">
<article style="margin-left:0px" class="commented deleted">[comment deleted]</article><article style="margin-left:60px" id="2-2" data-comment-id="2-2" class="comment"><span class="avatar"><img src="http://gravatar.com/avatar/d41d8cd98f00b204e9800998ecf8427e?s=48&amp;d=mm"></span><span class="info"><span class="username"><a href="/user/user2">user2</a></span> some time ago. <a href="/comment/2/2" class="reply">link</a>  1 points <a href="#up" class="uparrow">&#9650;</a> <a href="#down" class="downarrow">&#9660;</a></span><pre>a reply</pre></article>
</div>
<script>
       $(function() {
         $("input[name=post_comment]").click(post_comment);
       });
     </script>
</div>
<footer><a href="http://github.com/antirez/lamernews">source code</a> | <a href="/rss">rss feed</a></footer><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
', '... content');

  $res = $cb->(GET 'http://localhost/comment/2/1');
  ok($res->is_success, 'comment/2/1');
  is($res->code, 200, '... status code');
  check_content($res->content, q~<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>
Newish article - Lamer News
</title>
<meta name="robots" content="nofollow">
<link rel="stylesheet" href="/css/style.css?v=8" type="text/css">
<link rel="shortcut icon" href="/images/favicon.png">
<script src="//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js"></script><script src="/js/app.js?v=8"></script>
</head>
<body>
<div class="container">
<header><h1><a href="/">Lamer News</a> <small>0.9.3</small></h1><nav><a href="/">top</a>
<a href="/latest/0">latest</a>
<a href="/submit">submit</a></nav> <nav id="account"><a href="/login">login / register</a></nav></header><div id="content">
<section id="newslist"><article class="deleted">[deleted news]</article></section><div class="singlecomment">
<article style="margin-left:0px" class="commented deleted">[comment deleted]</article>
</div>
<div class="commentreplies">
<h2>Replies</h2>
</div>
<div id="comments">
<article style="margin-left:0px" id="2-2" data-comment-id="2-2" class="comment"><span class="avatar"><img src="http://gravatar.com/avatar/d41d8cd98f00b204e9800998ecf8427e?s=48&amp;d=mm"></span><span class="info"><span class="username"><a href="/user/user2">user2</a></span> 3 seconds ago. <a href="/comment/2/2" class="reply">link</a>  1 points <a href="#up" class="uparrow">&#9650;</a> <a href="#down" class="downarrow">&#9660;</a></span><pre>a reply</pre></article>
</div>
</div>
<footer><a href="http://github.com/beanz/camelnews">source code</a> | <a href="/rss">rss feed</a></footer><script>setKeyboardNavigation();</script>
</div>
</body>
</html>
~, '... content');

};

done_testing;
waitpid $pid, 0 if ($pid);

sub check_location {
  my ($res, $expected, $desc) = @_;
  my $actual = $res->header('Location');
  $actual =~ s!^https?://[^/]+!!;
  is $actual, $expected, ($desc || '... location');
}

sub check_content {
  my ($actual, $expected, $desc) = @_;
  eq_or_diff canon($actual), canon($expected), $desc or
    diag 'check_content: '.(join ' ', caller)."\n";
}

sub check_json {
  my ($content, $tests) = @_;
  my $json;
  eval { $json = $j->decode($content); };
  ok($json, '... json decode');
  foreach my $t (@$tests) {
    like($content, qr![{,]$t[,}]!, '... json: '.$t);
  }
  $json;
}

sub slurp {
  my $file = shift;
  open my $fh, $file or die "Failed to open $file: $!\n";
  local $/;
  my $c = <$fh>;
  close $fh;
  return $c;
}

sub canon {
  my $c = shift;
  $c =~ s!127\.0\.0\.1:\d+!localhost!g;
  $c =~ s!/beanz/camelnews!/antirez/lamernews!g;
  $c =~ s!localhost\K/(?=\s)!!g;
  $c =~ s!</(?:username|span)>\K[^<]+ago! some time ago!g;
  $c =~ s!\d+ minutes left!some minutes left!g;
  $c =~ s!\bnow\b!some time ago!g;
  $c =~ s!user[12] \K\(\d+\)!(karma)!g;
  $c =~ # reorder html attributes
    s!<([^\s/>]+)\s+([^>]+)>!"<$1 ".(join "\n  ", sort split /\s+/, $2).'>'!eg;
  $c =~ s!<[^>]+>\K(?=[^\n])!\n!g;
  $c =~ s![^\n]\K<!\n<!g;
  $c =~ s!(\s+)!$1 =~ /\n/ ? "\n" : ' '!eg;
  $c;
}

sub connections {
  [
   [
    # create_account user1
    [ recvredis => [qw/exists username.to.id:user1/] ],
    [ sendredis => ':0' ],
    [ recvredis => [qw/incr users.count/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hmset user:1/, id => 1, username => 'user1',
                    salt => qr!^[0-9a-f]{40}$!,
                    password => qr!^[0-9a-f]{40}$!,
                    ctime => qr!^\d+$!, karma => '1', about => '',
                    email => '', auth => qr!^[0-9a-f]{40}$!,
                    apisecret => qr!^[0-9a-f]{40}$!, flags => '',
                    karma_incr_time => qr!^\d+$!] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/set username.to.id:user1 1/] ],
    [ sendredis => '+OK' ],
    [ recvredis => [set => qr!^auth:[0-9a-f]{40}$!, 1] ],
    [ sendredis => '+OK' ],

    # login user1
    [ recvredis => [qw/get username.to.id:user1/] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [qw/hgetall user:1/], ],
    [ sendredis =>
      ['*' =>
       [
        id => 1, username => 'user1',
        salt => '6b72a45358fb859b391d2d1ce2226fa61a74ed9e',
        password => 'e78514e6c6101112846d2b9f60dc5cdf918c108d',
        ctime => $time, karma => 1, about => '', email => '',
        auth => '9b37ef4d421b50957c45afcf588b877896e176d4',
        apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
        flags => '', karma_incr_time => $ktime
       ] ] ],

    # submit news:1
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => 1] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis =>
      ['*' =>
       [
        id => 1, username => 'user1',
        salt => '6b72a45358fb859b391d2d1ce2226fa61a74ed9e',
        password => 'e78514e6c6101112846d2b9f60dc5cdf918c108d',
        ctime => $time, karma => 1, about => '', email => '',
        auth => '9b37ef4d421b50957c45afcf588b877896e176d4',
        apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
        flags => '', karma_incr_time => $ktime
       ] ] ],
    [ recvredis => [qw/ttl user:1:submitted_recently/] ],
    [ sendredis => ':-1' ],
    [ recvredis => [qw/incr news.count/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hmset news:1/, id => 1, title => 'Test Article',
                    url => 'text://some text', user_id => 1,
                    ctime => qr!^\d{10}$!, score => 0, rank => 0,
                    up => 0, down => 0, comments => 0 ] ],
    [ sendredis => '+OK' ],
    [ recvredis => [hgetall => 'news:1'] ],
    [ sendredis =>
      ['*' => [ id => 1, title => 'New article',
                url => 'text://Another article', user_id => 1,
                ctime => $time, score => 0, rank => 0, up => 0,
                down => 0, comments => 0 ] ] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:1 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:1 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.up:1 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:1 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zadd news.up:1 /, qr!^\d{10}$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hincrby news:1 up 1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd user.saved:1/, qr!^\d{10}$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrange news.up:1 0 -1/] ],
    [ sendredis => ['*' => [ '1' ] ] ],
    [ recvredis => [qw/zrange news.down:1 0 -1/] ],
    [ sendredis => '*0' ],
    [ recvredis => [qw/hmset news:1 score 0.5 rank/, qr!^[\.0-9]+$! ] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd user.posted:1/, qr!^\d+$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd news.cron/, qr!^\d+$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '1'] ],
    [ sendredis => ':0' ],

    # /
    [ recvredis => [qw/zcard news.top/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrevrange news.top 0 29/] ],
    [ sendredis => ['*' => ['1']] ],
    [ recvredis => [qw/hgetall news:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, title => 'Test Article',
                      url => 'text://some text', user_id => 1,
                      ctime => $time, score => 1, rank => '0.0103086555529132',
                      up => 1, down => 0, comments => 0 ]] ],
    [ recvredis => [qw/hmset news:1 rank/, qr!^[\.0-9]+$!] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],

    # /css
    # /js

    # /rss
    [ recvredis => [qw/zcard news.cron/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrevrange news.cron 0 99/] ],
    [ sendredis => ['*' => ['1']] ],
    [ recvredis => [qw/hgetall news:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, title => 'Test Article',
                      url => 'text://some text', user_id => 1,
                      ctime => $time, score => 1, rank => '0.0103086555529132',
                      up => 1, down => 0, comments => 0]] ],
    [ recvredis => [qw/hmset news:1 rank/, qr!^[\.0-9]+$!] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1' ] ],

    # /latest redirect

    # /latest/0
    [ recvredis => [qw/zcard news.cron/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrevrange news.cron 0 99/] ],
    [ sendredis => ['*' => ['1']] ],
    [ recvredis => [qw/hgetall news:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, title => 'Test Article',
                      url => 'text://some text', user_id => 1,
                      ctime => $time, score => 1, rank => '0.0103086555529132',
                      up => 1, down => 0, comments => 0]] ],
    [ recvredis => [qw/hmset news:1 rank/, qr!^[\.0-9]+$!] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],

    # /replies
    # /saved/0

    # /usercomments/user2/0
    [ recvredis => [qw/get username.to.id:user2/] ],
    [ sendredis => '$-1' ],

    # /submit
    # /logout

    # /news/1
    [ recvredis => [qw/hgetall news:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, title => 'Test Article',
                      url => 'text://some text', user_id => 1,
                      ctime => $time, score => 1, rank => '0.00801850412002884',
                      up => 1, down => 0, comments => 0]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/hgetall user:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/hgetall thread:comment:1/] ],
    [ sendredis => '*0' ],

    # /news/2
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => '*0' ],

    # /comment/1/2
    [ recvredis => [qw/hgetall news:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, title => 'Test Article',
                      url => 'text://some text', user_id => 1,
                      ctime => $time, score => 1, rank => '0.00488120052790944',
                      up => 1, down => 0, comments => 0]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/hget thread:comment:1 2/] ],
    [ sendredis => '$-1' ],

    # /comment/2/2
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => '*0' ],

    # /reply/1/1
    # /editcomment/1/1
    # /editnews/1

    # /user/user1
    [ recvredis => [qw/get username.to.id:user1/] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [qw/hgetall user:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/zcard user.posted:1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zcard user.comments:1/] ],
    [ sendredis => ':0' ],

    # /user/user2
    [ recvredis => [qw/get username.to.id:user2/] ],
    [ sendredis => '$-1' ],

    # /login?username=user1&password=incorrect
    [ recvredis => [qw/get username.to.id:user1/] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [qw/hgetall user:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime]] ],

    # /saved/0
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/zcard user.saved:1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrevrange user.saved:1 0 9/] ],
    [ sendredis => ['*' => ['1']] ],
    [ recvredis => [qw/hgetall news:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, title => 'Test Article',
                      url => 'text://some text', user_id => 1,
                      ctime => $time, score => 1, rank => '0.00488120052790944',
                      up => 1, down => 0, comments => 0]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:1 1/] ],
    [ sendredis => ['$' => $time] ],
    [ recvredis => [qw/zscore news.down:1 1/] ],
    [ sendredis => '$-1' ],

    # /replies
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/zcard user.comments:1/] ],
    [ sendredis => ':0' ],
    [ recvredis => [qw/zrevrange user.comments:1 0 9/] ],
    [ sendredis => '*0' ],
    [ recvredis => [qw/hset user:1 replies 0/] ],
    [ sendredis => ':0' ],

    # /submit
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],

    # /api/submit
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [qw/ttl user:1:submitted_recently/] ],
    [ sendredis => ':-1' ],
    [ recvredis => [qw/incr news.count/] ],
    [ sendredis => ':2' ],
    [ recvredis => [qw/hmset news:2/, id => 2, title => 'New article',
                    url => 'text://Another article', user_id => 1,
                    ctime => qr!^\d{10}$!, score => 0, rank => 0,
                    up => 0, down => 0, comments => 0] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'New article',
                      url => 'text://Another article', user_id => 1,
                      ctime => $time, score => 0, rank => 0,
                      up => 0, down => 0, comments => 0]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.up:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zadd news.up:2/, qr!^\d{10}$!, '1'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hincrby news:2 up 1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd user.saved:1/, qr!^\d{10}$!, '2'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrange news.up:2 0 -1/] ],
    [ sendredis => ['*' => [1]] ],
    [ recvredis => [qw/zrange news.down:2 0 -1/] ],
    [ sendredis => '*0' ],
    [ recvredis => [qw/hmset news:2 score 0.5 rank/, qr!^[\.0-9]+$!] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '2'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd user.posted:1/, qr!^\d+$!, '2'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd news.cron/, qr!^\d+$!, '2'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '2'] ],
    [ sendredis => ':0' ],

    # /api/postcomment
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'New article',
                      url => 'text://Another article', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 1, down => 0,
                      comments => 0]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 1/] ],
    [ sendredis => ['$' => $time] ],
    [ recvredis => [qw/zscore news.down:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/hincrby thread:comment:2 nextid 1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hset thread:comment:2 1/, qr!^{"ctime":\d+,"body":"comment","up":\[1\],"user_id":"1","score":0,"parent_id":"-1"}$!] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hincrby news:2 comments 1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zadd user.comments:1/, qr!^\d+$!, '2-1'] ],
    [ sendredis => ':1' ],

    # /usercomments/user1/0
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [qw/get username.to.id:user1/] ],
    [ sendredis => ['$' => 1] ],
    [ recvredis => [qw/hgetall user:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [qw/zcard user.comments:1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrevrange user.comments:1 0 9/] ],
    [ sendredis => ['*' => ['2-1']] ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [qw/hgetall user:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],

    # /editnews/2
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'New article',
                      url => 'text://Another article', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 1, down => 0,
                      comments => 1]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 1/] ],
    [ sendredis => ['$' => $time] ],
    [ recvredis => [qw/zscore news.down:2 1/] ],
    [ sendredis => '$-1' ],

    # /api/submit
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'New article',
                      url => 'text://Another article', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 1, down => 0,
                      comments => 1]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 1/] ],
    [ sendredis => ['$' => $time] ],
    [ recvredis => [qw/zscore news.down:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/hmset news:2/, title => 'Newish article',
                    url => 'text://Another article (edited)'] ],
    [ sendredis => '+OK' ],

    # /api/create_account
    [ recvredis => [qw/exists username.to.id:user2/] ],
    [ sendredis => ':0' ],
    [ recvredis => [qw/incr users.count/] ],
    [ sendredis => ':2' ],
    [ recvredis => [qw/hmset user:2/, id => 2, username => 'user2',
                    salt => qr!^[0-9a-f]{40}$!,
                    password => qr!^[0-9a-f]{40}$!,
                    ctime => qr!^\d+$!, karma => '1', about => '',
                    email => '', auth => qr!^[0-9a-f]{40}$!,
                    apisecret => qr!^[0-9a-f]{40}$!, flags => '',
                    karma_incr_time => qr!^\d+$!] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/set username.to.id:user2 2/] ],
    [ sendredis => '+OK' ],
    [ recvredis => [set => qr!^auth:[0-9a-f]{40}$!, '2'] ],
    [ sendredis => '+OK' ],

    # /reply/2/1
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '2'] ],
    [ recvredis => [hgetall => 'user:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, username => 'user2',
                      salt => '91169b4c7062accffe3900e1dc9e14e976f3e0c1',
                      password => '9c1a21a40138837fb4c227c89ad467e3c7361bea',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'ce6a425191040684e89d7e49ad108c3f42686647',
                      apisecret => 'ed7c2cf86e273f88bcd28251d3eb5e0c718e2bd3',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'Newish article',
                      url => 'text://Another article (edited)', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 1, down => 0,
                      comments => 1]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [qw/hgetall user:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],

    # /api/postcomment
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '2'] ],
    [ recvredis => [hgetall => 'user:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, username => 'user2',
                      salt => '91169b4c7062accffe3900e1dc9e14e976f3e0c1',
                      password => '9c1a21a40138837fb4c227c89ad467e3c7361bea',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'ce6a425191040684e89d7e49ad108c3f42686647',
                      apisecret => 'ed7c2cf86e273f88bcd28251d3eb5e0c718e2bd3',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'Newish article',
                      url => 'text://Another article (edited)', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 1, down => 0,
                      comments => 1]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [qw/hincrby thread:comment:2 nextid 1/] ],
    [ sendredis => ':2' ],
    [ recvredis => [qw/hset thread:comment:2 2/, qr!^\{"ctime":\d+,"body":"a reply","up":\[2\],"user_id":"2","score":0,"parent_id":"1"}$!] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hincrby news:2 comments 1/] ],
    [ sendredis => ':2' ],
    [ recvredis => [qw/zadd user.comments:2/, qr!^\d+$!, '2-2'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/exists user:1/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hincrby user:1 replies 1/] ],
    [ sendredis => ':1' ],

    # /api/votenews
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '2'] ],
    [ recvredis => [hgetall => 'user:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, username => 'user2',
                      salt => '91169b4c7062accffe3900e1dc9e14e976f3e0c1',
                      password => '9c1a21a40138837fb4c227c89ad467e3c7361bea',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'ce6a425191040684e89d7e49ad108c3f42686647',
                      apisecret => 'ed7c2cf86e273f88bcd28251d3eb5e0c718e2bd3',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/hgetall news:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'Newish article',
                      url => 'text://Another article (edited)', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 1, down => 0,
                      comments => 2]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.up:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zscore news.down:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/zadd news.up:2/, qr!^\d{10}$!, '2'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/hincrby news:2 up 1/] ],
    [ sendredis => ':2' ],
    [ recvredis => [qw/zadd user.saved:2/, qr!^\d{10}$!, '2'] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrange news.up:2 0 -1/] ],
    [ sendredis => ['*' => ['1','2']] ],
    [ recvredis => [qw/zrange news.down:2 0 -1/] ],
    [ sendredis => '*0' ],
    [ recvredis => [hmset => 'news:2', score => 1, rank => qr!^[\.0-9]+$!] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/zadd news.top/, qr!^[\.0-9]+$!, '2'] ],
    [ sendredis => ':0' ],
    [ recvredis => [qw/hincrby user:2 karma -1/] ],
    [ sendredis => ':0' ],
    [ recvredis => [qw/hincrby user:1 karma 1/] ],
    [ sendredis => ':4' ],

    # /api/votecomment
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '2'] ],
    [ recvredis => [hgetall => 'user:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, username => 'user2',
                      salt => '91169b4c7062accffe3900e1dc9e14e976f3e0c1',
                      password => '9c1a21a40138837fb4c227c89ad467e3c7361bea',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'ce6a425191040684e89d7e49ad108c3f42686647',
                      apisecret => 'ed7c2cf86e273f88bcd28251d3eb5e0c718e2bd3',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [qw/hset thread:comment:2 1/, qr!^{"ctime":\d+,"body":"comment","down":\[2\],"up":\[1\],"user_id":"1","score":0,"parent_id":"-1"}$!] ],
    [ sendredis => ':0' ],

    # /editcomment/2/2
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '2'] ],
    [ recvredis => [hgetall => 'user:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, username => 'user2',
                      salt => '91169b4c7062accffe3900e1dc9e14e976f3e0c1',
                      password => '9c1a21a40138837fb4c227c89ad467e3c7361bea',
                      ctime => $time, karma => 1, about => '', email => '',
                      auth => 'ce6a425191040684e89d7e49ad108c3f42686647',
                      apisecret => 'ed7c2cf86e273f88bcd28251d3eb5e0c718e2bd3',
                      flags => '', karma_incr_time => $ktime]] ],
    [ recvredis => [hgetall => 'news:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'Newish article',
                      url => 'text://Another article (edited)', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 2, down => 0,
                      comments => 2]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 2/] ],
    [ sendredis => ['$' => $time] ],
    [ recvredis => [qw/zscore news.down:2 2/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/hget thread:comment:2 2/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"a reply","up":[2],"user_id":"2","score":0,"parent_id":"1"}'] ],
    [ recvredis => [hgetall => 'user:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, username => 'user2',
                      salt => '91169b4c7062accffe3900e1dc9e14e976f3e0c1',
                      password => '9c1a21a40138837fb4c227c89ad467e3c7361bea',
                      ctime => $time, karma => 0, about => '', email => '',
                      auth => 'ce6a425191040684e89d7e49ad108c3f42686647',
                      apisecret => 'ed7c2cf86e273f88bcd28251d3eb5e0c718e2bd3',
                      flags => '', karma_incr_time => $ktime]] ],

    # /api/delnews
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 4, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [hgetall => 'news:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'Newish article',
                      url => 'text://Another article (edited)', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 2, down => 0,
                      comments => 2]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 1/] ],
    [ sendredis => ['$' => $time] ],
    [ recvredis => [qw/zscore news.down:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [hmset => 'news:2', del => 1] ],
    [ sendredis => '+OK' ],
    [ recvredis => [qw/zrem news.top 2/] ],
    [ sendredis => ':1' ],
    [ recvredis => [qw/zrem news.cron 2/] ],
    [ sendredis => ':1' ],

    # /api/postcomment (delete)
    [ recvredis => [get => qr!^auth:[0-9a-f]{40}$!] ],
    [ sendredis => ['$' => '1'] ],
    [ recvredis => [hgetall => 'user:1'] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => 'a8da48809f99800c1e6bd5933086134edf377b78',
                      password => '372fd9286caed14834465bbd309fe7e1a36530fe',
                      ctime => $time, karma => 4, about => '', email => '',
                      auth => 'd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5',
                      apisecret => 'a3f9381b0f3f0201ad762f913623070d0e2335db',
                      flags => '', karma_incr_time => $ktime, replies => 0]] ],
    [ recvredis => [hgetall => 'news:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'Newish article',
                      url => 'text://Another article (edited)', user_id => 1,
                      ctime => $time, score => '0.5',
                      rank => '0.00515432777645662', up => 2, down => 0,
                      comments => 2, del => 1]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/zscore news.up:2 1/] ],
    [ sendredis => ['$' => $time] ],
    [ recvredis => [qw/zscore news.down:2 1/] ],
    [ sendredis => '$-1' ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","down":[2],"up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [qw/hget thread:comment:2 1/] ],
    [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","down":[2],"up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ recvredis => [hset => 'thread:comment:2', 1 => '{"ctime":'.$time.',"body":"comment","del":1,"down":[2],"up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
    [ sendredis => ':0' ],
    [ recvredis => [qw/hincrby news:2 comments -1/] ],
    [ sendredis => ':1' ],

    # /news/2
    [ recvredis => [hgetall => 'news:2'] ],
    [ sendredis => ['*' =>
                    [ id => 2, title => 'Newish article',
                      url => 'text://Another article (edited)', user_id => 1,
                      ctime => $time, score => 1, rank => '0.0103070807944016',
                      up => 2, down => 0, comments => 1, del => 1]] ],
    [ recvredis => [qw/hget user:1 username/] ],
    [ sendredis => ['$' => 'user1'] ],
    [ recvredis => [qw/hgetall thread:comment:2/] ],
    [ sendredis => ['*' =>
                    [ nextid => 2,
                      1 => '{"ctime":'.$time.',"body":"comment","del":1,"down":[2],"up":[1],"user_id":"1","score":0,"parent_id":"-1"}',
                      2 => '{"ctime":'.$time.',"body":"a reply","up":[2],"user_id":"2","score":0,"parent_id":"1"}']] ],
    [ recvredis => [qw/hgetall user:1/] ],
    [ sendredis => ['*' =>
                    [ id => 1, username => 'user1',
                      salt => '09f4675e12299c9513046612c09f87d04511ad86',
                      password => '282ae99397c03876543728819ce259ae547ecda5',
                      ctime => $time, karma => 2, about => '', email => '',
                      auth => '7a5c29d3677dd03d8aa2e03b93af82a9860b417d',
                      apisecret => 'e69d6052ba38ad632a40502d99521ed74d0fe1b9',
                      flags => '', karma_incr_time => $ktime, replies => 1]] ],
    [ recvredis => [qw/hgetall user:2/] ],
    [ sendredis => ['*' =>
                    [ id => 2, username => 'user2',
                      salt => '3d4b6fb7611b2b82c4f9161c6a423a9af6540c65',
                      password => 'afea2e1264dd5a023fbeec8beaee81e99f184fd8',
                      ctime => $time, karma => 0, about => '', email => '',
                      auth => '8efcd1255910e284f3963487ddab8f2804d8aff1',
                      apisecret => '7cf39f6cd309e18a97d8ff294851cc759ad81745',
                      flags => '', karma_incr_time => $ktime]] ],

   # /comment/2/1
   [ recvredis => [qw/hgetall news:2/] ],
   [ sendredis => ['*' =>
                   [ id => 2, title => 'Newish article',
                     url => 'text://Another article (edited)', user_id => 1,
                     ctime => $time, score => 1, rank => '0.0103062935463583',
                     up => 2, down => 0, comments => 1, del => 1]] ],
   [ recvredis => [qw/hget user:1 username/] ],
   [ sendredis => ['$' => 'user1'] ],
   [ recvredis => [qw/hget thread:comment:2 1/] ],
   [ sendredis => ['$' => '{"ctime":'.$time.',"body":"comment","del":1,"down":[2],"up":[1],"user_id":"1","score":0,"parent_id":"-1"}'] ],
   [ recvredis => [qw/hgetall user:1/] ],
   [ sendredis => ['*' =>
                   [ id => 1, username => 'user1',
                     salt => 'ad7d8013b696a673afc2cc62fca39a1f866a88db',
                     password => '041545cb3e79d60825623a3ab4875dc36e69a563',
                     ctime => $time, karma => 2, about => '', email => '',
                     auth => '3921b12ca2774e31672e331b965885513c95cbd3',
                     apisecret => '258a110308de8951e453664572578f66b56797a6',
                     flags => '', karma_incr_time => $ktime, replies => 1]] ],
   [ recvredis => [qw/hgetall thread:comment:2/] ],
   [ sendredis => ['*' =>
                   [ nextid => 2,
                     1 => '{"ctime":'.$time.',"body":"comment","del":1,"down":[2],"up":[1],"user_id":"1","score":0,"parent_id":"-1"}',
                     2 => '{"ctime":'.$time.',"body":"a reply","up":[2],"user_id":"2","score":0,"parent_id":"1"}']] ],
   [ recvredis => [qw/hgetall user:2/] ],
   [ sendredis => ['*' =>
                   [ id => 2, username => 'user2',
                     salt => 'b609512b678a2d5a1517e86f37385ddb41560101',
                     password => '17ec4f036696119addbd38585aeafa9a39b7f047',
                     ctime => $time, karma => 0, about => '', email => '',
                     auth => '7369f7ad27919bb46503577d994ede4bcbf136df',
                     apisecret => '7c9fcc1479fe4220956d3a8f3bced9ae9e329f3b',
                     flags => '', karma_incr_time => $ktime]] ],
   ]
  ]
}
