use strict;
use warnings;
package AnyEvent::MockRedis;
use base 'AnyEvent::MockTCPServer';

use constant {
  DEBUG => $ENV{ANYEVENT_MOCK_REDIS_DEBUG}
};

use AnyEvent;
use AnyEvent::Handle;
use Test::More;
use Sub::Name;
use Carp qw/croak/;
use Data::Show;

=head2 C<sendredis($handle, $actions, $send, $desc)>

Sends the redis message, C<$send>, to the client.

=cut

sub sendredis {
  my ($self, $handle, $actions, $send, $desc) = @_;
  unless (defined $desc) {
    $desc = ref $send ? 'redis reply' : $send;
    $desc = substr($desc, 0, 60).'...' if (length $desc > 63);
  }
  print STDERR 'Sending: ', $desc, "\n" if DEBUG;
  print STDERR 'Sending ', length $send, " bytes\n" if DEBUG;
  $handle->push_write(_encode($send));
  $self->next_action($handle, $actions);
}

sub _encode {
  my $s = shift;
  if (ref $s) {
    my ($t, $v) = @$s;
    if ($t eq '$') {
      $s = '$'.length($v)."\r\n".$v."\r\n";
    } elsif ($t eq '*') {
      $s = '*'.(scalar @$v)."\r\n".join '', map { _encode(['$' => $_]) } @$v;
    } else {
      croak "Invalid redis message @$s\n";
    }
  } else {
    $s .= "\r\n" unless ($s =~ /\r\n$/);
  }
  return $s;
}

=head2 C<recvredis($handle, $actions, $expect, $desc)>

Waits for a redis protocol message of data C<$expect> from the client.

=cut

sub recvredis {
  my ($self, $handle, $actions, $expect, $desc) = @_;
  unless (defined $desc) {
    $desc = join ' ', @$expect;
    $desc = substr($desc, 0, 60).'...' if (length $desc > 63);
  }
  print STDERR 'Waiting for ', $desc, "\n" if DEBUG;
  print STDERR "Waiting for line\n" if DEBUG;
  my $cb;
  my $i = 0;
  $cb =
    sub {
      my ($hdl, $data) = @_;
      my $recv = shift @$expect;
      my $d = "..... length\[$i]: $recv";
      if (ref $recv) {
        like($data, qr!^\$\d+$!, $d);
      } else {
        is($data, '$'.(length $recv), $d);
      }
      $hdl->push_read(line => sub {
        my ($hdl, $data) = @_;
        my $d = "..... value\[$i]: $recv";
        if (ref $recv) {
          like($data, $recv, $d);
        } else {
          is($data, $recv, $d);
        }
        if (@$expect) {
          $i++;
          $hdl->push_read(line => $cb);
        } else {
          $self->next_action($hdl, $actions) unless (@$expect);
        }
        1;
      });
    };

  $handle->push_read(
    line => sub {
      my ($hdl, $data) = @_;
      is($data, '*'.@$expect, '... redis # args - '.$desc);
      $hdl->push_read(line => $cb);
      1;
    });
}

1;
