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
use AnyEvent::MockTCPServer;
use AnyEvent;
use JSON;
use Test::SharedFork;

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
  eval { $server = AnyEvent::MockTCPServer->new(connections => $connections); };
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
  ok($res->is_success, 'create_account correct password');
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
    check_json($res->content, [ '"status":"ok"', qr!"auth":"[0-9a-f]{40}"! ]);
  my %headers2 = ( Cookie => 'auth='.$json->{auth} );

  $res = $cb->(GET 'http://localhost/reply/2/1', %headers2);
  ok($res->is_success, 'reply/2/1');
  is($res->code, 200, '... status code');
  $c = $res->content;
  ok($c =~ m!var apisecret = '([0-9a-f]{40})'!, '... apisecret');
  my $apisecret2 = $1;
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
<header><h1><a href="/">Lamer News</a> <small>0.9.2</small></h1><nav><a href="/">top</a>
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
    [ recv => "*2\r\n\$6\r\nexists\r\n\$20\r\nusername.to.id:user1\r\n",
      'exists user1' ],
    [ send => ":0\r\n", 'no' ],
    [ recv => "*2\r\n\$4\r\nincr\r\n\$11\r\nusers.count\r\n",
      'incr users.count' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*26\r\n\$5\r\nhmset\r\n\$6\r\nuser:1\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\n", 'hmset user:1 i' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:1 ii' ],
    [ recv => "\$8\r\npassword\r\n\$40\r\n", 'hmset user:1 iii' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:1 iv' ],
    [ recv => "\$5\r\nctime\r\n\$10\r\n", 'hmset user:1 v' ],
    [ recvline => qr!^\d+$!, 'hmset user:1 vi' ],
    [ recv => "\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n",
      'hmset user:1 vii' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:1 viii' ],
    [ recv => "\$9\r\napisecret\r\n\$40\r\n", 'hmset user:1 ix' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:1 x' ],
    [ recv => "\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n", 'hmset user:1 xi' ],
    [ recvline => qr!^\d+$!, 'hmset user:1 xii' ],
    [ send => "+OK\r\n", 'ok' ],
    [ recv => "*3\r\n\$3\r\nset\r\n\$20\r\nusername.to.id:user1\r\n\$1\r\n1\r\n",
      'set username.to.id:user1 1' ],
    [ send => "+OK\r\n", 'ok' ],
    [ recv => "*3\r\n\$3\r\nset\r\n\$45\r\n", 'set auth:... 1 i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'set auth:... 1 ii' ],
    [ recv => "\$1\r\n1\r\n", 'set auth:... 1 iii' ],
    [ send => "+OK\r\n", 'ok' ],

    # login user1
    [ recv => "*2\r\n\$3\r\nget\r\n\$20\r\nusername.to.id:user1\r\n", '' ],
    [ send => "\$1\r\n1\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", '' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\n6b72a45358fb859b391d2d1ce2226fa61a74ed9e\r\n\$8\r\npassword\r\n\$40\r\ne78514e6c6101112846d2b9f60dc5cdf918c108d\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n9b37ef4d421b50957c45afcf588b877896e176d4\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n", '' ],

    # submit news:1
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$3\r\nttl\r\n\$25\r\nuser:1:submitted_recently\r\n",
      'user:1:submitted_recently' ],
    [ send => ":-1\r\n", 'not recently' ],
    [ recv => "*2\r\n\$4\r\nincr\r\n\$10\r\nnews.count\r\n", 'incr news.count' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*22\r\n\$5\r\nhmset\r\n\$6\r\nnews:1\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$12\r\nTest Article\r\n\$3\r\nurl\r\n\$16\r\ntext://some text\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n",
      'hmset news:1 i' ],
    [ recvline => qr!^\d{10}$!, 'hmset news:1 ii (ctime)' ],
    [ recv => "\$5\r\nscore\r\n\$1\r\n0\r\n\$4\r\nrank\r\n\$1\r\n0\r\n\$2\r\nup\r\n\$1\r\n0\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'hmset news:1 iii' ],
    [ send => "+OK\r\n", 'hmset ok' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:1\r\n", 'hgetall news:1' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$11\r\nNew article\r\n\$3\r\nurl\r\n\$22\r\ntext://Another article\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n0\r\n\$4\r\nrank\r\n\$1\r\n0\r\n\$2\r\nup\r\n\$1\r\n0\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'news:1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1 username' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:1\r\n\$1\r\n1\r\n",
      'zscore news.up:1' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:1\r\n\$1\r\n1\r\n",
      'zscore news.down:1' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:1\r\n\$1\r\n1\r\n",
      'zscore news.up:1' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:1\r\n\$1\r\n1\r\n",
      'zscore news.down:1' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$9\r\nnews.up:1\r\n\$10\r\n",
      'zadd news.up:1 i'],
    [ recvline => qr!^\d{10}$!, 'zadd news.up:1 ii (ctime)' ],
    [ recv => "\$1\r\n1\r\n", 'zadd news.up:1 iii' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nnews:1\r\n\$2\r\nup\r\n\$1\r\n1\r\n",
      'hincrby news:1 up 1' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$12\r\nuser.saved:1\r\n\$10\r\n",
      'zadd user.saved:1 0' ],
    [ recvline => qr!^\d{10}$!, 'zadd user.saved:1 ii (ctime)' ],
    [ recv => "\$1\r\n1\r\n", 'zadd user.saved:1 iii' ],
    [ send => ":1\r\n", 'zadd ok' ],
    [ recv => "*4\r\n\$6\r\nzrange\r\n\$9\r\nnews.up:1\r\n\$1\r\n0\r\n\$2\r\n-1\r\n",
      'zrange news.up:1' ],
    [ send => "*1\r\n\$1\r\n1\r\n", '1' ],
    [ recv => "*4\r\n\$6\r\nzrange\r\n\$11\r\nnews.down:1\r\n\$1\r\n0\r\n\$2\r\n-1\r\n",
      'zrange news.down:1' ],
    [ send => "*0\r\n", '0' ],
    [ recv => "*6\r\n\$5\r\nhmset\r\n\$6\r\nnews:1\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n", 'hmset news:1 score+rank i' ],
    [ recvline => qr!^\$\d+$!, 'hmset news:1 score+rank ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'hmset news:1 score+rank iii' ],
    [ send => "+OK\r\n", 'ok' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$8\r\nnews.top\r\n", 'zadd news.top i' ],
    [ recvline => qr!^\$\d+$!, 'zadd news.top ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'zadd news.top iii' ],
    [ recv => "\$1\r\n1\r\n", 'zadd news.top iv' ],
    [ send => ":1\r\n", 'zadd news.top reply' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$13\r\nuser.posted:1\r\n\$10\r\n",
      'zadd user.posted:1' ],
    [ recvline => qr!^\d+$!, 'zadd user.posted:1 ii' ],
    [ recv => "\$1\r\n1\r\n", 'zadd user.posted:1 iii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$9\r\nnews.cron\r\n\$10\r\n",
      'zadd news.cron i' ],
    [ recvline => qr!^\d+$!, 'zadd news.cron ii' ],
    [ recv => "\$1\r\n1\r\n", 'zadd news.cron iii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$8\r\nnews.top\r\n", 'zadd news.top i' ],
    [ recvline => qr!^\$\d+$!, 'zadd news.top ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'zadd news.top iii' ],
    [ recv => "\$1\r\n1\r\n", 'zadd news.top iv' ],
    [ send => ":0\r\n", '' ],

    # /
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$8\r\nnews.top\r\n", 'zcard news.top' ],
    [ send => ":1\r\n", '1 article news' ],
    [ recv => "*4\r\n\$9\r\nzrevrange\r\n".
              "\$8\r\nnews.top\r\n\$1\r\n0\r\n\$2\r\n29\r\n",
      'zrevrange news.top' ],
    [ send => "*1\r\n\$1\r\n1\r\n", '1 article news' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:1\r\n", 'hgetall news:1' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$12\r\nTest Article\r\n\$3\r\nurl\r\n\$16\r\ntext://some text\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$18\r\n0.0103086555529132\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'news:1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1 username' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],

    # /css
    # /js

    # /rss
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$9\r\nnews.cron\r\n", 'zcard news.cron' ],
    [ send => ":1\r\n", '1 article news' ],
    [ recv => "*4\r\n\$9\r\nzrevrange\r\n".
              "\$9\r\nnews.cron\r\n\$1\r\n0\r\n\$2\r\n99\r\n",
      'zrevrange news.cron' ],
    [ send => "*1\r\n\$1\r\n1\r\n", '1 article news' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:1\r\n", 'hgetall news:1' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$12\r\nTest Article\r\n\$3\r\nurl\r\n\$16\r\ntext://some text\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$18\r\n0.0103086555529132\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'news:1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1 username' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],

    # /latest redirect

    # /latest/0
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$9\r\nnews.cron\r\n", 'zcard news.cron' ],
    [ send => ":1\r\n", '1 article news' ],
    [ recv => "*4\r\n\$9\r\nzrevrange\r\n".
              "\$9\r\nnews.cron\r\n\$1\r\n0\r\n\$2\r\n99\r\n",
      'zrevrange news.cron' ],
    [ send => "*1\r\n\$1\r\n1\r\n", '1 article news' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:1\r\n", 'hgetall news:1' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$12\r\nTest Article\r\n\$3\r\nurl\r\n\$16\r\ntext://some text\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$18\r\n0.0103086555529132\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'news:1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1 username' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],

    # /replies
    # /saved/0

    # /usercomments/user2/0
    [ recv => "*2\r\n\$3\r\nget\r\n\$20\r\nusername.to.id:user2\r\n",
      'nget username.to.id:user2' ],
    [ send => "\$-1\r\n", 'no such user' ],

    # /submit
    # /logout

    # /news/1
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:1\r\n", 'hgetall news:1' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$12\r\nTest Article\r\n\$3\r\nurl\r\n\$16\r\ntext://some text\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$19\r\n0.00801850412002884\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n", 'news:1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\nd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user1 (all)' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$16\r\nthread:comment:1\r\n",
      'hgetall thread:comment:1' ],
    [ send => "*0\r\n", 'no comments' ],

    # /news/2
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n",
      'hgetall news:2' ],
    [ send => "*0\r\n", 'no such news' ],

    # /comment/1/2
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:1\r\n", 'hgetall news:1' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$12\r\nTest Article\r\n\$3\r\nurl\r\n\$16\r\ntext://some text\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$19\r\n0.00488120052790944\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n", 'news:1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:1\r\n\$1\r\n2\r\n",
      'hget thread:comment:1' ],
    [ send => "\$-1\r\n", 'no such comment' ],

    # /comment/2/2
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", 'hgetall news:2' ],
    [ send => "*0\r\n", 'no such news' ],

    # /reply/1/1
    # /editcomment/1/1
    # /editnews/1

    # /user/user1
    [ recv => "*2\r\n\$3\r\nget\r\n\$20\r\nusername.to.id:user1\r\n",
      'username.to.id:user1' ],
    [ send => "\$1\r\n1\r\n", 'user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\nd6d5c367d3bd17aa9a088cf3a13c8a21d17ad5e5\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$13\r\nuser.posted:1\r\n",
      'user.posted:1' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$15\r\nuser.comments:1\r\n", '' ],
    [ send => ":0\r\n", '0' ],

    # /user/user2
    [ recv => "*2\r\n\$3\r\nget\r\n\$20\r\nusername.to.id:user2\r\n",
      'username.to.id:user2' ],
    [ send => "\$-1\r\n", 'no such user' ],

    # /login?username=user1&password=incorrect
    [ recv => "*2\r\n\$3\r\nget\r\n\$20\r\nusername.to.id:user1\r\n",
      'username.to.id:user1' ],
    [ send => "\$1\r\n1\r\n", 'user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],

    # /saved/0
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$12\r\nuser.saved:1\r\n",
      'zcard user.saved:1' ],
    [ send => ":1\r\n", '1 post' ],
    [ recv => "*4\r\n\$9\r\nzrevrange\r\n\$12\r\nuser.saved:1\r\n\$1\r\n0\r\n\$1\r\n9\r\n",
      'zrevrange user.saved:1' ],
    [ send => "*1\r\n\$1\r\n1\r\n", 'post 1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:1\r\n", 'hgetall news:1' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$5\r\ntitle\r\n\$12\r\nTest Article\r\n\$3\r\nurl\r\n\$16\r\ntext://some text\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$19\r\n0.00488120052790944\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'news:1' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1 username' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:1\r\n\$1\r\n1\r\n",
      'zscore news.up:1' ],
    [ send => "\$10\r\n".$time."\r\n", 'news.up.1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:1\r\n\$1\r\n1\r\n",
      'zscore news.down:1' ],
    [ send => "\$-1\r\n", 'news.down:1 does not exist' ],

    # /replies
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$15\r\nuser.comments:1\r\n",
      'zcard user.comments:1' ],
    [ send => ":0\r\n", '0 comments' ],
    [ recv => "*4\r\n\$9\r\nzrevrange\r\n\$15\r\nuser.comments:1\r\n\$1\r\n0\r\n\$1\r\n9\r\n", 'zrevrange user.comments:1' ],
    [ send => "*0\r\n", '0 comments' ],
    [ recv => "*4\r\n\$4\r\nhset\r\n\$6\r\nuser:1\r\n\$7\r\nreplies\r\n\$1\r\n0\r\n",
      'hset user:1 replies 0' ],
    [ send => ":0\r\n", '0' ],

    # /submit
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],

    # /api/submit
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$3\r\nttl\r\n\$25\r\nuser:1:submitted_recently\r\n",
      'user:1:submitted_recently' ],
    [ send => ":-1\r\n", 'not recently' ],
    [ recv => "*2\r\n\$4\r\nincr\r\n\$10\r\nnews.count\r\n", 'incr news.count' ],
    [ send => ":2\r\n", '2' ],
    [ recv => "*22\r\n\$5\r\nhmset\r\n\$6\r\nnews:2\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$11\r\nNew article\r\n\$3\r\nurl\r\n\$22\r\ntext://Another article\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n",
      'hmset news:2 i' ],
    [ recvline => qr!^\d{10}$!, 'hmset news:2 ii (ctime)' ],
    [ recv => "\$5\r\nscore\r\n\$1\r\n0\r\n\$4\r\nrank\r\n\$1\r\n0\r\n\$2\r\nup\r\n\$1\r\n0\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'hmset news:2 iii' ],
    [ send => "+OK\r\n", 'hmset ok' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", 'hgetall news:2' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$11\r\nNew article\r\n\$3\r\nurl\r\n\$22\r\ntext://Another article\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n0\r\n\$4\r\nrank\r\n\$1\r\n0\r\n\$2\r\nup\r\n\$1\r\n0\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n",
      'news:2' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1 username' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n1\r\n",
      'zscore news.up:2' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n1\r\n",
      'zscore news.down:2' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n1\r\n",
      'zscore news.up:2' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n1\r\n",
      'zscore news.down:2' ],
    [ send => "\$-1\r\n", '-1' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$9\r\nnews.up:2\r\n\$10\r\n",
      'zadd news.up:2 i'],
    [ recvline => qr!^\d{10}$!, 'zadd news.up:2 ii (ctime)' ],
    [ recv => "\$1\r\n1\r\n", 'zadd news.up:2 iii' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nnews:2\r\n\$2\r\nup\r\n\$1\r\n1\r\n",
      'hincrby news:2 up 1' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$12\r\nuser.saved:1\r\n\$10\r\n",
      'zadd user.saved:1 0' ],
    [ recvline => qr!^\d{10}$!, 'zadd user.saved:1 ii (ctime)' ],
    [ recv => "\$1\r\n2\r\n", 'zadd user.saved:1 iii' ],
    [ send => ":1\r\n", 'zadd ok' ],
    [ recv => "*4\r\n\$6\r\nzrange\r\n\$9\r\nnews.up:2\r\n\$1\r\n0\r\n\$2\r\n-1\r\n",
      'zrange news.up:2' ],
    [ send => "*1\r\n\$1\r\n1\r\n", '1' ],
    [ recv => "*4\r\n\$6\r\nzrange\r\n\$11\r\nnews.down:2\r\n\$1\r\n0\r\n\$2\r\n-1\r\n",
      'zrange news.down:2' ],
    [ send => "*0\r\n", '0' ],
    [ recv => "*6\r\n\$5\r\nhmset\r\n\$6\r\nnews:2\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n", 'hmset news:2 score+rank i' ],
    [ recvline => qr!^\$\d+$!, 'hmset news:2 score+rank ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'hmset news:2 score+rank iii' ],
    [ send => "+OK\r\n", 'ok' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$8\r\nnews.top\r\n", 'zadd news.top i' ],
    [ recvline => qr!^\$\d+$!, 'zadd news.top ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'zadd news.top iii' ],
    [ recv => "\$1\r\n2\r\n", 'zadd news.top iv' ],
    [ send => ":1\r\n", 'zadd news.top reply' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$13\r\nuser.posted:1\r\n\$10\r\n",
      'zadd user.posted:1' ],
    [ recvline => qr!^\d+$!, 'zadd user.posted:1 ii' ],
    [ recv => "\$1\r\n2\r\n", 'zadd user.posted:1 iii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$9\r\nnews.cron\r\n\$10\r\n",
      'zadd news.cron i' ],
    [ recvline => qr!^\d+$!, 'zadd news.cron ii' ],
    [ recv => "\$1\r\n2\r\n", 'zadd news.cron iii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$8\r\nnews.top\r\n", 'zadd news.top i' ],
    [ recvline => qr!^\$\d+$!, 'zadd news.top ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'zadd news.top iii' ],
    [ recv => "\$1\r\n2\r\n", 'zadd news.top iv' ],
    [ send => ":0\r\n", '' ],

    # /api/postcomment
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", 'hgetall news:2' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$11\r\nNew article\r\n\$3\r\nurl\r\n\$22\r\ntext://Another article\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n\$19\r\n0.00515432777645662\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n0\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1 username' ],
    [ send => "\$5\r\nuser1\r\n", 'user1' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n1\r\n",
      'zscore news.up:2' ],
    [ send => "\$10\r\n".$time."\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n1\r\n",
      'zscore news.down:2' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$16\r\nthread:comment:2\r\n\$6\r\nnextid\r\n\$1\r\n1\r\n",
      'hincrby thread:comment:2 nextid' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*4\r\n\$4\r\nhset\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n\$87\r\n", 'hset thread:comment:2 i' ],
    [ recvline => qr!^{"ctime":\d+,"body":"comment","up":\[1\],"user_id":"1","score":0,"parent_id":"-1"}$!,
      'hset thread:comment:2 ii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nnews:2\r\n\$8\r\ncomments\r\n\$1\r\n1\r\n",
      'hincrby news:2 comments 1' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$15\r\nuser.comments:1\r\n\$10\r\n",
      'zadd user.comments:1 i' ],
    [ recvline => qr!^\d+$!, 'zadd user.comments:1 ii' ],
    [ recv => "\$3\r\n2-1\r\n", 'zadd user.comments:1 iii' ],
    [ send => ":1\r\n", '' ],

    # /usercomments/user1/0
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$3\r\nget\r\n\$20\r\nusername.to.id:user1\r\n", '' ],
    [ send => "\$1\r\n1\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", '' ],
    [ send => "*26\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n3\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n\$7\r\nreplies\r\n\$1\r\n0\r\n", '' ],
    [ recv => "*2\r\n\$5\r\nzcard\r\n\$15\r\nuser.comments:1\r\n", '' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$9\r\nzrevrange\r\n\$15\r\nuser.comments:1\r\n\$1\r\n0\r\n\$1\r\n9\r\n", '' ],
    [ send => "*1\r\n\$3\r\n2-1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$87\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", '' ],
    [ send => "*26\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n3\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n\$7\r\nreplies\r\n\$1\r\n0\r\n", '' ],

    # /editnews/2
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$11\r\nNew article\r\n\$3\r\nurl\r\n\$22\r\ntext://Another article\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n\$19\r\n0.00515432777645662\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$10\r\n".$time."\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$-1\r\n", '' ],

    # /api/submit
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$11\r\nNew article\r\n\$3\r\nurl\r\n\$22\r\ntext://Another article\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n\$19\r\n0.00515432777645662\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$10\r\n".$time."\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*6\r\n\$5\r\nhmset\r\n\$6\r\nnews:2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n", '' ],
    [ send => "+OK\r\n", '' ],

    # /api/create_account
    [ recv => "*2\r\n\$6\r\nexists\r\n\$20\r\nusername.to.id:user2\r\n", '' ],
    [ send => ":0\r\n", '' ],
    [ recv => "*2\r\n\$4\r\nincr\r\n\$11\r\nusers.count\r\n", '' ],
    [ send => ":2\r\n", '' ],
    [ recv => "*26\r\n\$5\r\nhmset\r\n\$6\r\nuser:2\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\n", 'hmset user:2 i' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:2 ii' ],
    [ recv => "\$8\r\npassword\r\n\$40\r\n", 'hmset user:2 iii' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:2 iv' ],
    [ recv => "\$5\r\nctime\r\n\$10\r\n", 'hmset user:2 v' ],
    [ recvline => qr!^\d+$!, 'hmset user:2 vi' ],
    [ recv => "\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n",
      'hmset user:2 vii' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:2 viii' ],
    [ recv => "\$9\r\napisecret\r\n\$40\r\n", 'hmset user:2 ix' ],
    [ recvline => qr!^[0-9a-f]{40}$!, 'hmset user:2 x' ],
    [ recv => "\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n", 'hmset user:2 xi' ],
    [ recvline => qr!^\d+$!, 'hmset user:2 xii' ],
    [ send => "+OK\r\n", '' ],
    [ recv => "*3\r\n\$3\r\nset\r\n\$20\r\nusername.to.id:user2\r\n\$1\r\n2\r\n", '' ],
    [ send => "+OK\r\n", '' ],
    [ recv => "*3\r\n\$3\r\nset\r\n\$45\r\n", 'set auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'set auth:... ii' ],
    [ recv => "\$1\r\n2\r\n", 'set auth:... iii' ],
    [ send => "+OK\r\n", '' ],

    # /reply/2/1
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n2\r\n", 'user:2' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:2\r\n", 'hgetall user:2' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\n91169b4c7062accffe3900e1dc9e14e976f3e0c1\r\n\$8\r\npassword\r\n\$40\r\n9c1a21a40138837fb4c227c89ad467e3c7361bea\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\nce6a425191040684e89d7e49ad108c3f42686647\r\n\$9\r\napisecret\r\n\$40\r\ned7c2cf86e273f88bcd28251d3eb5e0c718e2bd3\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n\$19\r\n0.00515432777645662\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$87\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", '' ],
    [ send => "*26\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n3\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n\$7\r\nreplies\r\n\$1\r\n0\r\n", '' ],

    # /api/postcomment
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n2\r\n", 'user:2' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:2\r\n", 'hgetall user:2' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\n91169b4c7062accffe3900e1dc9e14e976f3e0c1\r\n\$8\r\npassword\r\n\$40\r\n9c1a21a40138837fb4c227c89ad467e3c7361bea\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\nce6a425191040684e89d7e49ad108c3f42686647\r\n\$9\r\napisecret\r\n\$40\r\ned7c2cf86e273f88bcd28251d3eb5e0c718e2bd3\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$time."\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n\$19\r\n0.00515432777645662\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$87\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$87\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$16\r\nthread:comment:2\r\n\$6\r\nnextid\r\n\$1\r\n1\r\n", '' ],
    [ send => ":2\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nhset\r\n\$16\r\nthread:comment:2\r\n\$1\r\n2\r\n\$86\r\n", 'hset thread:comment:2 i' ],
    [ recvline => qr!^\{"ctime":\d+,"body":"a reply","up":\[2\],"user_id":"2","score":0,"parent_id":"1"}$!, 'hset thread:comment:2 ii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nnews:2\r\n\$8\r\ncomments\r\n\$1\r\n1\r\n", '' ],
    [ send => ":2\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$15\r\nuser.comments:2\r\n\$10\r\n", 'zadd user.comments:2 i' ],
    [ recvline => qr!^\d+$!, 'zadd user.comments:2 ii' ],
    [ recv => "\$3\r\n2-2\r\n", 'zadd user.comments:2 iii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*2\r\n\$6\r\nexists\r\n\$6\r\nuser:1\r\n", '' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nuser:1\r\n\$7\r\nreplies\r\n\$1\r\n1\r\n", '' ],
    [ send => ":1\r\n", '' ],

    # /api/votenews
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n2\r\n", 'user:2' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:2\r\n", 'hgetall user:2' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\n91169b4c7062accffe3900e1dc9e14e976f3e0c1\r\n\$8\r\npassword\r\n\$40\r\n9c1a21a40138837fb4c227c89ad467e3c7361bea\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\nce6a425191040684e89d7e49ad108c3f42686647\r\n\$9\r\napisecret\r\n\$40\r\ned7c2cf86e273f88bcd28251d3eb5e0c718e2bd3\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$time."\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$3\r\n0.5\r\n\$4\r\nrank\r\n\$19\r\n0.00515432777645662\r\n\$2\r\nup\r\n\$1\r\n1\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n2\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$9\r\nnews.up:2\r\n\$10\r\n",
      'zadd news.up:2 i'],
    [ recvline => qr!^\d{10}$!, 'zadd news.up:2 ii (ctime)' ],
    [ recv => "\$1\r\n2\r\n", 'zadd news.up:2 iii' ],
    [ send => ":1\r\n", '1' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nnews:2\r\n\$2\r\nup\r\n\$1\r\n1\r\n", '' ],
    [ send => ":2\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$12\r\nuser.saved:2\r\n\$10\r\n",
      'zadd user.saved:2 0' ],
    [ recvline => qr!^\d{10}$!, 'zadd user.saved:2 ii (ctime)' ],
    [ recv => "\$1\r\n2\r\n", 'zadd user.saved:2 iii' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*4\r\n\$6\r\nzrange\r\n\$9\r\nnews.up:2\r\n\$1\r\n0\r\n\$2\r\n-1\r\n", '' ],
    [ send => "*2\r\n\$1\r\n1\r\n\$1\r\n2\r\n", '' ],
    [ recv => "*4\r\n\$6\r\nzrange\r\n\$11\r\nnews.down:2\r\n\$1\r\n0\r\n\$2\r\n-1\r\n", '' ],
    [ send => "*0\r\n", '' ],
    [ recv => "*6\r\n\$5\r\nhmset\r\n\$6\r\nnews:2\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n", 'hmset news:2 score+rank i' ],
    [ recvline => qr!^\$\d+$!, 'hmset news:2 score+rank ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'hmset news:2 score+rank iii' ],
    [ send => "+OK\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nzadd\r\n\$8\r\nnews.top\r\n", 'zadd news.top i' ],
    [ recvline => qr!^\$\d+$!, 'zadd news.top ii' ],
    [ recvline => qr!^[\.0-9]+$!, 'zadd news.top iii' ],
    [ recv => "\$1\r\n2\r\n", 'zadd news.top iv' ],
    [ send => ":0\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nuser:2\r\n\$5\r\nkarma\r\n\$2\r\n-1\r\n", '' ],
    [ send => ":0\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nuser:1\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n", '' ],
    [ send => ":4\r\n", '' ],

    # /api/votecomment
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n2\r\n", 'user:2' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:2\r\n", 'hgetall user:2' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\n91169b4c7062accffe3900e1dc9e14e976f3e0c1\r\n\$8\r\npassword\r\n\$40\r\n9c1a21a40138837fb4c227c89ad467e3c7361bea\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\nce6a425191040684e89d7e49ad108c3f42686647\r\n\$9\r\napisecret\r\n\$40\r\ned7c2cf86e273f88bcd28251d3eb5e0c718e2bd3\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$time."\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$87\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$87\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nhset\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n\$98\r\n",
      'hset thread:comment:2 i' ],
    [ recvline => qr!^{"ctime":\d+,"body":"comment","down":\[2\],"up":\[1\],"user_id":"1","score":0,"parent_id":"-1"}$!,
      'hset thread:comment:2 ii' ],
    [ send => ":0\r\n", '' ],

    # /editcomment/2/2
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n2\r\n", 'user:2' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:2\r\n", 'hgetall user:2' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\n91169b4c7062accffe3900e1dc9e14e976f3e0c1\r\n\$8\r\npassword\r\n\$40\r\n9c1a21a40138837fb4c227c89ad467e3c7361bea\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n1\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\nce6a425191040684e89d7e49ad108c3f42686647\r\n\$9\r\napisecret\r\n\$40\r\ned7c2cf86e273f88bcd28251d3eb5e0c718e2bd3\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$time."\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$18\r\n0.0103070807944016\r\n\$2\r\nup\r\n\$1\r\n2\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n2\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$10\r\n1321192584\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n2\r\n", '' ],
    [ send => "\$86\r\n{\"ctime\":".$time.",\"body\":\"a reply\",\"up\":[2],\"user_id\":\"2\",\"score\":0,\"parent_id\":\"1\"}\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:2\r\n", '' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\nf8bfab6057362d6d7b265f1ea48b9ec49cb748f4\r\n\$8\r\npassword\r\n\$40\r\n508aab8bcce8dc15b2af920eb31dc9b466241301\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n0\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n0971a4daf92aaeccd906ae389f61e2acfa15ad8c\r\n\$9\r\napisecret\r\n\$40\r\na90d2ba21b228ec36a0ddd0e8349e67d838d3388\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n", '' ],

    # /api/delnews
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$18\r\n0.0103070807944016\r\n\$2\r\nup\r\n\$1\r\n2\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n2\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$10\r\n1321200741\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*4\r\n\$5\r\nhmset\r\n\$6\r\nnews:2\r\n\$3\r\ndel\r\n\$1\r\n1\r\n", '' ],
    [ send => "+OK\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nzrem\r\n\$8\r\nnews.top\r\n\$1\r\n2\r\n", '' ],
    [ send => ":1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nzrem\r\n\$9\r\nnews.cron\r\n\$1\r\n2\r\n", '' ],
    [ send => ":1\r\n", '' ],

    # /api/postcomment (delete)
    [ recv => "*2\r\n\$3\r\nget\r\n\$45\r\n", 'get auth:... i' ],
    [ recvline => qr!^auth:[0-9a-f]{40}$!, 'get auth:... ii' ],
    [ send => "\$1\r\n1\r\n", 'belongs to user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", 'hgetall user:1' ],
    [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\na8da48809f99800c1e6bd5933086134edf377b78\r\n\$8\r\npassword\r\n\$40\r\n372fd9286caed14834465bbd309fe7e1a36530fe\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n5abaad9749326aaf9f984a2ab2f6f315e8f6223a\r\n\$9\r\napisecret\r\n\$40\r\na3f9381b0f3f0201ad762f913623070d0e2335db\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n",
      'user:1' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", '' ],
    [ send => "*20\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$18\r\n0.0103070807944016\r\n\$2\r\nup\r\n\$1\r\n2\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n2\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n", '' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$9\r\nnews.up:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$10\r\n1321200741\r\n", '' ],
    [ recv => "*3\r\n\$6\r\nzscore\r\n\$11\r\nnews.down:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$-1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$98\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"down\":[2],\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n", '' ],
    [ send => "\$98\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"down\":[2],\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ recv => "*4\r\n\$4\r\nhset\r\n\$16\r\nthread:comment:2\r\n\$1\r\n1\r\n\$106\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"del\":1,\"down\":[2],\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n", '' ],
    [ send => ":0\r\n", '' ],
    [ recv => "*4\r\n\$7\r\nhincrby\r\n\$6\r\nnews:2\r\n\$8\r\ncomments\r\n\$2\r\n-1\r\n", '' ],
    [ send => ":1\r\n", '' ],

    # /news/2
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nnews:2\r\n", 'hgetall news:2' ],
    [ send => "*22\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$5\r\ntitle\r\n\$14\r\nNewish article\r\n\$3\r\nurl\r\n\$31\r\ntext://Another article (edited)\r\n\$7\r\nuser_id\r\n\$1\r\n1\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nscore\r\n\$1\r\n1\r\n\$4\r\nrank\r\n\$18\r\n0.0103070807944016\r\n\$2\r\nup\r\n\$1\r\n2\r\n\$4\r\ndown\r\n\$1\r\n0\r\n\$8\r\ncomments\r\n\$1\r\n1\r\n\$3\r\ndel\r\n\$1\r\n1\r\n", '' ],
    [ recv => "*3\r\n\$4\r\nhget\r\n\$6\r\nuser:1\r\n\$8\r\nusername\r\n",
      'hget user:1' ],
    [ send => "\$5\r\nuser1\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$16\r\nthread:comment:2\r\n",
      'hgetall thread:comment:2' ],
    [ send => "*6\r\n\$6\r\nnextid\r\n\$1\r\n2\r\n\$1\r\n1\r\n\$106\r\n{\"ctime\":".$time.",\"body\":\"comment\",\"del\":1,\"down\":[2],\"up\":[1],\"user_id\":\"1\",\"score\":0,\"parent_id\":\"-1\"}\r\n\$1\r\n2\r\n\$86\r\n{\"ctime\":".$time.",\"body\":\"a reply\",\"up\":[2],\"user_id\":\"2\",\"score\":0,\"parent_id\":\"1\"}\r\n", '' ],
    [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:1\r\n", '' ],
    [ send => "*26\r\n\$2\r\nid\r\n\$1\r\n1\r\n\$8\r\nusername\r\n\$5\r\nuser1\r\n\$4\r\nsalt\r\n\$40\r\n09f4675e12299c9513046612c09f87d04511ad86\r\n\$8\r\npassword\r\n\$40\r\n282ae99397c03876543728819ce259ae547ecda5\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n2\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n7a5c29d3677dd03d8aa2e03b93af82a9860b417d\r\n\$9\r\napisecret\r\n\$40\r\ne69d6052ba38ad632a40502d99521ed74d0fe1b9\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n\$7\r\nreplies\r\n\$1\r\n1\r\n", '' ],
      [ recv => "*2\r\n\$7\r\nhgetall\r\n\$6\r\nuser:2\r\n", '' ],
  [ send => "*24\r\n\$2\r\nid\r\n\$1\r\n2\r\n\$8\r\nusername\r\n\$5\r\nuser2\r\n\$4\r\nsalt\r\n\$40\r\n3d4b6fb7611b2b82c4f9161c6a423a9af6540c65\r\n\$8\r\npassword\r\n\$40\r\nafea2e1264dd5a023fbeec8beaee81e99f184fd8\r\n\$5\r\nctime\r\n\$10\r\n".$time."\r\n\$5\r\nkarma\r\n\$1\r\n0\r\n\$5\r\nabout\r\n\$0\r\n\r\n\$5\r\nemail\r\n\$0\r\n\r\n\$4\r\nauth\r\n\$40\r\n8efcd1255910e284f3963487ddab8f2804d8aff1\r\n\$9\r\napisecret\r\n\$40\r\n7cf39f6cd309e18a97d8ff294851cc759ad81745\r\n\$5\r\nflags\r\n\$0\r\n\r\n\$15\r\nkarma_incr_time\r\n\$10\r\n".$ktime."\r\n", '' ],
   ]
  ]
}
