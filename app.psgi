#!/usr/bin/perl
use warnings;
use strict;
use feature ":5.10";
use Comments;
use Crypt::PBKDF2;
use Digest::MD5 qw/md5_hex/;
use Digest::SHA qw/sha1_hex/;
use Data::Show qw/show/;
use JSON;
use HTMLGen;
use Plack::Builder;
use Plack::Request;
use Redis::hiredis;

unless (caller) {
  require Plack::Runner;
  Plack::Runner->run(@ARGV, $0);
}

my $cfg = do 'app_config.pl' or die "Config file error: $@\n";
our $VERSION = '0.9.2';

our %ct =
  (
   gif => 'image/gif',
   png => 'image/png',
   js => 'text/javascript',
   css => 'text/css',
  );

my $todo;
my $r;
my $j;
my $h;
my $comments;
my $user;
my $req;
my $app =
  sub {
    my $env = shift;
    $req = Plack::Request->new($env);
    $r = Redis::hiredis->new(host => $cfg->{RedisHost},
                             port => $cfg->{RedisPort}) unless ($r);
    $h = HTMLGen->new(header => \&header, footer => \&footer) unless ($h);
    $j = JSON->new unless ($j);
    $comments =
      Comments->new(redis => $r,
                    namespace => 'comment',
                    sort_proc => sub {
                      my ($c, $level) = @_;
                      # TODO: calculate scores once
                      [
                       sort {
                         my $ascore = compute_comment_score($a);
                         my $bscore = compute_comment_score($b);
                         if ($ascore == $bscore) {
                           # If score is the same favor newer comments
                          $b->{'ctime'} <=> $a->{'ctime'}
                         } else {
                           # If score is different order by score.
                           # FIXME: do something smarter favouring
                           # newest comments but only in the short
                           # time.
                           $bscore <=> $ascore
                         }
                       } @$c
                      ]
                    }) unless ($comments);
    $user = auth_user($req->cookies->{auth});
    increment_karma_if_needed($user) if ($user);
    my $p = err('Not found');
    show $req->method.' '.$req->path_info;
    given ($req->method) {
      when ('GET') {
        given ($req->path_info) {
          when ('/') {
            $p = top();
          }
          when ('/rss') {
            $p = [200, ['text/xml'], [rss()]];
          }
          when ('/latest') {
            return redirect(302, '/latest/0');
          }
          when (qr!^/latest/(\d+)$!) {
            $p = latest($1);
          }
          when (qr!^/saved/(\d+)$!) {
            $p = saved($1);
          }
          when (qr!^/usercomments/(.*)/(\d+)$!) {
            $p = usercomments($1, $2);
          }
          when ('/replies') {
            $p = replies();
          }
          when ('/login') {
            $p = login();
          }
          when ('/submit') {
            $p = submit();
          }
          when ('/logout') {
            $p = logout();
          }
          when (qr!^/news/(\d+)$!) {
            $p = news($1);
          }
          when (qr!^/comment/(\d+)/(\d+)$!) {
            $p = comment($1, $2);
          }
          when (qr!^/reply/(\d+)/(\d+)$!) {
            $p = reply($1, $2);
          }
          when (qr!^/editcomment/(\d+)/(\d+)$!) {
            $p = editcomment($1, $2);
          }
          when (qr!^/editnews/(\d+)$!) {
            $p = editnews($1);
          }
          when (qr!^/user/(.+)$!) {
            $p = user($1);
          }
          when ('/api/login') {
            $p = api_login();
          }
          when (qr!^/api/getnews/(\w+)/(\d+)/(\d+)$!) {
            $p = api_getnews($1, $2, $3);
          }
          when (qr!^/api/getcomments/(\d+)$!) {
            $p = api_getcomments($1);
          }
          when (qr!^/(?:css|js|images)/.*\.([a-z]+)$!) {
            my $ct = $ct{$1};
            if (/\.\./ or !defined $ct) {
              return err('Not found');
            } else {
              open my $fh, 'public'.$_ or return err('Not found');
              $p = [ 200, ['Content-Type' => $ct], $fh ]
            }
          }
        }
      }
      when ('POST') {
        given ($req->path_info) {
          when ('/api/logout') {
            $p = api_logout();
          }
          when ('/api/create_account') {
            $p = api_create_account();
          }
          when ('/api/submit') {
            $p = api_submit();
          }
          when ('/api/delnews') {
            $p = api_delnews();
          }
          when ('/api/votenews') {
            $p = api_votenews();
          }
          when ('/api/postcomment') {
            $p = api_postcomment();
          }
          when ('/api/updateprofile') {
            $p = api_updateprofile();
          }
          when ('/api/votecomment') {
            $p = api_votecomment();
          }
        }
      }
    }
    return $p if (ref $p);
    return [200,
            [
             'Content-Type' => ($req->path_info =~ m!^/api/! ?
                                'application/json' : 'text/html'),
            ],
            [$p]];
  };

sub top {
  $h->set_title('Top News - '.$cfg->{SiteName});
  my ($news, $numitems) = get_top_news();
  $h->page($h->h2('Top News').news_list_to_html($news));
}

sub rss {
  my ($news, $count) = get_latest_news();
  $h->rss(version => '2.0', 'xmlns:atom' => 'http://www.w3.org/2005/Atom',
    $h->channel(
      $h->title($cfg->{SiteName}).' '.
      $h->link($req->base).' '.
      $h->description('Description pending').' '.
      news_list_to_rss($news)
    )
  );
}

sub latest {
  my ($start) = @_;
  $h->set_title('Latest News - '.$cfg->{SiteName});
  my %paginate =
    (
     get => sub { my ($start, $count) = @_; get_latest_news($start, $count); },
     render => sub { my ($item) = @_; news_to_html($item); },
     start => $start,
     perpage => $cfg->{LatestNewsPerPage},
     link => '/latest/$',
    );
  $h->page(
    $h->h2('Latest news').
    $h->section(id => 'newslist', list_items(\%paginate))
  );
}

sub saved {
  my ($start) = @_;
  return redirect(302, '/login') unless ($user);
  $h->set_title('Saved news - '.$cfg->{SiteName});
  my %paginate =
    (
     get => sub {
       my ($start, $count) = @_;
       get_saved_news($user->{'id'}, $start, $count);
     },
     render => sub {
       my ($item) = @_;
       news_to_html($item);
     },
     start => $start,
     perpage => $cfg->{SavedNewsPerPage},
     link => '/saved/$',
    );
  $h->page($h->h2('Your saved news').
           $h->section(id => 'newslist', list_items(\%paginate)));
}

sub usercomments {
  my ($username, $start) = @_;
  my $u = get_user_by_username($username);
  return err('Non existing user', 404) unless ($u);

  $h->set_title(HTMLGen::entities($u->{'username'}).' comments - '.
                $cfg->{SiteName});
  my %paginate =
    (
     get => sub {
       my ($start, $count) = @_;
       get_user_comments($u->{'id'}, $start, $count);
     },
     render => sub {
       my ($comment) = @_;
       my $u = get_user_by_id($comment->{'user_id'}) || $cfg->{DeletedUser};
       comment_to_html($comment, $u);
     },
     start => $start,
     perpage => $cfg->{UserCommentsPerPage},
     link => '/usercomments/'.HTMLGen::urlencode($u->{'username'}).'/$',
    );

  $h->page(
    $h->h2(HTMLGen::entities($u->{'username'}),' comments').
    $h->div(id => 'comments', list_items(\%paginate))
  );
}

sub replies {
  return redirect(302, '/login') unless ($user);
  my ($comments,$count) =
    get_user_comments($user->{'id'}, 0, $cfg->{SubthreadsInRepliesPage});
  $r->hset('user:'.$user->{'id'}, 'replies', 0);
  $h->set_title('Your threads - '.$cfg->{SiteName});
  $h->page(
    $h->h2('Your threads').
    $h->div(id => 'comments',
            (join '', map { render_comment_subthread($_) } @$comments))
  );
}

sub login {
  $h->set_title('Login - '.$cfg->{SiteName});
  $h->page(
    $h->div(id => 'login',
      $h->form(name => 'f',
        $h->label(for => 'username', 'username').
        $h->inputtext(id => 'username', name => 'username').
        $h->label(for => 'password', 'password').
        $h->inputpass(id => 'password', name => 'password').$h->br.
        $h->checkbox(name => 'register', value => '1').
        'create account'.$h->br.
        $h->submit(name => 'do_login', value => 'Login')
      )
    ).
    $h->div(id => 'errormsg', '').
    $h->script('
      $(function() {
        $("form[name=f]").submit(login);
      });
    ')
  );
}

sub err {
  my ($message, $code, $type) = @_;
  [$code||404,
   ['Content-Type' => $type||'text/plain'],
   [$message||'Not found']]
}

sub redirect {
  my $code = shift;
  my $uri = uri_for(@_);
  [$code, ['Location' => $uri], []]
}

sub uri_for {
  my ($path, $args) = @_;
  my $uri = $req->base;
  $path =~ s!^/!! if ($uri->path =~ m!/$!);
  $uri->path($uri->path.$path);
  $uri->query_form(@$args) if $args;
  $uri
}

sub submit {
  return redirect(302, '/login') unless ($user);
  $h->set_title('Submit a new story - '.$cfg->{SiteName});
  $h->page(
    $h->h2('Submit a new story').
      $h->div(id => 'submitform',
        $h->form(name => 'f',
          $h->inputhidden(name => 'news_id', value => -1).
          $h->label(for => 'title', 'title').
          $h->inputtext(id => 'title', name => 'title', size => 80,
                        value => ($req->param('t') ?
                                  HTMLGen::entities($req->param('t')) :
                                  '')).$h->br.
          $h->label(for => 'url', 'url').$h->br.
          $h->inputtext(id => 'url', name => 'url', size => 60,
                        value => ($req->param('u') ?
                                  HTMLGen::entities($req->param('u')) :
                                  '')).$h->br.
            "or if you don't have an url type some text".
          $h->br.
          $h->label(for => 'text', 'text').
          $h->textarea(id => 'text', name => 'text', cols => 60, rows => 10,'').
          $h->button(name => 'do_submit', value => 'Submit')
        )
      ).
      $h->div(id => 'errormsg', '').
      $h->p(
        'Submitting news is simpler using the '.
        $h->a(href => 'javascript:window.location=%22'.$cfg->{SiteUrl}.
                      '/submit?u=%22+encodeURIComponent(document.location)+%22'.
                      '&t=%22+encodeURIComponent(document.title)',
              'bookmarklet').
        ' (drag the link to your browser toolbar)'
      ).
      $h->script('
          $(function() {
            $("input[name=do_submit]").click(submit);
          });
      ')
    );
}

sub logout {
  if ($user and check_api_secret()) {
    update_auth_token($user->{'id'});
  }
  return redirect(302, '/');
}

sub news {
  my ($news_id) = @_;
  my $news = get_news_by_id($news_id);
  show $news;
  return err('404 - This news does not exist.') unless ($news);
  # Show the news text if it is a news without URL.
  my $top_comment = '';
  if (!news_domain($news)) {
    my $c = {
             'body' => news_text($news),
             'ctime' => $news->{'ctime'},
             'user_id' => $news->{'user_id'},
             'thread_id' => $news->{'id'},
             'topcomment' => 1,
             'id' => 0,
            };
    my $user = get_user_by_id($news->{'user_id'}) || $cfg->{DeletedUser};
    $top_comment = $h->topcomment(comment_to_html($c, $user));
  }
  $h->set_title(HTMLGen::entities($news->{'title'}).' - '.$cfg->{SiteName});
  $h->page(
    $h->section(id => 'newslist', news_to_html($news)).
    $top_comment.
    ($user ?
     $h->form(name => 'f',
       $h->inputhidden(name => 'news_id', value => $news->{'id'}).
       $h->inputhidden(name => 'comment_id', value => -1).
       $h->inputhidden(name => 'parent_id', value => -1).
       $h->textarea(name => 'comment', cols => 60, rows => 10, '').$h->br.
       $h->button(name => 'post_comment', value => 'Send comment')
     ).$h->div(id => 'errormsg', '') :
     $h->br).
     render_comments_for_news($news->{'id'}).
     $h->script('
       $(function() {
         $("input[name=post_comment]").click(post_comment);
       });
     ')
  );
}


sub comment {
  my ($news_id, $comment_id) = @_;
  my $news = get_news_by_id($news_id);
  return err('404 - This news does not exist.') unless ($news);
  my $comment = $comments->fetch($news_id, $comment_id);
  return err('404 - This comment does not exist.') unless ($comment);

  $h->page(
    $h->section(id => 'newslist', news_to_html($news)).
    render_comment_subthread($comment, $h->h2('Replies'))
  );
}

sub render_comment_subthread {
  my ($comment, $sep) = @_;
  $sep //= '';
  $h->div(class => 'singlecomment',
    comment_to_html($comment,
                    get_user_by_id($comment->{'user_id'})||$cfg->{DeletedUser})
  ).$h->div(class => 'commentreplies', $sep).
  render_comments_for_news($comment->{'thread_id'}, $comment->{'id'});
}

sub reply {
  my ($news_id, $comment_id) = @_;
  return redirect(302, '/login') unless ($user);

  my $news = get_news_by_id($news_id);
  return err('404 - This news does not exist.') unless ($news);
  my $comment = $comments->fetch($news_id, $comment_id);
  return err('404 - This comment does not exist.') unless ($comment);
  my $com_user = get_user_by_id($comment->{'user_id'}) || $cfg->{DeletedUser};

  $h->set_title('Reply to comment - '.$cfg->{SiteName});
  $h->page(
    news_to_html($news).
    comment_to_html($comment, $com_user).
    $h->form(name => 'f',
      $h->inputhidden(name => 'news_id', value => $news->{'id'}).
      $h->inputhidden(name => 'comment_id', value => -1).
      $h->inputhidden(name => 'parent_id', value => $comment_id).
      $h->textarea(name => 'comment', cols => 60, rows => 10, '').$h->br.
      $h->button(name => 'post_comment', value => 'Reply')
    ).$h->div(id => 'errormsg', '').
    $h->script('
      $(function() {
        $("input[name=post_comment]").click(post_comment);
      });
    ')
  );
}

sub editcomment {
  my ($news_id, $comment_id) = @_;
  return redirect(302, '/login') unless ($user);
  my $news = get_news_by_id($news_id);
  return err('404 - This news does not exist.') unless ($news);
  my $comment = $comments->fetch($news_id, $comment_id);
  return err('404 - This comment does not exist.') unless ($comment);
  my $com_user = get_user_by_id($comment->{'user_id'}) || $cfg->{DeletedUser};
  return err('Permission denied.', 500)
    unless ($user->{'id'} == $com_user->{'id'});

  $h->set_title('Edit comment - '.$cfg->{SiteName});
  $h->page(
    news_to_html($news).
    comment_to_html($comment, $user).
    $h->form(name => 'f',
            $h->inputhidden(name => 'news_id', value => $news->{'id'}).
            $h->inputhidden(name => 'comment_id',value => $comment_id).
            $h->inputhidden(name => 'parent_id', value => -1).
            $h->textarea(name => 'comment', cols => 60, rows => 10,
                         HTMLGen::entities($comment->{'body'})).
            $h->br.
            $h->button(name => 'post_comment', value => 'Edit')
    ).$h->div(id => 'errormsg', '').
    $h->note('Note: to remove the comment remove all the text and press Edit.').
    $h->script('
      $(function() {
        $("input[name=post_comment]").click(post_comment);
      });
    ')
  );
}

sub editnews {
  my ($news_id) = @_;
  return redirect(302, '/login') unless ($user);

  my $news = get_news_by_id($news_id);
  return err('404 - This news does not exist.') unless ($news);
  return err('Permission denied.', 500)
    unless ($user->{'id'} == $news->{'user_id'});

  my $text;
  if (news_domain($news)) {
    $text = '';
  } else {
    $text = news_text($news);
    $news->{'url'} = '';
  }

  $h->set_title('Edit news - '.$cfg->{SiteName});
  $h->page(
    news_to_html($news).
    $h->div(id => 'submitform',
      $h->form(name => 'f',
        $h->inputhidden(name => 'news_id', value => $news->{'id'}).
        $h->label(for => 'title', 'title').
        $h->inputtext(id => 'title', name => 'title', size => 80,
                      value => HTMLGen::entities($news->{'title'})).$h->br.
        $h->label(for => 'url', 'url').$h->br.
        $h->inputtext(id => 'url', name => 'url', size => 60,
                      value => HTMLGen::entities($news->{'url'})).$h->br.
        "or if you don't have an url type some text".
        $h->br.
        $h->label(for => 'text', 'text').
        $h->textarea(id => 'text', name => 'text', cols => 60, rows => 10,
                     HTMLGen::entities($text)).
        $h->br.
        $h->checkbox(name => 'del', value => '1').'delete this news'.$h->br.
        $h->button(name => 'edit_news', value => 'Edit')
      )
    ).
    $h->div(id => 'errormsg', '').
    $h->script('
            $(function() {
                $("input[name=edit_news]").click(submit);
            });
        ')
  );
}

sub user {
  my ($username) = @_;
  my $u = get_user_by_username($username);
  return err('Non existing user', 404) unless ($u);
  # TODO: pipeline
  my $posted_news = $r->zcard('user.posted:'.$u->{'id'});
  my $posted_comments = $r->zcard('user.comments:'.$u->{'id'});

  $h->set_title(HTMLGen::entities($u->{'username'}).' - '.$cfg->{SiteName});
  my $owner = $user && ($user->{'id'} == $u->{'id'});
  $h->page(
    $h->div(class => 'userinfo',
      avatar($u->{'email'}).' '.
      $h->h2(HTMLGen::entities($u->{'username'})).
      $h->pre(HTMLGen::entities($u->{'about'})).
      $h->ul(
        $h->li($h->b('created ').
               int((time-$u->{'ctime'})/(3600*24)).' days ago').
        $h->li($h->b('karma ').$u->{'karma'}.' points').
        $h->li($h->b('posted news ').$posted_news).
        $h->li($h->b('posted comments ').$posted_comments).
        ($owner ? $h->li($h->a(href => '/saved/0','saved news')) : '').
        $h->li(
          $h->a(
            href=>'/usercomments/'.HTMLGen::urlencode($u->{'username'}).'/0',
            'user comments'))
      )
    ).($owner ?
       $h->br.
       $h->form(name => 'f',
         $h->label(for => 'email', 'email (not visible, used for gravatar)').
         $h->br.
         $h->inputtext(id => 'email', name => 'email', size => 40,
                       value => HTMLGen::entities($u->{'email'})).$h->br.
         $h->label(for => 'password', 'change password (optional)').$h->br.
                $h->inputpass(name => 'password', size => 40).$h->br.
                $h->label(for => 'about', 'about').$h->br.
                $h->textarea(id => 'about', name => 'about',
                             cols => 60, rows => 10,
                             HTMLGen::entities($u->{'about'})
                ).$h->br.
                $h->button(name => 'update_profile', value => 'Update profile')
            ).
            $h->div(id => 'errormsg', '').
            $h->script('
                $(function() {
                    $("input[name=update_profile]").click(update_profile);
                });
            ') : '')
  );
}

###############################################################################
# API implementation
###############################################################################

sub api_logout {
  if ($user and check_api_secret()) {
    update_auth_token($user->{'id'});
    return $j->encode({status => 'ok'});
  } else {
    return $j->encode({
                       status => 'err',
                       error => 'Wrong auth credentials or API secret.'
                      })
  }
}

sub api_login {
  my ($auth,$apisecret) =
    check_user_credentials($req->param('username'), $req->param('password'));
  if ($auth) {
    return $j->encode({
                       status => 'ok',
                       auth => $auth,
                       apisecret => $apisecret,
                      });
  } else {
    return $j->encode(
      {
       status => 'err',
       error => 'No match for the specified username / password pair.',
      })
  }
}

sub api_create_account {
  unless (check_params('username','password')) {
    return $j->encode({
      status => 'err',
      error => 'Username and password are two required fields.'
    });
  }
  my $password = $req->param('password');
  if (length($password) < $cfg->{PasswordMinLength}) {
    return $j->encode({
      status => 'err',
      error => 'Password is too short. Min length: '.$cfg->{PasswordMinLength}
    });
  }
  my ($auth,$errmsg) = create_user($req->param('username'),$password);
  if ($auth) {
    return $j->encode({status => 'ok', auth => $auth});
  } else {
    return $j->encode({ status => 'err', error => $errmsg });
  }
}

sub api_submit {
  return $j->encode({status => 'err', error => 'Not authenticated.'})
    unless ($user);
  return $j->encode({status => 'err', error => 'Wrong form secret.'})
    unless (check_api_secret());

  # We can have an empty url or an empty first comment, but not both.
  if (!check_params('title', 'news_id', ':url', ':text') or
      ($req->param('url') eq '' and $req->param('text') eq '')) {
    return $j->encode({
      status => 'err',
      error => 'Please specify a news title and address or text.'
    });
  }
  # Make sure the URL is about an acceptable protocol, that is
  # http:// or https:// for now.
  if ($req->param('url') ne '' and ($req->param('url') !~ m!^https?://!)) {
    return $j->encode({
      status => 'err',
      error => 'We only accept http:// and https:// news.'
    });
  }

  my $news_id;
  show $req->param('news_id');
  if ($req->param('news_id') == -1) {
    return $j->encode({
      status => 'err',
      error => ('You have submitted a story too recently, please wait '.
                allowed_to_post_in_seconds().' seconds.')
    }) if (submitted_recently());
    $news_id = insert_news($req->param('title'), $req->param('url'),
                           $req->param('text'), $user->{'id'});
  } else {
    $news_id = edit_news($req->param('news_id'),$req->param('title'),
                         $req->param('url'), $req->param('text'),
                         $user->{'id'});
    unless ($news_id) {
      return $j->encode({
        status => 'err',
        error => ('Invalid parameters, news too old to be modified '.
                  'or url recently posted.')
      });
    }
  }
  show $news_id;
  return $j->encode({ status => 'ok', news_id => $news_id });
}

sub api_delnews {
  return $j->encode({status => 'err', error => 'Not authenticated.'})
    unless ($user);
  return $j->encode({status => 'err', error => 'Wrong form secret.'})
    unless (check_api_secret());
  unless (check_params('news_id')) {
    return
      $j->encode({ status => 'err', error => 'Please specify a news title.' });
  }
  if (del_news($req->param('news_id'),$user->{'id'})) {
    return $j->encode({status => 'ok', news_id => -1});
  }
  return
    $j->encode({status => 'err', error => 'News too old or wrong ID/owner.'});
}

sub api_votenews {
  return $j->encode({status => 'err', error => 'Not authenticated.'})
    unless ($user);
  return $j->encode({status => 'err', error => 'Wrong form secret.'})
    unless (check_api_secret());

  # Params sanity check
  my $vote_type = $req->param('vote_type');
  if (!check_params('news_id','vote_type') or
      ($vote_type ne 'up' and $vote_type ne 'down')) {
    return $j->encode({
            status => 'err',
            error => 'Missing news ID or invalid vote type.',
        })
  }
  # Vote the news
  my ($karma, $error) =
    vote_news($req->param('news_id'),$user->{'id'}, $vote_type);
  if (defined $karma) {
    return $j->encode({ status => 'ok' });
  } else {
    return $j->encode({ status => 'err', error => $error });
  }
}

sub api_postcomment {
  return $j->encode({status => 'err', error => 'Not authenticated.'})
    unless ($user);
  return $j->encode({status => 'err', error => 'Wrong form secret.'})
    unless (check_api_secret());

  # Params sanity check
  if (!check_params('news_id', 'comment_id', 'parent_id', ':comment')) {
    return $j->encode({
      status => 'err',
      error => 'Missing news_id, comment_id, parent_id, or comment parameter.',
    })
  }
  my $info = insert_comment($req->param('news_id'), $user->{'id'},
                            $req->param('comment_id'),
                            $req->param('parent_id'), $req->param('comment'));
  return $j->encode({
    status => 'err',
    error => 'Invalid news, comment, or edit time expired.'
  }) unless ($info);
  return $j->encode({
    status => 'ok',
    op => $info->{'op'},
    comment_id => $info->{'comment_id'},
    parent_id => $req->param('parent_id'),
    news_id => $req->param('news_id')
  });
}

sub api_updateprofile {
  return $j->encode({status => 'err', error => 'Not authenticated.'})
    unless ($user);
  return $j->encode({status => 'err', error => 'Wrong form secret.'})
    unless (check_api_secret());
  unless (check_params(':about', ':email', ':password')) {
    return $j->encode({status => 'err', error => 'Missing parameters.'});
  }
  my $password = $req->param('password');
  if ($password ne '') {
    if (length $password < $cfg->{PasswordMinLength}) {
      return $j->encode({
                         status => 'err',
                         error => 'Password is too short. Min length '.
                                  $cfg->{PasswordMinLength},
                        });
    }
    $r->hmset('user:'.$user->{'id'}, 'password',
              hash_password($password,$user->{'salt'}));
  }
  $r->hmset('user:'.$user->{'id'},
            'about' => (substr $req->param('about'), 0, 4096),
            'email' => (substr $req->param('email'), 0, 256));
  return $j->encode({status => 'ok'});
}

sub api_votecomment {
  return $j->encode({status => 'err', error => 'Not authenticated.'})
    unless ($user);
  return $j->encode({status => 'err', error => 'Wrong form secret.'})
    unless (check_api_secret());
  # Params sanity check
  my $vote_type = $req->param('vote_type');
  unless (check_params('comment_id', 'vote_type') or
          ($vote_type ne 'up' and $vote_type ne 'down')) {
    return $j->encode({
            status => 'err',
            error => 'Missing comment ID or invalid vote type.',
        })
  }
  # Vote the news
  my ($news_id, $comment_id) = split /-/, $req->param('comment_id'), 2;
  if (vote_comment($news_id, $comment_id, $user->{'id'}, $vote_type)) {
    return $j->encode({ status => 'ok',
                        comment_id => $req->param('comment_id') });
  } else {
    return $j->encode({ status => 'err',
                        error => 'Invalid parameters or duplicated vote.' });
  }
}

sub api_getnews {
  my ($sort, $start, $count) = @_;
  unless (exists {latest => 1, top => 1}->{$sort}) {
    return $j->encode({status => 'err', error => "Invalid sort parameter"});
  }
  return $j->encode({status => 'err', error => 'Count is too big'})
    if ($count > $cfg->{APIMaxNewsCount});

  $start = 0 if ($start < 0);
  my $getfunc = $sort eq 'latest' ? \&get_latest_news : \&get_top_news;
  my ($news, $numitems) = $getfunc->($start, $count);
  foreach my $n (@$news) {
    foreach my $field (qw/rank score user_id/) {
      delete $n->{$field};
    }
  }
  return $j->encode({ status => 'ok', news => $news, count => $numitems });
}

sub api_getcomments {
  my ($news_id) = @_;
  return $j->encode({ status => 'err', error => 'Wrong news ID.' })
    unless (get_news_by_id($news_id));
  my $thread = $comments->fetch_thread($news_id);
  my $top_comments = [];
  foreach (@$thread) {
    my ($parent, $replies) = @$_;
    if ($parent == -1) {
      $top_comments = $replies;
    }
    foreach my $r (@$replies) {
      my $u = get_user_by_id($r->{'user_id'}) || $cfg->{DeletedUser};
      $r->{'username'} = $u->{'username'};
      $r->{'replies'} = $thread->{$r->{'id'}} || [];
      if ($r->{'up'}) {
        $r->{'voted'} = 'up'
          if ($user && (grep { $_ eq $user->{'id'} } @{$r->{'up'}}));
        $r->{'up'} = @{$r->{'up'}};
      }
      if ($r->{'down'}) {
        $r->{'voted'} = 'down'
          if ($user && (grep { $_ eq $user->{'id'} } @{$r->{'down'}}));
        $r->{'down'} = @{$r->{'down'}};
      }
      foreach my $f (qw/id thread_id score parent_id user_id/) {
        delete $r->{$f};
      }
    }
  }
  return $j->encode({ status => 'ok', comments => $top_comments });
}

# Check that the list of parameters specified exist.
# If at least one is missing false is returned, otherwise true is returned.
#
# If a parameter is specified as as symbol only existence is tested.
# If it is specified as a string the parameter must also meet the condition
# of being a non empty string.
sub check_params {
  my (@required) = @_;
  foreach my $p (@required) {
    if ($p =~ s!^:!!) {
      return unless (defined $req->param($p));
    } else {
      my $v = $req->param($p);
      return unless (defined $v and $v ne '');
    }
    $req->parameters->{$p} =~ s/\s+$// if (exists $req->parameters->{$p});
    # TODO: what about body_parameters and query_parameters which may be
    # different hashes
  }
  return 1;
}

sub check_api_secret {
  return unless ($user);
  $req->param('apisecret') and
    ($req->param('apisecret') eq $user->{'apisecret'})
}

###############################################################################
# Navigation, header and footer.
###############################################################################

# Return the HTML for the 'replies' link in the main navigation bar.
# The link is not shown at all if the user is not logged in, while
# it is shown with a badge showing the number of replies for logged in
# users.
sub replies_link {
  return '' unless ($user);
  my $count = $user->{'replies'} || 0;
  $h->a(href => '/replies', class => 'replies',
        'replies'.($count > 0 ? $h->sup($count) : ''));
}

sub header {
  my ($h) = @_;
  my @navitems =
    (
     ['top' => '/'],
     ['latest' => '/latest/0'],
     ['submit' => '/submit'],
    );
  my $navbar =
    $h->nav(join("\n",
                 map { $h->a(href => $_->[1], HTMLGen::entities($_->[0]))
                     } @navitems).replies_link());
  my $rnavbar =
    $h->nav(id => 'account',
            ( $user ?
              $h->a(href => '/user/'.HTMLGen::urlencode($user->{'username'}),
                   $user->{'username'}.' ('.$user->{'karma'}.')').
              ' | '.
              $h->a(href => '/logout?apisecret='.$user->{'apisecret'},
                   'logout')
              :
              $h->a(href => '/login', 'login / register')
            ));

  $h->header($h->h1($h->a(href => '/', HTMLGen::entities($cfg->{SiteName})).
                    ' '.$h->small($VERSION)
                   ).$navbar.' '.$rnavbar);
}

sub footer {
  my ($h) = @_;
  my $apisecret =
    $user ? $h->script('var apisecret = "'.$user->{'apisecret'}.'"') : '';
  $h->footer(
    join ' | ', grep { defined $_ } map {
      $_->[1] ? $h->a(href => $_->[1], HTMLGen::entities($_->[0])) : undef
    } (['source code', 'http://github.com/antirez/lamernews'],
       ['rss feed', '/rss'],
       ['twitter', $cfg->{FooterTwitterLink}],
       ['google group', $cfg->{FooterGoogleGroupLink}]
      )
  ).$apisecret;
}

################################################################################
# User and authentication
################################################################################

# Try to authenticate the user, if the credentials are ok we populate the
# $user global with the user information.
# Otherwise $user is set to nil, so you can test for authenticated user
# just with: if $user ...
#
# Return value: $user
sub auth_user {
  my ($auth) = @_;
  return unless ($auth);
  my $id = $r->get('auth:'.$auth);
  return unless ($id);
  my $user = { @{$r->hgetall('user:'.$id)} };
  $user
}

# In Lamer News users get karma visiting the site.
# Increment the user karma by KarmaIncrementAmount if the latest increment
# was performed more than KarmaIncrementInterval seconds ago.
#
# Return value: none.
#
# Notes: this function must be called only in the context of a logged in
#        user.
#
# Side effects: the user karma is incremented and the $user hash updated.
sub increment_karma_if_needed {
  my ($user) = @_;
  my $t = time;
  if ($user->{'karma_incr_time'} < ($t - $cfg->{KarmaIncrementInterval})) {
    my $userkey = 'user:'.$user->{'id'};
    $r->hset($userkey, 'karma_incr_time', $t);
    increment_user_karma_by($user->{'id'}, $cfg->{KarmaIncrementAmount});
  }
}

# Increment the user karma by the specified amount and make sure to
# update $user to reflect the change if it is the same user id.
sub increment_user_karma_by {
  my ($user_id, $increment) = @_;
  $r->hincrby('user:'.$user_id, 'karma', $increment);
  if ($user and ($user->{'id'} == $user_id)) {
    $user->{'karma'} = $user->{'karma'} + $increment;
  }
}

# Return the specified user karma.
sub get_user_karma {
  my ($user_id) = @_;
  return $user->{'karma'} if ($user and ($user_id == $user->{'id'}));
  my $karma = $r.hget('user:'.$user_id, 'karma');
  $karma || 0
}

# Return the hex representation of an unguessable 160 bit random number.
sub get_rand {
  open my $fh, '/dev/urandom';
  local $/ = \20;
  my $bytes = <$fh>;
  close $fh;
  unpack 'H*', $bytes;
}

# Create a new user with the specified username/password
#
# Return value: the function returns two values, the first is the
#               auth token if the registration succeeded, otherwise
#               is nil. The second is the error message if the function
#               failed (detected testing the first return value).
sub create_user {
  my ($username, $password) = @_;

  if ($r->exists('username.to.id:'.(lc $username))) {
    return (undef, 'Username is busy, please try a different one.');
  }
  if (rate_limit_by_ip($cfg->{PreventCreateUserTime},
                       'create_user', $req->address)) {
    return (undef, 'Please wait some time before creating a new user.');
  }
  my $id = $r->incr('users.count');
  my $auth_token = get_rand();
  my $salt = get_rand();
  $r->hmset('user:'.$id,
            'id' => $id,
            'username' => $username,
            'salt' => $salt,
            'password' => hash_password($password, $salt),
            'ctime' => time,
            'karma' => $cfg->{UserInitialKarma},
            'about' => '',
            'email' => '',
            'auth' => $auth_token,
            'apisecret' => get_rand(),
            'flags' => '',
            'karma_incr_time' => time);
    $r->set('username.to.id:'.(lc $username), $id);
    $r->set('auth:'.$auth_token, $id);
    return ($auth_token, undef);
}

# Update the specified user authentication token with a random generated
# one. This in other words means to logout all the sessions open for that
# user.
#
# Return value: on success the new token is returned. Otherwise nil.
# Side effect: the auth token is modified.
sub update_auth_token {
  my ($user_id) = @_;
  my $user = get_user_by_id($user_id);
  return unless ($user);
  $r->del('auth:'.$user->{'auth'});
  my $new_auth_token = get_rand();
  $r->hmset('user:'.$user_id, 'auth', $new_auth_token);
  $r->set('auth:'.$new_auth_token, $user_id);
  return $new_auth_token
}

# Turn the password into an hashed one, using PBKDF2 with HMAC-SHA1
# and 160 bit output.
sub hash_password {
  my ($password, $salt) = @_;
  my $pbkdf2 = Crypt::PBKDF2->new(iterations => $cfg->{PBKDF2Iterations},
                                  output_len => 160/8);
  $pbkdf2->PBKDF2_hex($salt, $password);
}

# Return the user from the ID.
sub get_user_by_id {
  my ($id) = @_;
  my $user = { @{$r->hgetall('user:'.$id)} };
  $user
}

# Return the user from the username.
sub get_user_by_username {
  my ($username) = @_;
  my $id = $r->get('username.to.id:'.$username);
  return unless ($id);
  get_user_by_id($id);
}

# Check if the username/password pair identifies an user.
# If so the auth token and form secret are returned, otherwise nil is returned.
sub check_user_credentials {
  my ($username, $password) = @_;
  my $user = get_user_by_username($username);
  return unless ($user);
  my $hp = hash_password($password, $user->{'salt'});
  ($user->{'password'} eq $hp) ? ($user->{'auth'},$user->{'apisecret'}) : undef;
}

# Has the user submitted a news story in the last `NewsSubmissionBreak` seconds?
sub submitted_recently {
  allowed_to_post_in_seconds() > 0
}

# Indicates when the user is allowed to submit another story after the last.
sub allowed_to_post_in_seconds {
  $r->ttl('user:'.$user->{'id'}.':submitted_recently');
}

# Add the specified set of flags to the user.
# Returns false on error (non existing user), otherwise true is returned.
#
# Current flags:
# 'a'   Administrator.
# 'k'   Karma source, can transfer more karma than owned.
# 'n'   Open links to new windows.
#
sub user_add_flags {
  my ($user_id, $flags) = @_;
  my ($u) = get_user_by_id($user_id);
  return unless ($u);
  my $newflags = $u->{'flags'};
  foreach my $flag (split //, $flags) {
    $newflags .= $flag unless (user_has_flags($user,$flag));
  }
  # Note: race condition here if somebody touched the same field
  # at the same time: very unlkely and not critical so not using WATCH.
  $r->hset('user:'.$u->{'id'}, 'flags', $newflags);
  1;
}

# Check if the user has all the specified flags at the same time.
# Returns true or false.
sub user_has_flags {
  my ($u, $flags) = @_;
  foreach my $flag (split //, $flags) {
    return if (index($u->{'flags'}, $flag) < 0);
  }
  1;
}

sub user_is_admin {
  my ($u) = @_;
  user_has_flags($u, 'a');
}

################################################################################
# News
################################################################################

# Fetch one or more (if an Array is passed) news from Redis by id.
# Note that we also load other informations about the news like
# the username of the poster and other informations needed to render
# the news into HTML.
#
# Doing this in a centralized way offers us the ability to exploit
# Redis pipelining.
sub get_news_by_id {
  my ($news_ids, %opt) = @_;
  my $result = [];
  if (ref $news_ids) {
    return [] unless (@$news_ids);
  } else {
    $opt{single} = 1;
    $news_ids = [$news_ids]
  }
  foreach (@$news_ids) {
    $r->append_command('hgetall news:'.$_);
  }
  my @news;
  foreach (@$news_ids) {
    my $res = $r->get_reply;
    push @news, $res if ($res);
  }

  return $opt{single} ? undef : [] unless (@news);

  # Get all the news
  my @result;
  foreach (@news) { # TODO: pipeline?
    # Adjust rank if too different from the real-time value.
    my %h = @$_;
    update_news_rank_if_needed(\%h) if ($opt{update_rank});
    push @result, \%h;
  }

  # Get the associated users information
  foreach (@result) { # TODO: pipeline?
    $_->{'username'} = $r->hget('user:'.$_->{'user_id'}, 'username');
    $_->{'voted'} = 0;
  }

  # Load $user vote information if we are in the context of a
  # registered user.

  if ($user) {
    foreach (@result) {
      if ($r->zscore('news.up:'.$_->{'id'}, $user->{'id'})) {
        $_->{voted} = 1;
      }
      if ($r->zscore('news.down:'.$_->{'id'}, $user->{'id'})) {
        $_->{voted} = -1;
      }
    }
  }

  # Return an array if we got an array as input, otherwise
  # the single element the caller requested.
  return $opt{single} ? $result[0] : \@result;
}

# Vote the specified news in the context of a given user.
# type is either :up or :down
#
# The function takes care of the following:
# 1) The vote is not duplicated.
# 2) That the karma is decreased from voting user, accordingly to vote type.
# 3) That the karma is transfered to the author of the post, if different.
# 4) That the news score is updaed.
#
# Return value: two return values are returned: rank,error
#
# If the fucntion is successful rank is not nil, and represents the news karma
# after the vote was registered. The error is set to nil.
#
# On error the returned karma is false, and error is a string describing the
# error that prevented the vote.
sub vote_news {
  my ($news_id, $user_id, $vote_type) = @_;
  # Fetch news and user
  my $user =
    ($user and $user->{'id'} == $user_id) ? $user : get_user_by_id($user_id);
  my $news = get_news_by_id($news_id);
  return (undef, 'No such news or user.') unless ($news and $user);

  # Now it's time to check if the user already voted that news, either
  # up or down. If so return now.
  if ($r->zscore('news.up:'.$news_id, $user_id) or
      $r->zscore('news.down:'.$news_id, $user_id)) {
    return (undef, 'Duplicated vote.');
  }

  # Check if the user has enough karma to perform this operation
  if ($user->{'id'} != $news->{'user_id'}) {
    if (($vote_type eq 'up' and
         (get_user_karma($user_id) < $cfg->{NewsUpvoteMinKarma})) or
        ($vote_type eq 'down' and
         (get_user_karma($user_id) < $cfg->{NewsDownvoteMinKarma}))) {
      return (undef, "You don't have enough karma to vote ".$vote_type);
    }
  }
  # News was not already voted by that user. Add the vote.
  # Note that even if there is a race condition here and the user may be
  # voting from another device/API in the time between the ZSCORE check
  # and the zadd, this will not result in inconsistencies as we will just
  # update the vote time with ZADD.
  if ($r->zadd('news.'.$vote_type.':'.$news_id, time, $user_id)) {
    $r->hincrby('news:'.$news_id, $vote_type, 1);
  }
  $r->zadd('user.saved:'.$user_id, time, $news_id) if ($vote_type eq 'up');

  # Compute the new values of score and karma, updating the news accordingly.
  my $score = compute_news_score($news);
  $news->{'score'} = $score;
  my $rank = compute_news_rank($news);
  $r->hmset('news:'.$news_id, 'score' => $score, 'rank' => $rank);
  $r->zadd('news.top', $rank, $news_id);

  # Remove some karma to the user if needed, and transfer karma to the
  # news owner in the case of an upvote.
  if ($user->{'id'} != $news->{'user_id'}) {
    if ($vote_type eq 'up') {
      increment_user_karma_by($user_id, -$cfg->{NewsUpvoteKarmaCost});
      increment_user_karma_by($news->{'user_id'},
                              $cfg->{NewsUpvoteKarmaTransfered});
    } else {
      increment_user_karma_by($user_id,-$cfg->{NewsDownvoteKarmaCost});
    }
  }

  return ($rank,undef);
}

# Given the news compute its score.
# No side effects.
sub compute_news_score {
  my ($news) = @_;

  # TODO: withscores => 1
  my $upvotes = $r->zrange('news.up:'.$news->{'id'}, 0, -1);
  my $downvotes = $r->zrange('news.down:'.$news->{'id'}, 0, -1);
  # FIXME: For now we are doing a naive sum of votes, without time-based
  # filtering, nor IP filtering.
  # We could use just ZCARD here of course, but I'm using ZRANGE already
  # since this is what is needed in the long term for vote analysis.
  my $score = (@$upvotes/2) - (@$downvotes/2);
  # Now let's add the logarithm of the sum of all the votes, since
  # something with 5 up and 5 down is less interesting than something
  # with 50 up and 50 down.
  my $votes = @$upvotes/2 + @$downvotes/2;
  if ($votes > $cfg->{NewsScoreLogStart}) {
    $score += log($votes-$cfg->{NewsScoreLogStart})*$cfg->{NewsScoreLogBooster};
  }
  $score
}

# Given the news compute its rank, that is function of time and score.
#
# The general forumla is RANK = SCORE / (AGE ^ AGING_FACTOR)
sub compute_news_rank {
  my ($news) = @_;
  my $age = (time - $news->{'ctime'}) + $cfg->{NewsAgePadding};
  return ($news->{'score'})/(($age/3600)**$cfg->{RankAgingFactor})
}

# Add a news with the specified url or text.
#
# If an url is passed but was already posted in the latest 48 hours the
# news is not inserted, and the ID of the old news with the same URL is
# returned.
#
# Return value: the ID of the inserted news, or the ID of the news with
# the same URL recently added.
sub insert_news {
  my ($title, $url, $text, $user_id) = @_;

  # If we don't have an url but a comment, we turn the url into
  # text://....first comment..., so it is just a special case of
  # title+url anyway.
  my $textpost = ($url eq '');
  if ($textpost) {
    $url = 'text://'.substr($text, 0, $cfg->{CommentMaxLength});
  }
  # Check for already posted news with the same URL.
  my $news_id;
  if (!$textpost && ($news_id = $r->get('url:'.$url))) {
    return $news_id;
  }

  # We can finally insert the news.
  my $ctime = time;
  $news_id = $r->incr('news.count');
  $r->hmset('news:'.$news_id,
            'id' => $news_id,
            'title' => $title,
            'url' => $url,
            'user_id' => $user_id,
            'ctime' => $ctime,
            'score' => 0,
            'rank' => 0,
            'up' => 0,
            'down' => 0,
            'comments' => 0);
  # The posting user virtually upvoted the news posting it
  my ($rank, $error) = vote_news($news_id, $user_id, 'up');
  # Add the news to the user submitted news
  $r->zadd('user.posted:'.$user_id, $ctime, $news_id);
  # Add the news into the chronological view
  $r->zadd('news.cron', $ctime, $news_id);
  # Add the news into the top view
  $r->zadd('news.top', $rank, $news_id);
  # Add the news url for some time to avoid reposts in short time
  $r->setex('url:'.$url, $cfg->{PreventRepostTime}, $news_id)
    unless ($textpost);
  # Set a timeout indicating when the user may post again
  $r->setex('user:'.$user->{'id'}.':submitted_recently',
            $cfg->{NewsSubmissionBreak}, '1');
  return $news_id;
}

# Edit an already existing news.
#
# On success the news_id is returned.
# On success but when a news deletion is performed (empty title) -1 is returned.
# On failure (for instance news_id does not exist or does not match
#             the specified user_id) false is returned.
sub edit_news {
  my ($news_id, $title, $url, $text, $user_id) = @_;
  my $news = get_news_by_id($news_id);

  return if (!$news or $news->{'user_id'} != $user_id);
  return unless ($news->{'ctime'} > (time - $cfg->{NewsEditTime}));

  # If we don't have an url but a comment, we turn the url into
  # text://....first comment..., so it is just a special case of
  # title+url anyway.
  my $textpost = ($url eq '');
  if ($textpost) {
    $url = 'text://'.substr($text, 0, $cfg->{CommentMaxLength});
  }

  # Even for edits don't allow to change the URL to the one of a
  # recently posted news.
  if (!$textpost and $url ne $news->{'url'}) {
    return if ($r->get('url:'.$url));
    # No problems with this new url, but the url changed
    # so we unblock the old one and set the block in the new one.
    # Otherwise it is easy to mount a DOS attack.
    $r->del('url:'.$news->{'url'});
    $r->setex('url:'.$url, $cfg->{PreventRepostTime}, $news_id)
      unless ($textpost);
  }
  # Edit the news fields.
  $r->hmset('news:'.$news_id, 'title' => $title, 'url' => $url);
  return $news_id;
}

# Mark an existing news as removed.
sub del_news {
  my ($news_id, $user_id) = @_;
  my $news = get_news_by_id($news_id);
  return unless ($news and $news->{'user_id'} == $user_id);
  return unless ($news->{'ctime'} > (time - $cfg->{NewsEditTime}));

  $r->hmset('news:'.$news_id, 'del' ,1);
  $r->zrem('news.top', $news_id);
  $r->zrem('news.cron', $news_id);
  return 1;
}

# Return the host part of the news URL field.
# If the url is in the form text:// nil is returned.
sub news_domain {
  my $news = shift;
  my @su = split /\//, $news->{'url'};
  ($su[0] eq 'text:') ? undef : $su[2]
}

# Assuming the news has an url in the form text:// returns the text
# inside. Otherwise nil is returned.
sub news_text {
  my $news = shift;
  my @su = split /\//, $news->{'url'};
  ($su[0] eq 'text:') ? (substr $news->{'url'}, 7) : undef
}

# Turn the news into its RSS representation
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
sub news_to_rss {
  my ($news) = @_;
  my $domain = news_domain($news);
  my %news = %$news; # Copy the object so we can modify it as we wish.
  $news{'ln_url'} = uri_for('/news/'.$news{'id'});
  $news{'url'} = $news{'ln_url'} unless ($domain);

  $h->item(
    $h->title(HTMLGen::entities($news{'title'})).' '.
    $h->guid(HTMLGen::entities($news{'url'})).' '.
    $h->link(HTMLGen::entities($news{'url'})).' '.
    $h->description(
      '<![CDATA['.$h->a(href => $news{'ln_url'}, 'Comments').']]>'
    ).' '.
    $h->comments(HTMLGen::entities($news{'ln_url'}))
  )."\n"
}

# Turn the news into its HTML representation, that is
# a linked title with buttons to up/down vote plus additional info.
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
sub news_to_html {
  my ($news) = @_;
  return $h->article(class => 'deleted', '[deleted news]') if ($news->{del});
  my $domain = news_domain($news);
  my %news = %$news; # Copy the object so we can modify it as we wish.
  $news{'url'} = '/news/'.$news{'id'} unless ($domain);
  my $upclass = 'uparrow';
  my $downclass = 'downarrow';
  if ($news{'voted'} == 1) {
    $upclass .= ' voted';
    $downclass .= ' disabled';
  } elsif ($news{'voted'} == -1) {
    $downclass .= ' voted';
    $upclass .= ' disabled';
  }

  $h->article('data-news-id' => $news{'id'},
    $h->a(href => '#up', class => $upclass, '&#9650;').' '.
    $h->h2($h->a(href => $news{'url'}, HTMLGen::entities($news{'title'}))).' '.
    $h->address(($domain ? 'at '.HTMLGen::entities($domain) : '').
                (($user and $user->{'id'} == $news{'user_id'} and
                  $news{'ctime'} > (time - $cfg->{NewsEditTime})) ?
                 ' '.$h->a(href => '/editnews/'.$news{'id'}, '[edit]') : '')).
    $h->a(href => '#down', 'class' => $downclass, '&#9660;').
    $h->p($news{'up'}.' up and '.$news{'down'}.' down, posted by '.
          $h->username(
            $h->a(href=>'/user/'.HTMLGen::urlencode($news{'username'}),
                  HTMLGen::entities($news{'username'}))
          ).' '.str_elapsed($news{'ctime'}).' '.
          $h->a(href => '/news/'.$news{'id'}, $news{'comments'}.' comments')
    ).
    ($req->param('debug') && $user && user_is_admin($user) ?
     'score: '.$news->{'score'}.' old rank:'.$news->{'rank'}.
     ' new rank:'.compute_news_rank($news) : '')
  )."\n"
}

# If 'news' is a list of news entries (Ruby hashes with the same fields of
# the Redis hash representing the news in the DB) this function will render
# the RSS needed to show this news.
sub news_list_to_rss {
  my ($news) = @_;
  join '', map { news_to_rss($_) } @$news;
}

# If 'news' is a list of news entries (Ruby hashes with the same fields of
# the Redis hash representing the news in the DB) this function will render
# the HTML needed to show this news.
sub news_list_to_html {
  my $news = shift;
  $h->section(id => 'newslist', (join '', map { news_to_html($_) } @$news));
}

# Updating the rank would require some cron job and worker in theory as
# it is time dependent and we don't want to do any sorting operation at
# page view time. But instead what we do is to compute the rank from the
# score and update it in the sorted set only if there is some sensible error.
# This way ranks are updated incrementally and "live" at every page view
# only for the news where this makes sense, that is, top news.
#
# Note: this function can be called in the context of redis.pipelined {...}
sub update_news_rank_if_needed {
  my ($n) = @_;
  my $real_rank = compute_news_rank($n);
  if (abs($real_rank-$n->{'rank'}) > 0.001) {
    $r->hmset('news:'.$n->{'id'}, 'rank', $real_rank);
    $r->zadd('news.top', $real_rank, $n->{'id'});
    $n->{'rank'} = $real_rank;
  }
}

# Generate the main page of the web site, the one where news are ordered by
# rank.
#
# As a side effect thsi function take care of checking if the rank stored
# in the DB is no longer correct (as time is passing) and updates it if
# needed.
#
# This way we can completely avoid having a cron job adjusting our news
# score since this is done incrementally when there are pageviews on the
# site.

sub get_top_news {
  my ($start, $count) = @_;
  $start //= 0;
  $count //= $cfg->{TopNewsPerPage};
  my $numitems = $r->zcard('news.top');
  my $news_ids = $r->zrevrange('news.top', $start, $start+($count-1));
  my $result = get_news_by_id($news_ids, update_rank => 1);
  # Sort by rank before returning, since we adjusted ranks during iteration.
  return ([sort { $b->{rank} <=> $a->{rank} } @$result], $numitems);
}

# Get news in chronological order.
sub get_latest_news {
 my ($start, $count) = @_;
 $start //= 0;
 $count //= $cfg->{LatestNewsPerPage};
 my $numitems = $r->zcard('news.cron');
 my $news_ids = $r->zrevrange('news.cron', $start, $start+($count-1));
 return (get_news_by_id($news_ids, update_rank => 1), $numitems);
}

# Get saved news of current user
sub get_saved_news {
  my ($user_id, $start, $count) = @_;
  my $numitems = $r->zcard('user.saved:'.$user_id);
  my $news_ids =
    $r->zrevrange('user.saved:'.$user_id, $start, $start+($count-1));
  return (get_news_by_id($news_ids), $numitems);
}

###############################################################################
# Comments
###############################################################################

# This function has different behaviors, depending on the arguments:
#
# 1) If comment_id is -1 insert a new comment into the specified news.
# 2) If comment_id is an already existing comment in the context of the
#    specified news, updates the comment.
# 3) If comment_id is an already existing comment in the context of the
#    specified news, but the comment is an empty string, delete the comment.
#
# Return value:
#
# If news_id does not exist or comment_id is not -1 but neither a valid
# comment for that news, nil is returned.
# Otherwise an hash is returned with the following fields:
#   news_id: the news id
#   comment_id: the updated comment id, or the new comment id
#   op: the operation performed: "insert", "update", or "delete"
#
# More informations:
#
# The parent_id is only used for inserts (when comment_id == -1), otherwise
# is ignored.
sub insert_comment {
  my ($news_id, $user_id, $comment_id, $parent_id, $body) = @_;
  my $news = get_news_by_id($news_id);
  return unless ($news);
  if ($comment_id == -1) {
    my $p;
    if ($parent_id != -1) {
      $p = $comments->fetch($news_id, $parent_id);
      return unless ($p);
    }
    my $comment =
      {
       score => 0,
       body => $body,
       parent_id => $parent_id,
       user_id => $user_id,
       ctime => time,
       up => [$user_id],
      };
    my $comment_id = $comments->insert($news_id, $comment);
    return unless ($comment_id);
    $r->hincrby('news:'.$news_id, 'comments', 1);
    $r->zadd('user.comments:'.$user_id, time, $news_id.'-'.$comment_id);
    # increment_user_karma_by(user_id,KarmaIncrementComment)
    if ($p and $r->exists('user:'.$p->{'user_id'})) {
      $r->hincrby('user:'.$p->{'user_id'}, 'replies',1);
    }
    return {
            'news_id' => $news_id,
            'comment_id' => $comment_id,
            'op' => 'insert',
           }
  }

  # If we reached this point the next step is either to update or
  # delete the comment. So we make sure the user_id of the request
  # matches the user_id of the comment.
  # We also make sure the user is in time for an edit operation.
  my $c = $comments->fetch($news_id, $comment_id);
  return unless ($c and $c->{'user_id'} == $user_id);
  return unless ($c->{'ctime'} > (time - $cfg->{CommentEditTime}));

  if (length($body) == 0) {
    return unless (!$comments->del_comment($news_id, $comment_id));
    $r->hincrby('news:'.$news_id, 'comments', -1);
    return {
            'news_id' => $news_id,
            'comment_id' => $comment_id,
            'op' => 'delete'
           }
  } else {
    my %update;
    $update{'body'} = $body;
    $update{'del'} = 0 if ($c->{'del'} == 1);
    return unless ($comments->edit($news_id, $comment_id, \%update));
    return {
            'news_id' => $news_id,
            'comment_id' => $comment_id,
            'op' => 'update'
        }
  }
}

# Compute the comment score
sub compute_comment_score {
  my ($c) = @_;
  my $upcount = ($c->{'up'} ? scalar @{$c->{'up'}} : 0);
  my $downcount = ($c->{'down'} ? scalar @{$c->{'down'}} : 0);
  $upcount-$downcount
}

sub avatar {
  my $email = shift || '';
  my $digest = md5_hex($email);
  $h->span(class => 'avatar',
           $h->img(src=>'http://gravatar.com/avatar/'.$digest.'?s=48&d=mm'))
}

# Given a string returns the same string with all the urls converted into
# HTML links. We try to handle the case of an url that is followed by a period
# Like in "I suggest http://google.com." excluding the final dot from the link.
sub urls_to_links {
  my ($s) = @_;
  my $urls =
    qr/((https?:\/\/|www\.)([-\w\.]+)+(:\d+)?(\/([\w\/_\.\-\%]*(\?\S+)?)?)?)/;
  $s =~
    s!$urls!my $u=$1;
            $u =~ s/(\.)$//
              ? '<a href="'.$u.'">'.$u.'</a>.'
              : '<a href="'.$u.'">'.$u.'</a>'!ge;
  $s
}

# Render a comment into HTML.
# 'c' is the comment representation as a Ruby hash.
# 'u' is the user, obtained from the user_id by the caller.
sub comment_to_html {
  my ($c, $u) = @_;
  my $indent =
    'margin-left:'.(($c->{'level'}||0)*$cfg->{CommentReplyShift}).'px';
  my $score = compute_comment_score($c);
  my $news_id = $c->{'thread_id'};

  if ($c->{'del'}) {
    return $h->article(style => $indent, class => 'commented deleted',
                       '[comment deleted]');
  }
  my $show_edit_link = !$c->{'topcomment'} &&
                       ($user && ($user->{'id'} == $c->{'user_id'})) &&
                       ($c->{'ctime'} > (time - $cfg->{CommentEditTime}));

  $h->article(class => 'comment', style => $indent,
              'data-comment-id' => $news_id.'-'.$c->{'id'},
    avatar($u->{'email'}).
    $h->span(class => 'info',
      $h->span(class => 'username',
        $h->a(href=>'/user/'.HTMLGen::urlencode($u->{'username'}),
              HTMLGen::entities($u->{'username'}))
        ).' '.str_elapsed($c->{'ctime'}).'. '.
        (!$c->{'topcomment'} ?
         $h->a(href => '/comment/'.$news_id.'/'.$c->{'id'}, class => 'reply',
               'link') : '').' '.
        ($user and !$c->{'topcomment'} ?
         $h->a(href => '/reply/'.$news_id.'/'.$c->{'id'},
               class => 'reply', 'reply').' ' :
         ' ').
        (!$c->{'topcomment'} ?
         do {
           my $upclass = 'uparrow';
           my $downclass = 'downarrow';
           if ($user and $c->{'up'} and
               (grep { $_ eq $user->{'id'} } @{$c->{'up'}})) {
             $upclass .= ' voted';
             $downclass .= ' disabled';
           } elsif ($user and $c->{'down'} and
                    (grep { $_ eq $user->{'id'} } @{$c->{'down'}})) {
             $downclass .= ' voted';
             $upclass .= ' disabled';
           }
           $score.' points '.
           $h->a(href => '#up', class => $upclass, '&#9650;').' '.
           $h->a(href => '#down', class => $downclass, '&#9660;')
         }
         : ' ').
        ($show_edit_link ?
         $h->a(href => '/editcomment/'.$news_id.'/'.$c->{'id'},
               class => 'reply', 'edit').
         (' ('.int(($cfg->{CommentEditTime} - (time-$c->{'ctime'}))/60).
          ' minutes left)') :
         '')
    ).
    $h->pre(
      urls_to_links(HTMLGen::entities($c->{'body'})) # TODO: .strip
    )
  );
}

sub render_comments_for_news {
  my ($news_id, $root) = @_;
  $root //= -1;
  my $html = '';
  my %user = ();
  $comments->render_comments($news_id, $root,
    sub {
      my ($c) = @_;
      $user{$c->{'id'}} = get_user_by_id($c->{'user_id'})
        unless ($user{$c->{'id'}});
      $user{$c->{'id'}} = $cfg->{DeletedUser} unless ($user{$c->{'id'}});
      $html .= comment_to_html($c, $user{$c->{'id'}});
    });
  $h->div(id => 'comments', $html);
}

sub vote_comment {
  my ($news_id, $comment_id, $user_id, $vote_type) = @_;
  my $comment = $comments->fetch($news_id, $comment_id);
  return unless ($comment);
  my $varray = $comment->{$vote_type} || [];
  return if (grep { $_ eq $user_id } @$varray);
  push @$varray, $user_id;
  return $comments->edit($news_id, $comment_id, { $vote_type => $varray });
}

# Get comments in chronological order for the specified user in the
# specified range.
sub get_user_comments {
  my ($user_id, $start, $count) = @_;
  my $numitems = $r->zcard('user.comments:'.$user_id);
  my $ids = $r->zrevrange('user.comments:'.$user_id,
                          $start, $start+($count-1));
  my @comments = ();
  foreach my $id (@$ids) {
    my ($news_id, $comment_id) = split /-/, $id, 2;
    my $comment = $comments->fetch($news_id, $comment_id);
    push @comments, $comment if ($comment);
  }
  (\@comments, $numitems);
}

###############################################################################
# Utility functions
###############################################################################

# Given an unix time in the past returns a string stating how much time
# has elapsed from the specified time, in the form "2 hours ago".
sub str_elapsed {
  my $t = shift;
  my $seconds = time - $t;
  return 'now' if ($seconds <= 1);
  return $seconds.' seconds ago' if ($seconds < 60);
  return int($seconds/60).' minutes ago' if ($seconds < 3600);
  return int($seconds/3600).' hours ago' if ($seconds < 86400);
  return int($seconds/86400).' days ago'
}

# Generic API limiting function
sub rate_limit_by_ip {
  my $delay = shift;
  my $key = 'limit:'.join('.', @_);
  return 1 if ($r->exists($key));
  $r->setex($key, $delay, 1);
  return;
}

# Show list of items with show-more style pagination.
#
# The function sole argument is an hash with the following fields:
#
# :get     A function accepinng start/count that will return two values:
#          1) A list of elements to paginate.
#          2) The total amount of items of this type.
#
# :render  A function that given an element obtained with :get will turn
#          in into a suitable representation (usually HTML).
#
# :start   The current start (probably obtained from URL).
#
# :perpage Number of items to show per page.
#
# :link    A string that is used to obtain the url of the [more] link
#          replacing '$' with the right value for the next page.
#
# Return value: the current page rendering.
sub list_items {
  my ($o) = @_;
  my $aux = '';
  $o->{start} = 0 if ($o->{start} < 0);
  my ($items, $count) = $o->{get}->($o->{start}, $o->{perpage});
  foreach my $n (@$items) {
    $aux .= $o->{render}->($n);
  }
  my $last_displayed = $o->{start} + $o->{perpage};
  if ($last_displayed < $count) {
    my $nextpage = $o->{link};
    $nextpage =~ s/\$/$nextpage/;
    $aux .= $h->a(href => $nextpage, class => 'more', '[more]')
  }
  $aux
}

$app;
