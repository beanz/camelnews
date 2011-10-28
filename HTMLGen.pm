use strict;
use warnings;
package HTMLGen;

# ABSTRACT: HTML Generation module

=head1 SYNOPSIS

=head1 DESCRIPTION

HTML generation module.

=cut

use constant DEBUG => $ENV{HTMLGEN_DEBUG};
use URI::Escape ();
use HTML::Entities ();

our %newlinetags =
  map { $_ => 1 } qw/html body div br ul hr title link head filedset label
                     legend option table li select td tr meta/;
our %metatags =
  (
   "js" => {"tag"=>"script"},
   "inputtext" => {"tag"=>"input","type"=>"text"},
   "inputpass" => {"tag"=>"input","type"=>"password"},
   "inputfile" => {"tag"=>"input","type"=>"file"},
   "inputhidden" => {"tag"=>"input","type"=>"hidden"},
   "button" => {"tag"=>"input","type"=>"button"},
   "submit" => {"tag"=>"input","type"=>"submit"},
   "checkbox" => {"tag"=>"input","type"=>"checkbox"},
   "radio" => {"tag"=>"input","type"=>"radio"},
  );

sub new {
  my ($pkg, %p) = @_;
  bless { title => 'Default title', %p }, $pkg;
}

our $AUTOLOAD;
sub AUTOLOAD {
  my $self = shift;
  my $m = $AUTOLOAD;
  $m =~ s/.*:://;
  $self->gentag($m, @_);
}

sub gentag {
  my $self = shift;
  my $tag = shift;
  my $content = (@_%2 == 1) ? pop @_ : undef;
  my %attr = @_;

  if (exists $metatags{$tag}) {
    my $orig_tag = $tag;
    foreach (keys %{$metatags{$tag}}) {
      $attr{$_} = $metatags{$tag}->{$_};
    }
    $tag = delete $attr{tag};
    if (exists $attr{'!append'}) {
      $content .= delete $attr{'!append'};
    }
  }
  my $nl = exists $newlinetags{$tag} ? "\n" : '';
  my $attribs = '';
  foreach (keys %attr) {
    my $v = $attr{$_} or next;
    $attribs .= ' '.$_.'="'.entities($v).'"';
  }
  if (defined $content) {
    if ($nl) {
      $content .= $nl unless ($content =~ /\n$/);
      $content = $nl.$content unless ($content =~ /^\n/);
    }
    return '<'.$tag.$attribs.'>'.$content.'</'.$tag.'>'.$nl;
  } else {
    return '<'.$tag.$attribs.'>'.$nl
  }
}

sub list {
  my ($self, $l) = @_;
  $self->ul(join '', map { $self->li($_) } @$l);
}

sub _header {
  my ($self) = @_;
  $self->{header}->($self, $self->{user});
}

sub _footer {
  my ($self) = @_;
  $self->{footer}->($self, $self->{user});
}

sub set_title {
  my ($self, $title) = @_;
  $self->{title} = $title;
}

sub entities {
  HTML::Entities::encode_entities(@_)
}

sub unentities {
  HTML::Entities::decode_entities(@_);
}

sub urlencode {
  URI::Escape::uri_escape(@_);
}

sub urldecode {
  URI::Escape::uri_unescape(@_);
}

sub page {
  my ($self, $content) = @_;
  "<!DOCTYPE html>\n".
    $self->html(
      $self->head(
        $self->title(entities($self->{title})).
        $self->meta(charset => 'utf8').
        $self->link(href => '/css/style.css?v=6', rel => 'stylesheet',
                    type => 'text/css').
        $self->link(href => '/images/favicon.png', rel => 'shortcut icon').
        $self->script(
          src => '//ajax.googleapis.com/ajax/libs/jquery/1.6.4/jquery.min.js',
          '').
        $self->script(src => '/js/app.js?v=6', '')
      ).$self->body(
                    $self->div(class => 'container',
                               $self->_header.
                               $self->div(id => "content", $content).
                               $self->_footer
                              )
                   )
    );
}

1;
