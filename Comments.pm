use strict;
use warnings;
package Comments;

# ABSTRACT: Comments module

=head1 SYNOPSIS

=head1 DESCRIPTION

Comments module.

=cut

use constant DEBUG => $ENV{COMMENTS_DEBUG};
use JSON;

sub new {
  my ($pkg, %p) = @_;
  bless { json => JSON->new, %p }, $pkg;
}

sub thread_key {
  my ($self, $id) = @_;
  'thread:'.$self->{namespace}.':'.$id
}

sub fetch {
  my ($self, $thread_id, $comment_id) = @_;
  my $key = $self->thread_key($thread_id);
  my $json = $self->{redis}->hget($key, $comment_id);
  return unless ($json);
  $json = $self->{json}->decode($json);
  $json->{'thread_id'} = $thread_id;
  $json->{'id'} = $comment_id;
  $json
}

sub insert {
  my ($self, $thread_id, $comment) = @_;
  die 'no parent_id field' unless (exists $comment->{'parent_id'});
  my $r = $self->{redis};
  my $key = $self->thread_key($thread_id);
  if ($comment->{'parent_id'} != -1) {
    my $parent = $r->hget($key, $comment->{'parent_id'});
    return unless ($parent);
  }
  my $id = $r->hincrby($key, 'nextid', 1);
  $r->hset($key, $id, $self->{json}->encode($comment));
  return $id;
}

sub edit {
  my ($self, $thread_id, $comment_id, $updates) = @_;
  my $r = $self->{redis};
  my $key = $self->thread_key($thread_id);
  my $old = $r->hget($key, $comment_id);
  return unless ($old);
  my %comment = ( %{$self->{json}->decode($old)}, %$updates );
  $r->hset($key, $comment_id, $self->{json}->encode(\%comment));
  return 1;
}

sub remove_thread {
  my ($self, $thread_id) = @_;
  $self->{redis}->del($self->thread_key($thread_id));
}

sub comments_in_thread {
  my ($self, $thread_id) = @_;
  $self->{redis}->hlen($self->thread_key($thread_id));
}

sub del_comment {
  my ($self, $thread_id, $comment_id) = @_;
  $self->edit($thread_id, $comment_id, {"del" => 1});
}

sub render_comments {
  my ($self, $thread_id, $root, $block) = @_;
  my $r = $self->{redis};
  my $key = $self->thread_key($thread_id);
  my %byparent = ();
  my $all = $r->hgetall($key);
  while (@$all) {
    my ($id, $comment) = splice @$all, 0, 2;
    next if ($id eq 'nextid');
    my $c = $self->{json}->decode($comment);
    $c->{id} = $id;
    $c->{thread_id} = $thread_id;
    my $parent_id = $c->{'parent_id'};
    push @{$byparent{$parent_id}}, $c;
  }
  $self->render_comments_rec(\%byparent, $root, 0, $block)
    if ($byparent{-1});
}

sub render_comments_rec {
  my ($self, $byparent, $parent_id, $level, $block) = @_;
  my $thislevel = $byparent->{$parent_id};
  return '' unless ($thislevel);
  $thislevel = $self->{sort_proc}->($thislevel, $level) if ($self->{sort_proc});
  foreach my $c (@$thislevel) {
    $c->{'level'} = $level;
    my $parents = $byparent->{$c->{'id'}};
    # Render the comment if not deleted, or if deleted but
    # has replies.
    $block->($c) if (!$c->{'del'} || @$parents);
    if ($parents) {
      $self->render_comments_rec($byparent, $c->{'id'}, $level+1, $block);
    }
  }
}

# In this example we want comments at top level sorted in reversed chronological
# order, but all the sub trees sorted in plain chronological order.
# comments = RedisComments.new(Redis.new,"mycomments",proc{|c,level|
#     if level == 0
#         c.sort {|a,b| b['ctime'] <=> a['ctime']}
#     else
#         c.sort {|a,b| a['ctime'] <=> b['ctime']}
#     end
# })
# 
# comments.remove_thread(50)
# first_id = comments.insert(50,
#     {'body' => 'First comment at top level','parent_id'=>-1,'ctime'=>1000}
# )
# second_id = comments.insert(50,
#     {'body' => 'Second comment at top level','parent_id'=>-1,'ctime'=>1001}
# )
# id = comments.insert(50,
#     {'body' => 'reply number one','parent_id'=>second_id,'ctime'=>1002}
# )
# id = comments.insert(50,
#     {'body' => 'reply to reply','parent_id'=>id,'ctime'=>1003}
# )
# id = comments.insert(50,
#     {'body' => 'reply number two','parent_id'=>second_id,'ctime'=>1002}
# )
# rendered_comments = comments.render_comments(50) {|c|
#     puts ("  "*c['level']) + c['body']
# }

1;
