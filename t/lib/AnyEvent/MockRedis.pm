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
use Data::Show;

=action C<recvredis($handle, $actions, $expect, $desc)>

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
