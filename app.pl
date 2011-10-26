#!/usr/bin/perl
use warnings;
use strict;
use feature ":5.10";
use Redis::hiredis;
use Digest::MD5 qw/md5_hex/;
use Digest::SHA qw/sha1_hex/;
use Data::Show qw/show/;
use JSON;
use HTMLGen;
use Plack::Builder;
use Plack::Request;
use YAML;

unless (caller) {
  require Plack::Runner;
  Plack::Runner->run(@ARGV, $0);
}

my $cfg = YAML::LoadFile('app_config.yml');
our $VERSION = '0.1';

our %ct =
  (
   png => 'image/png',
   js => 'text/javascript',
   css => 'text/css',
  );

my $todo;
my $r;
my $h;
my $user;
my $app =
  sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    $r = Redis::hiredis->new(host => $cfg->{RedisHost},
                             port => $cfg->{RedisPort});
    # Comments
    $user = auth_user($req->cookies->{auth});
    increment_karma_if_needed($user) if ($user);
    $h = HTMLGen->new(header => \&header, footer => \&footer);
    my $p;
    show $req->path_info;
    given ($req->path_info) {
      when ('/') {
        $h->set_title('Top News - '.$cfg->{SiteName});
        my $news = get_top_news();
        $p = $h->page($h->h2('Top News').news_list_to_html($news));
      }
      when ('/latest') {
        $h->set_title("Latest News - ".$cfg->{SiteName});
        my $news = get_latest_news();
        $p = $h->page($h->h2('Latest news').news_list_to_html($news));
      }
      when (qr!^/(?:css|js|images)/.*\.([a-z]+)$!) {
        my $ct = $ct{$1};
        if (/\.\./ or !defined $ct) {
          return [ 404, ['Content-Type' => 'text/plain'], ["Not found"] ]
        } else {
          open my $fh, 'public'.$_ or
            return [ 404, ['Content-Type' => 'text/plain'], ["Not found"] ];
          return [ 200, ['Content-Type' => $ct], $fh ]
        }
      }
      default { return [ 404, ['Content-Type' => 'text/plain'], ["Not found"] ]}
    }
    return [200, [ 'Content-Type' => 'text/html' ], [$p]];
  };

$todo = q~
get '/saved/:start' do
    redirect "/login" if !$user
    start = params[:start].to_i
    start = 0 if start < 0
    H.set_title "Saved news - #{SiteName}"
    news,count = get_saved_news($user['id'],start)
    paginate = {
        :start => start,
        :count => count,
        :perpage => SavedNewsPerPage,
        :link => "/saved/$"
    }
    H.page {
        H.h2 {"Your saved news"}+news_list_to_html(news,paginate)
    }
end

get '/login' do
    H.set_title "Login - #{SiteName}"
    H.page {
        H.div(:id => "login") {
            H.form(:name=>"f") {
                H.label(:for => "username") {"username"}+
                H.inputtext(:id => "username", :name => "username")+
                H.label(:for => "password") {"password"}+
                H.inputpass(:id => "password", :name => "password")+H.br+
                H.checkbox(:name => "register", :value => "1")+
                "create account"+H.br+
                H.button(:name => "do_login", :value => "Login")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("input[name=do_login]").click(login);
            });
        '}
    }
end

get '/submit' do
    redirect "/login" if !$user
    H.set_title "Submit a new story - #{SiteName}"
    H.page {
        H.h2 {"Submit a new story"}+
        H.form(:id => "submitform") {
            H.form(:name=>"f") {
                H.inputhidden(:name => "news_id", :value => -1)+
                H.label(:for => "title") {"title"}+
                H.inputtext(:id => "title", :name => "title", :size => 80)+H.br+
                H.label(:for => "url") {"url"}+H.br+
                H.inputtext(:id => "url", :name => "url", :size => 60)+H.br+
                "or if you don't have an url type some text"+
                H.br+
                H.label(:for => "text") {"text"}+
                H.textarea(:id => "text", :name => "text", :cols => 60, :rows => 10) {}+
                H.button(:name => "do_submit", :value => "Submit")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("input[name=do_submit]").click(submit);
            });
        '}
    }
end

get '/logout' do
    if $user and check_api_secret
        update_auth_token($user["id"])
    end
    redirect "/"
end

get "/news/:news_id" do
    news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    # Show the news text if it is a news without URL.
    if !news_domain(news)
        c = {
            "body" => news_text(news),
            "ctime" => news["ctime"],
            "user_id" => news["user_id"],
            "topcomment" => true
        }
        user = get_user_by_id(news["user_id"]) or DeletedUser
        top_comment = H.topcomment {comment_to_html(c,user,news['id'])}
    else
        top_comment = ""
    end
    H.set_title "#{H.entities news["title"]} - #{SiteName}"
    H.page {
        H.section(:id => "newslist") {
            news_to_html(news)
        }+top_comment+
        if $user
            H.form(:name=>"f") {
                H.inputhidden(:name => "news_id", :value => news["id"])+
                H.inputhidden(:name => "comment_id", :value => -1)+
                H.inputhidden(:name => "parent_id", :value => -1)+
                H.textarea(:name => "comment", :cols => 60, :rows => 10) {}+H.br+
                H.button(:name => "post_comment", :value => "Send comment")
            }+H.div(:id => "errormsg"){}
        else
            H.br
        end +
        render_comments_for_news(news["id"])+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get "/reply/:news_id/:comment_id" do
    redirect "/login" if !$user
    news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = Comments.fetch(params["news_id"],params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    user = get_user_by_id(comment["user_id"]) or DeletedUser
    comment["id"] = params["comment_id"]

    H.set_title "Reply to comment - #{SiteName}"
    H.page {
        news_to_html(news)+
        comment_to_html(comment,user,params["news_id"])+
        H.form(:name=>"f") {
            H.inputhidden(:name => "news_id", :value => news["id"])+
            H.inputhidden(:name => "comment_id", :value => -1)+
            H.inputhidden(:name => "parent_id", :value => params["comment_id"])+
            H.textarea(:name => "comment", :cols => 60, :rows => 10) {}+H.br+
            H.button(:name => "post_comment", :value => "Reply")
        }+H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get "/editcomment/:news_id/:comment_id" do
    redirect "/login" if !$user
    news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = Comments.fetch(params["news_id"],params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    user = get_user_by_id(comment["user_id"]) or DeletedUser
    halt(500,"Permission denied.") if $user['id'].to_i != user['id'].to_i
    comment["id"] = params["comment_id"]

    H.set_title "Edit comment - #{SiteName}"
    H.page {
        news_to_html(news)+
        comment_to_html(comment,user,params["news_id"])+
        H.form(:name=>"f") {
            H.inputhidden(:name => "news_id", :value => news["id"])+
            H.inputhidden(:name => "comment_id",:value => params["comment_id"])+
            H.inputhidden(:name => "parent_id", :value => -1)+
            H.textarea(:name => "comment", :cols => 60, :rows => 10) {
                H.entities comment['body']
            }+H.br+
            H.button(:name => "post_comment", :value => "Edit")
        }+H.div(:id => "errormsg"){}+
        H.note {
            "Note: to remove the comment remove all the text and press Edit."
        }+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get "/editnews/:news_id" do
    redirect "/login" if !$user
    news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    halt(500,"Permission denied.") if $user['id'].to_i != news['user_id'].to_i

    if news_domain(news)
        text = ""
    else
        text = news_text(news)
        news['url'] = ""
    end
    H.set_title "Edit news - #{SiteName}"
    H.page {
        news_to_html(news)+
        H.form(:id => "submitform") {
            H.form(:name=>"f") {
                H.inputhidden(:name => "news_id", :value => news['id'])+
                H.label(:for => "title") {"title"}+
                H.inputtext(:id => "title", :name => "title", :size => 80,
                            :value => H.entities(news['title']))+H.br+
                H.label(:for => "url") {"url"}+H.br+
                H.inputtext(:id => "url", :name => "url", :size => 60,
                            :value => H.entities(news['url']))+H.br+
                "or if you don't have an url type some text"+
                H.br+
                H.label(:for => "text") {"text"}+
                H.textarea(:id => "text", :name => "text", :cols => 60, :rows => 10) {
                    H.entities(text)
                }+H.button(:name => "edit_news", :value => "Edit")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.note {
            "Note: to remove the news set an empty title."
        }+
        H.script() {'
            $(function() {
                $("input[name=edit_news]").click(submit);
            });
        '}
    }
end

get "/user/:username" do
    user = get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user
    posted_news,posted_comments = $r.pipelined {
        $r.zcard("user.posted:#{user['id']}")
        $r.zcard("user.comments:#{user['id']}")
    }
    H.set_title "#{H.entities user['username']} - #{SiteName}"
    owner = $user && ($user['id'].to_i == user['id'].to_i)
    H.page {
        H.div(:class => "userinfo") {
            H.span(:class => "avatar") {
                email = user["email"] || ""
                digest = Digest::MD5.hexdigest(email)
                H.img(:src=>"http://gravatar.com/avatar/#{digest}?s=48&d=mm")
            }+" "+
            H.h2 {H.entities user['username']}+
            H.pre {
                H.entities user['about']
            }+
            H.ul {
                H.li {
                    H.b {"created "}+
                    "#{(Time.now.to_i-user['ctime'].to_i)/(3600*24)} days ago"
                }+
                H.li {H.b {"karma "}+ "#{user['karma']} points"}+
                H.li {H.b {"posted news "}+posted_news.to_s}+
                H.li {H.b {"posted comments "}+posted_comments.to_s}+
                if owner
                    H.li {H.a(:href=>"/saved/0") {"saved news"}}
                else "" end
            }
        }+if owner
            H.br+H.form(:name=>"f") {
                H.label(:for => "email") {
                    "email (not visible, used for gravatar)"
                }+H.br+
                H.inputtext(:id => "email", :name => "email", :size => 40,
                            :value => H.entities(user['email']))+H.br+
                H.label(:for => "password") {
                    "change password (optional)"
                }+H.br+
                H.inputpass(:name => "password", :size => 40)+H.br+
                H.label(:for => "about") {"about"}+H.br+
                H.textarea(:id => "about", :name => "about", :cols => 60, :rows => 10){
                    H.entities(user['about'])
                }+H.br+
                H.button(:name => "update_profile", :value => "Update profile")
            }+
            H.div(:id => "errormsg"){}+
            H.script() {'
                $(function() {
                    $("input[name=update_profile]").click(update_profile);
                });
            '}
        else "" end
    }
end

###############################################################################
# API implementation
###############################################################################

post '/api/logout' do
    if $user and check_api_secret
        update_auth_token($user["id"])
        return {:status => "ok"}.to_json
    else
        return {
            :status => "err",
            :error => "Wrong auth credentials or API secret."
        }
    end
end

get '/api/login' do
    auth,apisecret = check_user_credentials(params[:username],
                                            params[:password])
    if auth 
        return {
            :status => "ok",
            :auth => auth,
            :apisecret => apisecret
        }.to_json
    else
        return {
            :status => "err",
            :error => "No match for the specified username / password pair."
        }.to_json
    end
end

post '/api/create_account' do
    if (!check_params "username","password")
        return {
            :status => "err",
            :error => "Username and password are two required fields."
        }.to_json
    end
    if params[:password].length < PasswordMinLength
        return {
            :status => "err",
            :error => "Password is too short. Min length: #{PasswordMinLength}"
        }.to_json
    end
    auth,errmsg = create_user(params[:username],params[:password])
    if auth 
        return {:status => "ok", :auth => auth}.to_json
    else
        return {
            :status => "err",
            :error => errmsg
        }.to_json
    end
end

post '/api/submit' do
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end

    if submitted_recently
        return {:status => "err", :error => "You have submitted a story too recently, please wait #{allowed_to_post_in_seconds} seconds."}.to_json
    end

    # We can have an empty url or an empty first comment, but not both.
    if (!check_params "title","news_id",:url,:text) or
                               (params[:url].length == 0 and
                                params[:text].length == 0)
        return {
            :status => "err",
            :error => "Please specify a news title and address or text."
        }.to_json
    end
    # Make sure the URL is about an acceptable protocol, that is
    # http:// or https:// for now.
    if params[:url].length != 0
        if params[:url].index("http://") != 0 and
           params[:url].index("https://") != 0
            return {
                :status => "err",
                :error => "We only accept http:// and https:// news."
            }.to_json
        end
    end
    if params[:news_id].to_i == -1
        news_id = insert_news(params[:title],params[:url],params[:text],
                              $user["id"])
    else
        news_id = edit_news(params[:news_id],params[:title],params[:url],
                            params[:text],$user["id"])
        if !news_id
            return {
                :status => "err",
                :error => "Invalid parameters, news too old to be modified "+
                          "or url recently posted."
            }.to_json
        end
    end
    return  {
        :status => "ok",
        :news_id => news_id
    }.to_json
end

post '/api/votenews' do
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end
    # Params sanity check
    if (!check_params "news_id","vote_type") or (params["vote_type"] != "up" and
                                                 params["vote_type"] != "down")
        return {
            :status => "err",
            :error => "Missing news ID or invalid vote type."
        }.to_json
    end
    # Vote the news
    vote_type = params["vote_type"].to_sym
    if vote_news(params["news_id"].to_i,$user["id"],vote_type)
        return { :status => "ok" }.to_json
    else
        return { :status => "err", 
                 :error => "Invalid parameters or duplicated vote." }.to_json
    end
end

post '/api/postcomment' do
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end
    # Params sanity check
    if (!check_params "news_id","comment_id","parent_id",:comment)
        return {
            :status => "err",
            :error => "Missing news_id, comment_id, parent_id, or comment
                       parameter."
        }.to_json
    end
    info = insert_comment(params["news_id"].to_i,$user['id'],
                          params["comment_id"].to_i,
                          params["parent_id"].to_i,params["comment"])
    return {
        :status => "err",
        :error => "Invalid news, comment, or edit time expired."
    }.to_json if !info
    return {
        :status => "ok",
        :op => info['op'],
        :comment_id => info['comment_id'],
        :parent_id => params['parent_id'],
        :news_id => params['news_id']
    }.to_json
end

post '/api/updateprofile' do
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if !check_params(:about, :email, :password)
        return {:status => "err", :error => "Missing parameters."}.to_json
    end
    if params[:password].length > 0
        if params[:password].length < PasswordMinLength
            return {
                :status => "err",
                :error => "Password is too short. "+
                          "Min length: #{PasswordMinLength}"
            }.to_json
        end
        $r.hmset("user:#{$user['id']}","password",
            hash_password(params[:password],$user['salt']))
    end
    $r.hmset("user:#{$user['id']}",
        "about", params[:about][0..4095],
        "email", params[:email][0..255])
    return {:status => "ok"}.to_json
end

# Check that the list of parameters specified exist.
# If at least one is missing false is returned, otherwise true is returned.
#
# If a parameter is specified as as symbol only existence is tested.
# If it is specified as a string the parameter must also meet the condition
# of being a non empty string.
def check_params *required
    required.each{|p|
        if !params[p] or (p.is_a? String and params[p].length == 0)
            return false
        end
    }
    true
end

def check_params_or_halt *required
    return if check_parameters *required
    halt 500, H.h1{"500"}+H.p{"Missing parameters"}
end

def check_api_secret
    return false if !$user
    params["apisecret"] and (params["apisecret"] == $user["apisecret"])
end
~;

sub header {
  my ($h) = @_;
  my @navitems =
    (
     ["top" => "/"],
     ["latest" => "/latest"],
     ["submit" => "/submit"],
    );
  my $navbar =
    $h->nav(join("\n",
                 map { $h->a(href => $_->[1], HTMLGen::entities($_->[0]))
                     } @navitems));
  my $rnavbar =
    $h->nav(id => "account",
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
                    " ".$h->small($VERSION)
                   ).$navbar." ".$rnavbar);
}

sub footer {
  my ($h) = @_;
  my $apisecret =
    $user ? $h->script('var apisecret = "'.$user->{'apisecret'}.'"') : '';
  $h->footer("PLamer News source code is located ".
             $h->a(href => "http://github.com/antirez/lamernews", 'here')
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
# Return value: none, the function works by side effect.
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
    $r->hincrby($userkey, 'karma', $cfg->{KarmaIncrementAmount});
    $user->{'karma'} = $user->{'karma'} + $cfg->{KarmaIncrementAmount};
  }
}

# Return the hex representation of an unguessable 160 bit random number.
sub get_rand {
  open my $fh, '/dev/urandom';
  local $/ = \20;
  my $bytes = <$fh>;
  close $fh;
  unpack 'H*', $bytes;
}

$todo = q~
# Create a new user with the specified username/password
#
# Return value: the function returns two values, the first is the
#               auth token if the registration succeeded, otherwise
#               is nil. The second is the error message if the function
#               failed (detected testing the first return value).
def create_user(username,password)
    if $r.exists("username.to.id:#{username.downcase}")
        return nil, "Username is busy, please try a different one."
    end
    if rate_limit_by_ip(3600*15,"create_user",request.ip)
        return nil, "Please wait some time before creating a new user."
    end
    id = $r.incr("users.count")
    auth_token = get_rand
    salt = get_rand
    $r.hmset("user:#{id}",
        "id",id,
        "username",username,
        "salt",salt,
        "password",hash_password(password,salt),
        "ctime",Time.now.to_i,
        "karma",10,
        "about","",
        "email","",
        "auth",auth_token,
        "apisecret",get_rand,
        "flags","",
        "karma_incr_time",Time.new.to_i)
    $r.set("username.to.id:#{username.downcase}",id)
    $r.set("auth:#{auth_token}",id)
    return auth_token,nil
end

# Update the specified user authentication token with a random generated
# one. This in other words means to logout all the sessions open for that
# user.
#
# Return value: on success the new token is returned. Otherwise nil.
# Side effect: the auth token is modified.
def update_auth_token(user_id)
    user = get_user_by_id(user_id)
    return nil if !user
    $r.del("auth:#{user['auth']}")
    new_auth_token = get_rand
    $r.hmset("user:#{user_id}","auth",new_auth_token)
    $r.set("auth:#{new_auth_token}",user_id)
    return new_auth_token
end

# Turn the password into an hashed one, using PBKDF2 with HMAC-SHA1
# and 160 bit output.
def hash_password(password,salt)
    p = PBKDF2.new do |p|
        p.iterations = PBKDF2Iterations
        p.password = password
        p.salt = salt
        p.key_length = 160/8
    end
    p.hex_string
end

# Return the user from the ID.
def get_user_by_id(id)
    $r.hgetall("user:#{id}")
end

# Return the user from the username.
def get_user_by_username(username)
    id = $r.get("username.to.id:#{username.downcase}")
    return nil if !id
    get_user_by_id(id)
end

# Check if the username/password pair identifies an user.
# If so the auth token and form secret are returned, otherwise nil is returned.
def check_user_credentials(username,password)
    user = get_user_by_username(username)
    return nil if !user
    hp = hash_password(password,user['salt'])
    (user['password'] == hp) ? [user['auth'],user['apisecret']] : nil
end

# Has the user submitted a news story in the last `NewsSubmissionBreak` seconds?
def submitted_recently
  allowed_to_post_in_seconds > 0
end

# Indicates when the user is allowed to submit another story after the last.
def allowed_to_post_in_seconds
  $r.ttl("user:#{$user['id']}:submitted_recently")
end

~;

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
    # TODO:  update_news_rank_if_needed(hash) if opt[:update_rank]
    push @result, \%h;
  }

  # Get the associated users information
  foreach (@result) { # TODO: pipeline?
    $_->{'username'} = $r->hget('user:'.$_->{'user_id'}, "username");
    $_->{'voted'} = 0;
  }

  # Load $User vote information if we are in the context of a
  # registered user.

$todo = q~
    if $user
        votes = $r.pipelined {
            result.each{|n|
                $r.zscore("news.up:#{n["id"]}",$user["id"])
                $r.zscore("news.down:#{n["id"]}",$user["id"])
            }
        }
        result.each_with_index{|n,i|
            if votes[i*2]
                n["voted"] = :up
            elsif votes[(i*2)+1]
                n["voted"] = :down
            end
        }
    end
~;

  # Return an array if we got an array as input, otherwise
  # the single element the caller requested.
  return $opt{single} ? $result[0] : \@result;
}

$todo = q~
# Vote the specified news in the context of a given user.
# type is either :up or :down
#
# The function takes care of the following:
# 1) The vote is not duplicated.
# 2) That the karma is decreased from voting user, accordingly to vote type.
# 3) That the karma is transfered to the author of the post, if different.
# 4) That the news score is updaed.
#
# Return value: the news rank if the vote was inserted, otherwise
# if the vote was duplicated, or user_id or news_id don't match any
# existing user or news, false is returned.
def vote_news(news_id,user_id,vote_type)
    # Fetch news and user
    user = ($user and $user["id"] == user_id) ? $user : get_user_by_id(user_id)
    news = get_news_by_id(news_id)
    return false if !news or !user

    # Now it's time to check if the user already voted that news, either
    # up or down. If so return now.
    if $r.zscore("news.up:#{news_id}",user_id) or
       $r.zscore("news.down:#{news_id}",user_id)
       return false
    end

    # News was not already voted by that user. Add the vote.
    # Note that even if there is a race condition here and the user may be
    # voting from another device/API in the time between the ZSCORE check
    # and the zadd, this will not result in inconsistencies as we will just
    # update the vote time with ZADD.
    if $r.zadd("news.#{vote_type}:#{news_id}", Time.now.to_i, user_id)
        $r.hincrby("news:#{news_id}",vote_type,1)
    end
    $r.zadd("user.saved:#{user_id}", Time.now.to_i, news_id) if vote_type == :up

    # Compute the new values of score and karma, updating the news accordingly.
    score = compute_news_score(news)
    news["score"] = score
    rank = compute_news_rank(news)
    $r.hmset("news:#{news_id}",
        "score",score,
        "rank",rank)
    $r.zadd("news.top",rank,news_id)
    return rank
end

# Given the news compute its score.
# No side effects.
def compute_news_score(news)
    upvotes = $r.zrange("news.up:#{news["id"]}",0,-1,:withscores => true)
    downvotes = $r.zrange("news.down:#{news["id"]}",0,-1,:withscores => true)
    # FIXME: For now we are doing a naive sum of votes, without time-based
    # filtering, nor IP filtering.
    # We could use just ZCARD here of course, but I'm using ZRANGE already
    # since this is what is needed in the long term for vote analysis.
    score = (upvotes.length/2) - (downvotes.length/2)
    # Now let's add the logarithm of the sum of all the votes, since
    # something with 5 up and 5 down is less interesting than something
    # with 50 up and 50 donw.
    votes = upvotes.length/2+downvotes.length/2
    if votes > NewsScoreLogStart
        score += Math.log(votes-NewsScoreLogStart)*NewsScoreLogBooster
    end
    score
end

# Given the news compute its rank, that is function of time and score.
#
# The general forumla is RANK = SCORE / (AGE ^ AGING_FACTOR)
def compute_news_rank(news)
    age = (Time.now.to_i - news["ctime"].to_i)+NewsAgePadding
    return (news["score"].to_f*1000)/(age**RankAgingFactor)
end

# Add a news with the specified url or text.
#
# If an url is passed but was already posted in the latest 48 hours the
# news is not inserted, and the ID of the old news with the same URL is
# returned.
#
# Return value: the ID of the inserted news, or the ID of the news with
# the same URL recently added.
def insert_news(title,url,text,user_id)
    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://"+text[0...CommentMaxLength]
    end
    # Check for already posted news with the same URL.
    if !textpost and (id = $r.get("url:"+url))
        return id.to_i
    end
    # We can finally insert the news.
    ctime = Time.new.to_i
    news_id = $r.incr("news.count")
    $r.hmset("news:#{news_id}",
        "id", news_id,
        "title", title,
        "url", url,
        "user_id", user_id,
        "ctime", ctime,
        "score", 0,
        "rank", 0,
        "up", 0,
        "down", 0,
        "comments", 0)
    # The posting user virtually upvoted the news posting it
    rank = vote_news(news_id,user_id,:up)
    # Add the news to the user submitted news
    $r.zadd("user.posted:#{user_id}",ctime,news_id)
    # Add the news into the chronological view
    $r.zadd("news.cron",ctime,news_id)
    # Add the news into the top view
    $r.zadd("news.top",rank,news_id)
    # Add the news url for some time to avoid reposts in short time
    $r.setex("url:"+url,PreventRepostTime,news_id) if !textpost
    # Set a timeout indicating when the user may post again
    $r.setex("user:#{$user['id']}:submitted_recently",NewsSubmissionBreak,'1')
    return news_id
end

# Edit an already existing news.
#
# On success the news_id is returned.
# On success but when a news deletion is performed (empty title) -1 is returned.
# On failure (for instance news_id does not exist or does not match
#             the specified user_id) false is returned.
def edit_news(news_id,title,url,text,user_id)
    news = get_news_by_id(news_id)
    return false if !news or news['user_id'].to_i != user_id.to_i
    return false if !(news['ctime'].to_i > (Time.now.to_i - NewsEditTime))

    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://"+text[0...CommentMaxLength]
    end
    # Even for edits don't allow to change the URL to the one of a
    # recently posted news.
    if !textpost and url != news['url']
        return false if $r.get("url:"+url)
        # No problems with this new url, but the url changed
        # so we unblock the old one and set the block in the new one.
        # Otherwise it is easy to mount a DOS attack.
        $r.del("url:"+news['url'])
        $r.setex("url:"+url,PreventRepostTime,news_id) if !textpost
    end
    # Edit the news fields.
    $r.hmset("news:#{news_id}",
        "title", title,
        "url", url)
    return news_id
end
~;

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

# Turn the news into its HTML representation, that is
# a linked title with buttons to up/down vote plus additional info.
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
sub news_to_html {
  my ($news) = @_;
  my $domain = news_domain($news);
  my %news = %$news; # Copy the object so we can modify it as we wish.
  $news{'url'} = '/news/'.$news{'id'} unless ($domain);
  my $upclass;
  my $downclass;
  if ($news{'voted'} == 1) {
    $upclass = 'uparrow voted';
    $downclass = 'downarrow disabled';
  } elsif ($news{'voted'} == -1) {
    $downclass = 'downarrow voted';
    $upclass = 'downarrow disabled';
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
        )#+news["score"].to_s+","+news["rank"].to_s+","+compute_news_rank(news).to_s
  )."\n"
}

# If 'news' is a list of news entries (Ruby hashes with the same fields of
# the Redis hash representing the news in the DB) this function will render
# the HTML needed to show this news.
sub news_list_to_html {
  my $news = shift;
  my $paginate = shift;

$todo = q~
        if paginate
            last_displayed = paginate[:start]+paginate[:perpage]
            if last_displayed < paginate[:count]
                nextpage = paginate[:link].sub("$",
                           (paginate[:start]+paginate[:perpage]).to_s)
                aux << H.a(:href => nextpage,:class=> "more") {"[more]"}
            end
        end
        aux
~;
  $h->section(id => 'newslist',
              join '', map { news_to_html($_) } @$news);
}

$todo = q~
# Updating the rank would require some cron job and worker in theory as
# it is time dependent and we don't want to do any sorting operation at
# page view time. But instead what we do is to compute the rank from the
# score and update it in the sorted set only if there is some sensible error.
# This way ranks are updated incrementally and "live" at every page view
# only for the news where this makes sense, that is, top news.
#
# Note: this function can be called in the context of redis.pipelined {...}
def update_news_rank_if_needed(n)
    real_rank = compute_news_rank(n)
    if (real_rank-n["rank"].to_f).abs > 0.001
        $r.hmset("news:#{n["id"]}","rank",real_rank)
        $r.zadd("news.top",real_rank,n["id"])
        n["rank"] = real_rank.to_s
    end
end

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
~;

sub get_top_news {
  my $news_ids = $r->zrevrange('news.top', 0, $cfg->{TopNewsPerPage}-1);
  my $result = get_news_by_id($news_ids, update_rank => 1);
  # Sort by rank before returning, since we adjusted ranks during iteration.
  [sort { $b->{rank} <=> $a->{rank} } @$result];
}

$todo = q~
# Get news in chronological order.
def get_latest_news
    news_ids = $r.zrevrange("news.cron",0,LatestNewsPerPage-1)
    get_news_by_id(news_ids,:update_rank => true)
end

# Get saved news of current user
def get_saved_news(user_id,start=0)
    count = $r.zcard("user.saved:#{user_id}").to_i
    news_ids = $r.zrevrange("user.saved:#{user_id}",start,start+(SavedNewsPerPage-1))
    return get_news_by_id(news_ids),count
end

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
def insert_comment(news_id,user_id,comment_id,parent_id,body)
    puts "news_id: #{news_id}"
    puts "comment_id: #{comment_id}"
    puts "parent_id: #{parent_id}"
    puts "body: #{body}"
    news = get_news_by_id(news_id)
    return false if !news
    if comment_id == -1
        comment = {"score" => 0,
                   "body" => body,
                   "parent_id" => parent_id,
                   "user_id" => user_id,
                   "ctime" => Time.now.to_i};
        comment_id = Comments.insert(news_id,comment)
        return false if !comment_id
        $r.hincrby("news:#{news_id}","comments",1);
        $r.zadd("user.comments:#{user_id}",
            Time.now.to_i,
            news_id.to_s+"-"+comment_id.to_s);
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "insert"
        }
    end

    # If we reached this point the next step is either to update or
    # delete the comment. So we make sure the user_id of the request
    # matches the user_id of the comment.
    # We also make sure the user is in time for an edit operation.
    c = Comments.fetch(news_id,comment_id)
    return false if !c or c['user_id'].to_i != user_id.to_i
    return false if !(c['ctime'].to_i > (Time.now.to_i - CommentEditTime))

    if body.length == 0
        return false if !Comments.del_comment(news_id,comment_id)
        $r.hincrby("news:#{news_id}","comments",-1);
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "delete"
        }
    else
        update = {"body" => body}
        update = {"del" => 0} if c['del'].to_i == 1
        return false if !Comments.edit(news_id,comment_id,update)
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "update"
        }
    end
end

# Render a comment into HTML.
# 'c' is the comment representation as a Ruby hash.
# 'u' is the user, obtained from the user_id by the caller.
def comment_to_html(c,u,news_id)
    indent = "margin-left:#{c['level'].to_i*CommentReplyShift}px"

    if c['del'] and c['del'].to_i == 1
        return H.article(:style => indent,:class=>"commented deleted") {
            "[comment deleted]"
        }
    end
    H.article(:class => "comment", :style=>indent, "data-comment-id"=>"#{news_id}-#{c['id']}") {
        H.span(:class => "avatar") {
            email = u["email"] || ""
            digest = Digest::MD5.hexdigest(email)
            H.img(:src=>"http://gravatar.com/avatar/#{digest}?s=48&d=mm")
        }+H.span(:class => "info") {
            H.span(:class => "username") {
                H.a(:href=>"/user/"+H.urlencode(u["username"])) {
                    H.entities u["username"]
                }
            }+" "+str_elapsed(c["ctime"].to_i)+". "+
            if $user and !c['topcomment']
                H.a(:href=>"/reply/#{news_id}/#{c["id"]}", :class=>"reply") {
                    "reply"
                }+" "
            else
                " "
            end +
            if !c['topcomment'] and
               ($user and ($user['id'].to_i == c['user_id'].to_i)) and
               (c['ctime'].to_i > (Time.now.to_i - CommentEditTime))
                H.a(:href=> "/editcomment/#{news_id}/#{c["id"]}",
                    :class =>"reply") {"edit"}+
                    " (#{
                        (CommentEditTime - (Time.now.to_i-c['ctime'].to_i))/60
                    } minutes left)"
            else "" end
        }+H.pre {
            H.entities(c["body"].strip)
        }
    }
end

def render_comments_for_news(news_id)
    html = ""
    user = {}
    Comments.render_comments(news_id) {|c|
        user[c["id"]] = get_user_by_id(c["user_id"]) if !user[c["id"]]
        user[c["id"]] = DeletedUser if !user[c["id"]]
        u = user[c["id"]]
        html << comment_to_html(c,u,news_id)
    }
    html
end

~;

###############################################################################
# Utility functions
###############################################################################

# Given an unix time in the past returns a string stating how much time
# has elapsed from the specified time, in the form "2 hours ago".
sub str_elapsed {
  my $t = shift;
  my $seconds = time - $t;
  return "now" if ($seconds <= 1);
  return $seconds.' seconds ago' if ($seconds < 60);
  return int($seconds/60).' minutes ago' if ($seconds < 60*60);
  return int($seconds/3600).' hours ago' if ($seconds < 60*60*24);
  return int($seconds/86400).' days ago'
}

$todo = q~
# Generic API limiting function
def rate_limit_by_ip(delay,*tags)
    key = "limit:"+tags.join(".")
    return true if $r.exists(key)
    $r.setex(key,delay,1)
    return false
end
~;

$app;
