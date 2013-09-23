package Redis::Fast;

# ABSTRACT: Perl binding for Redis database
BEGIN {
    use XSLoader;
    our $VERSION = '0.01';
    XSLoader::load __PACKAGE__, $VERSION;
}

use warnings;
use strict;

use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Select;
use IO::Handle;
use Fcntl qw( O_NONBLOCK F_SETFL );
use Errno ();
use Data::Dumper;
use Carp qw/confess/;
use Encode;
use Try::Tiny;
use Scalar::Util ();

use constant WIN32       => $^O =~ /mswin32/i;
use constant EWOULDBLOCK => eval {Errno::EWOULDBLOCK} || -1E9;
use constant EAGAIN      => eval {Errno::EAGAIN} || -1E9;
use constant EINTR       => eval {Errno::EINTR} || -1E9;


sub new {
  my $class = shift;
  my %args  = @_;
  my $self  = $class->_new;

  #$self->{debug} = $args{debug} || $ENV{REDIS_DEBUG};

  ## default to lax utf8
  my $encoding = exists $args{encoding} ? $args{encoding} : 'utf8';
  if($encoding eq 'utf8') {
      $self->__set_utf8(1);
  } elsif(!$encoding) {
      $self->__set_utf8(0);
  } else {
      die "encoding $encoding does not support";
  }

  ## Deal with REDIS_SERVER ENV
  if ($ENV{REDIS_SERVER} && !$args{sock} && !$args{server}) {
    if ($ENV{REDIS_SERVER} =~ m!^/!) {
      $args{sock} = $ENV{REDIS_SERVER};
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^unix:(.+)!) {
      $args{sock} = $1;
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^(tcp:)?(.+)!) {
      $args{server} = $2;
    }
  }

  #$self->{password}   = $args{password}   if $args{password};
  #$self->{on_connect} = $args{on_connect} if $args{on_connect};

  #if (my $name = $args{name}) {
  #  my $on_conn = $self->{on_connect};
  #  $self->{on_connect} = sub {
  #    my ($redis) = @_;
  #    try {
  #      my $n = $name;
  #      $n = $n->($redis) if ref($n) eq 'CODE';
  #      $redis->client_setname($n) if defined $n;
  #    };
  #    $on_conn->(@_) if $on_conn;
  #    }
  #}

  if ($args{sock}) {
    $self->__connection_info_unix($args{sock});
  }
  else {
    my ($server, $port) = split /:/, ($args{server} || '127.0.0.1:6379');
    $self->__connection_info($server, $port);
  }

  #$self->{is_subscriber} = 0;
  #$self->{subscribers}   = {};
  $self->__set_reconnect($args{reconnect} || 0);
  $self->__set_every($args{every} || 1000);

  $self->__connect;

  return $self;
}

sub is_subscriber { }


### Deal with common, general case, Redis commands
our $AUTOLOAD;

sub AUTOLOAD {
  my $command = $AUTOLOAD;
  $command =~ s/.*://;

  my $method = sub {
      my $self = shift;
      my $ret;
      $ret = $self->__std_cmd($command, @_);
      return (wantarray && ref $ret eq 'ARRAY') ? @$ret : $ret;
  };

  # Save this method for future calls
  no strict 'refs';
  *$AUTOLOAD = $method;

  goto $method;
}

sub __with_reconnect {
  my ($self, $cb) = @_;

  ## Fast path, no reconnect
  return $cb->() unless $self->{reconnect};

  return &try(
    $cb,
    catch {
      die $_ unless ref($_) eq 'Redis::X::Reconnect';

      $self->__connect;
      $cb->();
    }
  );
}

sub __run_cmd {
  my ($self, $command, $collect_errors, $custom_decode, $cb, @args) = @_;

  my $ret;
  my $wrapper = $cb && $custom_decode
    ? sub {
    my ($reply, $error) = @_;
    $cb->(scalar $custom_decode->($reply), $error);
    }
    : $cb || sub {
    my ($reply, $error) = @_;
    confess "[$command] $error, " if defined $error;
    $ret = $reply;
    };

  $self->__send_command($command, @args);
  push @{ $self->{queue} }, [$command, $wrapper, $collect_errors];

  return 1 if $cb;

  $self->wait_all_responses;
  return
      $custom_decode ? $custom_decode->($ret, !wantarray)
    : wantarray && ref $ret eq 'ARRAY' ? @$ret
    :                                    $ret;
}


### Commands with extra logic

sub shutdown {
  my ($self) = @_;
  $self->__is_valid_command('SHUTDOWN');

  confess "[shutdown] only works in synchronous mode, "
    if @_ && ref $_[-1] eq 'CODE';

  return unless $self->{sock};

  $self->wait_all_responses;
  $self->__send_command('SHUTDOWN');
  close(delete $self->{sock}) || confess("Can't close socket: $!");

  return 1;
}


sub keys {
    my $self = shift;
    my $ret;
    $ret = $self->__keys(@_);
    return $ret unless ref $ret eq 'ARRAY';
    return @$ret;
}

### PubSub
sub wait_for_messages {
  my ($self, $timeout) = @_;
  my $sock = $self->{sock};

  my $s = IO::Select->new;
  $s->add($sock);

  my $count = 0;
MESSAGE:
  while ($s->can_read($timeout)) {
    while (1) {
      my $has_stuff = __try_read_sock($sock);
      last MESSAGE unless defined $has_stuff;    ## Stop right now if EOF
      last unless $has_stuff;                    ## back to select until timeout

      my ($reply, $error) = $self->__read_response('WAIT_FOR_MESSAGES');
      confess "[WAIT_FOR_MESSAGES] $error, " if defined $error;
      $self->__process_pubsub_msg($reply);
      $count++;
    }
  }

  return $count;
}

sub __subscription_cmd {
  my $self    = shift;
  my $pr      = shift;
  my $unsub   = shift;
  my $command = shift;
  my $cb      = pop;

  confess("Missing required callback in call to $command(), ")
    unless ref($cb) eq 'CODE';

  $self->wait_all_responses;

  my @subs = @_;
  $self->__with_reconnect(
    sub {
      $self->__throw_reconnect('Not connected to any server')
        unless $self->{sock};

      @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
        if $unsub;
      return unless @subs;

      $self->__send_command($command, @subs);

      my %cbs = map { ("${pr}message:$_" => $cb) } @subs;
      return $self->__process_subscription_changes($command, \%cbs);
    }
  );
}

sub subscribe    { shift->__subscription_cmd('',  0, subscribe    => @_) }
sub psubscribe   { shift->__subscription_cmd('p', 0, psubscribe   => @_) }
sub unsubscribe  { shift->__subscription_cmd('',  1, unsubscribe  => @_) }
sub punsubscribe { shift->__subscription_cmd('p', 1, punsubscribe => @_) }

sub __process_unsubscribe_requests {
  my ($self, $cb, $pr, @unsubs) = @_;
  my $subs = $self->{subscribers};

  my @subs_to_unsubscribe;
  for my $sub (@unsubs) {
    my $key = "${pr}message:$sub";
    my $cbs = $subs->{$key} = [grep { $_ ne $cb } @{ $subs->{$key} }];
    next if @$cbs;

    delete $subs->{$key};
    push @subs_to_unsubscribe, $sub;
  }

  return @subs_to_unsubscribe;
}

sub __process_subscription_changes {
  my ($self, $cmd, $expected) = @_;
  my $subs = $self->{subscribers};

  while (%$expected) {
    my ($m, $error) = $self->__read_response($cmd);
    confess "[$cmd] $error, " if defined $error;

    ## Deal with pending PUBLISH'ed messages
    if ($m->[0] =~ /^p?message$/) {
      $self->__process_pubsub_msg($m);
      next;
    }

    my ($key, $unsub) = $m->[0] =~ m/^(p)?(un)?subscribe$/;
    $key .= "message:$m->[1]";
    my $cb = delete $expected->{$key};

    push @{ $subs->{$key} }, $cb unless $unsub;

    $self->{is_subscriber} = $m->[2];
  }
}

sub __process_pubsub_msg {
  my ($self, $m) = @_;
  my $subs = $self->{subscribers};

  my $sub   = $m->[1];
  my $cbid  = "$m->[0]:$sub";
  my $data  = pop @$m;
  my $topic = $m->[2] || $sub;

  if (!exists $subs->{$cbid}) {
    warn "Message for topic '$topic' ($cbid) without expected callback, ";
    return;
  }

  $_->($data, $topic, $sub) for @{ $subs->{$cbid} };

  return 1;

}


### Mode validation
sub __is_valid_command {
  my ($self, $cmd) = @_;

#  confess("Cannot use command '$cmd' while in SUBSCRIBE mode, ")
#    if $self->{is_subscriber};
}


#
# The reason for this code:
#
# IO::Select and buffered reads like <$sock> and read() dont mix
# For example, if I receive two MESSAGE messages (from Redis PubSub),
# the first read for the first message will probably empty to socket
# buffer and move the data to the perl IO buffer.
#
# This means that IO::Select->can_read will return false (after all
# the socket buffer is empty) but from the application point of view
# there is still data to be read and process
#
# Hence this code. We try to do a non-blocking read() of 1 byte, and if
# we succeed, we put it back and signal "yes, Virginia, there is still
# stuff out there"
#
# We could just use sysread and leave the socket buffer with the second
# message, and then use IO::Select as intended, and previous versions of
# this code did that (check the git history for this file), but
# performance suffers, about 20/30% slower, mostly because we do a lot
# of "read one line", where <$sock> beats the crap of anything you can
# write on Perl-land.
#
sub __try_read_sock {
  my $sock = shift;
  my $data = '';

  __fh_nonblocking($sock, 1);

  ## Lots of problems with Windows here. This is a temporary fix until I
  ## figure out what is happening there. It looks like the wrong fix
  ## because we should not mix sysread (unbuffered I/O) with ungetc()
  ## below (buffered I/O), so I do expect to revert this soon.
  ## Call it a run through the CPAN Testers Gautlet fix. If I had to
  ## guess (and until my Windows box has a new power supply I do have to
  ## guess), I would say that the problems lies with the call
  ## __fh_nonblocking(), where on Windows we don't end up with a non-
  ## blocking socket.
  ## See
  ##  * https://github.com/melo/perl-redis/issues/20
  ##  * https://github.com/melo/perl-redis/pull/21
  my $len;
  if (WIN32) {
    $len = sysread($sock, $data, 1);
  }
  else {
    $len = read($sock, $data, 1);
  }
  my $err = 0 + $!;
  __fh_nonblocking($sock, 0);

  if (defined($len)) {
    ## Have stuff
    if ($len > 0) {
      $sock->ungetc(ord($data));
      return 1;
    }
    ## EOF according to the docs
    elsif ($len == 0) {
      return;
    }
    else {
      confess("read()/sysread() are really bonkers on $^O, return negative values ($len)");
    }
  }

  ## Keep going if nothing there, but socket is alive
  return 0 if $err and ($err == EWOULDBLOCK or $err == EAGAIN or $err == EINTR);

  ## No errno, but result is undef?? This happens sometimes on my tests
  ## when the server timesout the client. I traced the system calls and
  ## I see the read() system call return 0 for EOF, but on this side of
  ## perl, we get undef... We should see the 0 return code for EOF, I
  ## suspect the fact that we are in non-blocking mode is the culprit
  return if $err == 0;

  ## For everything else, there is Mastercard...
  confess("Unexpected error condition $err/$^O, please report this as a bug");
}


### Copied from AnyEvent::Util
BEGIN {
  *__fh_nonblocking = (WIN32)
    ? sub($$) { ioctl $_[0], 0x8004667e, pack "L", $_[1]; }    # FIONBIO
    : sub($$) { fcntl $_[0], F_SETFL, $_[1] ? O_NONBLOCK : 0; };
}


##########################
# I take exception to that

sub __throw_reconnect {
  my ($self, $m) = @_;
  die bless(\$m, 'Redis::X::Reconnect') if $self->{reconnect};
  die $m;
}


1;    # End of Redis.pm

__END__

=head1 AUTHOR

Dobrica Pavlinusic

Modified by Ichinose Shogo E<lt>shogo82148@gmail.comE<gt>

=head1 SYNOPSIS

    ## Defaults to $ENV{REDIS_SERVER} or 127.0.0.1:6379
    my $redis = Redis->new;

    my $redis = Redis->new(server => 'redis.example.com:8080');

    ## Set the connection name (requires Redis 2.6.9)
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => 'my_connection_name',
    );
    my $generation = 0;
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => sub { "cache-$$-".++$generation },
    );

    ## Use UNIX domain socket
    my $redis = Redis->new(sock => '/path/to/socket');

    ## Enable auto-reconnect
    ## Try to reconnect every 500ms up to 60 seconds until success
    ## Die if you can't after that
    my $redis = Redis->new(reconnect => 60);

    ## Try each 100ms upto 2 seconds (every is in milisecs)
    my $redis = Redis->new(reconnect => 2, every => 100);

    ## Disable the automatic utf8 encoding => much more performance
    ## !!!! This will be the default after 2.000, see ENCODING below
    my $redis = Redis->new(encoding => undef);

    ## Use all the regular Redis commands, they all accept a list of
    ## arguments
    ## See http://redis.io/commands for full list
    $redis->get('key');
    $redis->set('key' => 'value');
    $redis->sort('list', 'DESC');
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC});

    ## Add a coderef argument to run a command in the background
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC}, sub {
      my ($reply, $error) = @_;
      die "Oops, got an error: $error\n" if defined $error;
      print "$_\n" for @$reply;
    });
    long_computation();
    $redis->wait_all_responses;
    ## or
    $redis->wait_one_response();

    ## Or run a large batch of commands in a pipeline
    my %hash = _get_large_batch_of_commands();
    $redis->hset('h', $_, $hash{$_}, sub {}) for keys %hash;
    $redis->wait_all_responses;

    ## Publish/Subscribe
    $redis->subscribe(
      'topic_1',
      'topic_2',
      sub {
        my ($message, $topic, $subscribed_topic) = @_

          ## $subscribed_topic can be different from topic if
          ## you use psubscribe() with wildcards
      }
    );
    $redis->psubscribe('nasdaq.*', sub {...});

    ## Blocks and waits for messages, calls subscribe() callbacks
    ##  ... forever
    my $timeout = 10;
    $redis->wait_for_messages($timeout) while 1;

    ##  ... until some condition
    my $keep_going = 1; ## other code will set to false to quit
    $redis->wait_for_messages($timeout) while $keep_going;

    $redis->publish('topic_1', 'message');


=head1 DESCRIPTION

Pure perl bindings for L<http://redis.io/>

This version supports protocol 2.x (multi-bulk) or later of Redis available at
L<https://github.com/antirez/redis/>.

This documentation lists commands which are exercised in test suite, but
additional commands will work correctly since protocol specifies enough
information to support almost all commands with same piece of code with a
little help of C<AUTOLOAD>.


=head1 PIPELINING

Usually, running a command will wait for a response.  However, if you're doing
large numbers of requests, it can be more efficient to use what Redis calls
I<pipelining>: send multiple commands to Redis without waiting for a response,
then wait for the responses that come in.

To use pipelining, add a coderef argument as the last argument to a command
method call:

  $r->set('foo', 'bar', sub {});

Pending responses to pipelined commands are processed in a single batch, as
soon as at least one of the following conditions holds:

=over 4

=item *

A non-pipelined (synchronous) command is called on the same connection

=item *

A pub/sub subscription command (one of C<subscribe>, C<unsubscribe>,
C<psubscribe>, or C<punsubscribe>) is about to be called on the same
connection.

=item *

One of L</wait_all_responses> or L</wait_one_response> methods is called
explicitly.

=back

The coderef you supply to a pipelined command method is invoked once the
response is available.  It takes two arguments, C<$reply> and C<$error>.  If
C<$error> is defined, it contains the text of an error reply sent by the Redis
server.  Otherwise, C<$reply> is the non-error reply. For almost all commands,
that means it's C<undef>, or a defined but non-reference scalar, or an array
ref of any of those; but see L</keys>, L</info>, and L</exec>.

Note the contrast with synchronous commands, which throw an exception on
receipt of an error reply, or return a non-error reply directly.

The fact that pipelined commands never throw an exception can be particularly
useful for Redis transactions; see L</exec>.


=head1 ENCODING

B<This feature is deprecated and will be removed before 2.000>. You should
start testing your code with C<< encoding => undef >> because that will be the
new default with 2.000.

Since Redis knows nothing about encoding, we are forcing utf-8 flag on all data
received from Redis. This change was introduced in 1.2001 version. B<Please
note> that this encoding option severely degrades performance.

You can disable this automatic encoding by passing an option to L</new>: C<<
encoding => undef >>.

This allows us to round-trip utf-8 encoded characters correctly, but might be
problem if you push binary junk into Redis and expect to get it back without
utf-8 flag turned on.


=head1 METHODS

=head2 Constructors

=head3 new

    my $r = Redis->new; # $ENV{REDIS_SERVER} or 127.0.0.1:6379

    my $r = Redis->new( server => '192.168.0.1:6379', debug => 0 );
    my $r = Redis->new( server => '192.168.0.1:6379', encoding => undef );
    my $r = Redis->new( sock => '/path/to/sock' );
    my $r = Redis->new( reconnect => 60, every => 5000 );
    my $r = Redis->new( password => 'boo' );
    my $r = Redis->new( on_connect => sub { my ($redis) = @_; ... } );
    my $r = Redis->new( name => 'my_connection_name' );
    my $r = Redis->new( name => sub { "cache-for-$$" });

The C<< server >> parameter specifies the Redis server we should connect to,
via TCP. Use the 'IP:PORT' format. If no C<< server >> option is present, we
will attempt to use the C<< REDIS_SERVER >> environment variable. If neither of
those options are present, it defaults to '127.0.0.1:6379'.

Alternatively you can use the C<< sock >> parameter to specify the path of the
UNIX domain socket where the Redis server is listening.

The C<< REDIS_SERVER >> can be used for UNIX domain sockets too. The following
formats are supported:

=over 4

=item *

/path/to/sock

=item *

unix:/path/to/sock

=item *

127.0.0.1:11011

=item *

tcp:127.0.0.1:11011

=back

The C<< encoding >> parameter speficies the encoding we will use to decode all
the data we receive and encode all the data sent to the redis server. Due to
backwards-compatibility we default to C<< utf8 >>. To disable all this
encoding/decoding, you must use C<< encoding => undef >>. B<< This is the
recommended option >>.

B<< Warning >>: this option has several problems and it is B<deprecated>. A
future version might add other filtering options though.

The C<< reconnect >> option enables auto-reconnection mode. If we cannot
connect to the Redis server, or if a network write fails, we enter retry mode.
We will try a new connection every C<< every >> miliseconds (1000ms by
default), up-to C<< reconnect >> seconds.

Be aware that read errors will always thrown an exception, and will not trigger
a retry until the new command is sent.

If we cannot re-establish a connection after C<< reconnect >> seconds, an
exception will be thrown.

If your Redis server requires authentication, you can use the C<< password >>
attribute. After each established connection (at the start or when
reconnecting), the Redis C<< AUTH >> command will be send to the server. If the
password is wrong, an exception will be thrown and reconnect will be disabled.

You can also provide a code reference that will be immediatly after each
sucessfull connection. The C<< on_connect >> attribute is used to provide the
code reference, and it will be called with the first parameter being the Redis
object.

You can also set a name for each connection. This can be very useful for
debugging purposes, using the C<< CLIENT LIST >> command. To set a connection
name, use the C<< name >> parameter. You can use both a scalar value or a
CodeRef. If the latter, it will be called after each connection, with the Redis
object, and it should return the connection name to use. If it returns a
undefined value, Redis will not set the connection name.

Please note that there are restrictions on the name you can set, the most
important of which is, no spaces. See the L<CLIENT SETNAME
documentation|http://redis.io/commands/client-setname> for all the juicy
details. This feature is safe to use with all versions of Redis servers. If C<<
CLIENT SETNAME >> support is not available (Redis servers 2.6.9 and above
only), the name parameter is ignored.

The C<< debug >> parameter enables debug information to STDERR, including all
interactions with the server. You can also enable debug with the C<REDIS_DEBUG>
environment variable.


=head2 Connection Handling

=head3 quit

  $r->quit;

Closes the connection to the server. The C<quit> method does not support
pipelined operation.

=head3 ping

  $r->ping || die "no server?";

The C<ping> method does not support pipelined operation.

=head3 client_list

  @clients = $r->client_list;

Returns list of clients connected to the server. See L<< CLIENT LIST
documentation|http://redis.io/commands/client-list >> for a description of the
fields and their meaning.

=head3 client_getname

  my $connection_name = $r->client_getname;

Returns the name associated with this connection. See L</client_setname> or the
C<< name >> parameter to L</new> for ways to set this name.

=head3 client_setname

  $r->client_setname('my_connection_name');

Sets this connection name. See the L<CLIENT SETNAME
documentation|http://redis.io/commands/client-setname> for restrictions on the
connection name string. The most important one: no spaces.

=head2 Pipeline management

=head3 wait_all_responses

Waits until all pending pipelined responses have been received, and invokes the
pipeline callback for each one.  See L</PIPELINING>.

=head3 wait_one_response

Waits until the first pending pipelined response has been received, and invokes
its callback.  See L</PIPELINING>.


=head2 Transaction-handling commands

B<Warning:> the behaviour of these commands when combined with pipelining is
still under discussion, and you should B<NOT> use them at the same time just
now.

You can L<follow the discussion to see the open issues with
this|https://github.com/melo/perl-redis/issues/17>.

=head3 multi

  $r->multi;

=head3 discard

  $r->discard;

=head3 exec

  my @individual_replies = $r->exec;

C<exec> has special behaviour when run in a pipeline: the C<$reply> argument to
the pipeline callback is an array ref whose elements are themselves C<[$reply,
$error]> pairs.  This means that you can accurately detect errors yielded by
any command in the transaction, and without any exceptions being thrown.


=head2 Commands operating on string values

=head3 set

  $r->set( foo => 'bar' );

  $r->setnx( foo => 42 );

=head3 get

  my $value = $r->get( 'foo' );

=head3 mget

  my @values = $r->mget( 'foo', 'bar', 'baz' );

=head3 incr

  $r->incr('counter');

  $r->incrby('tripplets', 3);

=head3 decr

  $r->decr('counter');

  $r->decrby('tripplets', 3);

=head3 exists

  $r->exists( 'key' ) && print "got key!";

=head3 del

  $r->del( 'key' ) || warn "key doesn't exist";

=head3 type

  $r->type( 'key' ); # = string


=head2 Commands operating on the key space

=head3 keys

  my @keys = $r->keys( '*glob_pattern*' );
  my $keys = $r->keys( '*glob_pattern*' ); # count of matching keys

Note that synchronous C<keys> calls in a scalar context return the number of
matching keys (not an array ref of matching keys as you might expect).  This
does not apply in pipelined mode: assuming the server returns a list of keys,
as expected, it is always passed to the pipeline callback as an array ref.

=head3 randomkey

  my $key = $r->randomkey;

=head3 rename

  my $ok = $r->rename( 'old-key', 'new-key', $new );

=head3 dbsize

  my $nr_keys = $r->dbsize;


=head2 Commands operating on lists

See also L<Redis::List> for tie interface.

=head3 rpush

  $r->rpush( $key, $value );

=head3 lpush

  $r->lpush( $key, $value );

=head3 llen

  $r->llen( $key );

=head3 lrange

  my @list = $r->lrange( $key, $start, $end );

=head3 ltrim

  my $ok = $r->ltrim( $key, $start, $end );

=head3 lindex

  $r->lindex( $key, $index );

=head3 lset

  $r->lset( $key, $index, $value );

=head3 lrem

  my $modified_count = $r->lrem( $key, $count, $value );

=head3 lpop

  my $value = $r->lpop( $key );

=head3 rpop

  my $value = $r->rpop( $key );


=head2 Commands operating on sets

=head3 sadd

  my $ok = $r->sadd( $key, $member );

=head3 scard

  my $n_elements = $r->scard( $key );

=head3 sdiff

  my @elements = $r->sdiff( $key1, $key2, ... );
  my $elements = $r->sdiff( $key1, $key2, ... ); # ARRAY ref

=head3 sdiffstore

  my $ok = $r->sdiffstore( $dstkey, $key1, $key2, ... );

=head3 sinter

  my @elements = $r->sinter( $key1, $key2, ... );
  my $elements = $r->sinter( $key1, $key2, ... ); # ARRAY ref

=head3 sinterstore

  my $ok = $r->sinterstore( $dstkey, $key1, $key2, ... );

=head3 sismember

  my $bool = $r->sismember( $key, $member );

=head3 smembers

  my @elements = $r->smembers( $key );
  my $elements = $r->smembers( $key ); # ARRAY ref

=head3 smove

  my $ok = $r->smove( $srckey, $dstkey, $element );

=head3 spop

  my $element = $r->spop( $key );

=head3 spop

  my $element = $r->srandmember( $key );

=head3 srem

  $r->srem( $key, $member );

=head3 sunion

  my @elements = $r->sunion( $key1, $key2, ... );
  my $elements = $r->sunion( $key1, $key2, ... ); # ARRAY ref

=head3 sunionstore

  my $ok = $r->sunionstore( $dstkey, $key1, $key2, ... );

=head2 Commands operating on hashes

Hashes in Redis cannot be nested as in perl, if you want to store a nested
hash, you need to serialize the hash first. If you want to have a named
hash, you can use Redis-hashes. You will find an example in the tests
of this module t/01-basic.t

=head3 hset

Sets the value to a key in a hash.
  $r->hset('hashname', $key => $value); ## returns true on success


=head3 hget
  
Gets the value to a key in a hash.

  my $value = $r->hget('hashname', $key);

=head3 hexists
  
  if($r->hexists('hashname', $key) {
    ## do something, the key exists
  }
  else {
    ## the key does not exist
  }

=head3 hdel

Deletes a key from a hash
  if($r->hdel('hashname', $key)) {
    ## key is deleted
  }
  else {
    ## oops
  }

=head3 hincrby

Adds an integer to a value. The integer is signed, so a negative integer decrements.
  
  my $key = 'testkey';
  $r->hset('hashname', $key => 1); ## value -> 1
  my $increment = 1; ## has to be an integer
  $r->hincrby('hashname', $key => $increment); ## value -> 2
  $increment = 5;
  $r->hincrby('hashname', $key => $increment); ## value -> 7
  $increment = -1;
  $r->hincrby('hashname', $key => $increment); ## value -> 6

=head3 hsetnx

Adds a key to a hash unless it is not already set.

  my $key = 'testnx';
  $r->hsetnx('hashname', $key => 1); ## returns true
  $r->hsetnx('hashname', $key => 2); ## returns false because key already exists

=head3 hmset

Adds multiple keys to a hash.

  $r->hmset('hashname', 'key1' => 'value1', 'key2' => 'value2'); ## returns true on success


=head3 hmget

Returns multiple keys of a hash.

  my @values = $r->hmget('hashname', 'key1', 'key2');

=head3 hgetall

Returns the whole hash.

  my %hash = $r->hgetall('hashname');

=head3 hkeys

Returns the keys of a hash.

  my @keys = $r->hkeys('hashname');

=head3 hvals

Returns the values of a hash.

  my @values = $r->hvals('hashname');

=head3 hlen

Returns the count of keys in a hash.

  my $keycount = $r->hlen('hashname');



=head2 Sorting

=head3 sort

  $r->sort("key BY pattern LIMIT start end GET pattern ASC|DESC ALPHA');


=head2 Publish/Subscribe commands

When one of L</subscribe> or L</psubscribe> is used, the Redis object will
enter I<PubSub> mode. When in I<PubSub> mode only commands in this section,
plus L</quit>, will be accepted.

If you plan on using PubSub and other Redis functions, you should use two Redis
objects, one dedicated to PubSub and the other for regular commands.

All Pub/Sub commands receive a callback as the last parameter. This callback
receives three arguments:

=over 4

=item *

The published message.

=item *

The topic over which the message was sent.

=item *

The subscribed topic that matched the topic for the message. With L</subscribe>
these last two are the same, always. But with L</psubscribe>, this parameter
tells you the pattern that matched.

=back

See the L<Pub/Sub notes|http://redis.io/topics/pubsub> for more information
about the messages you will receive on your callbacks after each L</subscribe>,
L</unsubscribe>, L</psubscribe> and L</punsubscribe>.

=head3 publish

  $r->publish($topic, $message);

Publishes the C<< $message >> to the C<< $topic >>.

=head3 subscribe

  $r->subscribe(
      @topics_to_subscribe_to,
      sub {
        my ($message, $topic, $subscribed_topic) = @_;
        ...
      },
  );

Subscribe one or more topics. Messages published into one of them will be
received by Redis, and the specificed callback will be executed.

=head3 unsubscribe

  $r->unsubscribe(@topic_list, sub { my ($m, $t, $s) = @_; ... });

Stops receiving messages for all the topics in C<@topic_list>.

=head3 psubscribe

  my @topic_matches = ('prefix1.*', 'prefix2.*');
  $r->psubscribe(@topic_matches, sub { my ($m, $t, $s) = @_; ... });

Subscribes a pattern of topics. All messages to topics that match the pattern
will be delivered to the callback.

=head3 punsubscribe

  my @topic_matches = ('prefix1.*', 'prefix2.*');
  $r->punsubscribe(@topic_matches, sub { my ($m, $t, $s) = @_; ... });

Stops receiving messages for all the topics pattern matches in C<@topic_list>.

=head3 is_subscriber

  if ($r->is_subscriber) { say "We are in Pub/Sub mode!" }

Returns true if we are in I<Pub/Sub> mode.

=head3 wait_for_messages

  my $keep_going = 1; ## Set to false somewhere to leave the loop
  my $timeout = 5;
  $r->wait_for_messages($timeout) while $keep_going;

Blocks, waits for incoming messages and delivers them to the appropriate
callbacks.

Requires a single parameter, the number of seconds to wait for messages. Use 0
to wait for ever. If a positive non-zero value is used, it will return after
that ammount of seconds without a single notification.

Please note that the timeout is not a commitement to return control to the
caller at most each C<timeout> seconds, but more a idle timeout, were control
will return to the caller if Redis is idle (as in no messages were received
during the timeout period) for more than C<timeout> seconds.

The L</wait_for_messages> call returns the number of messages processed during
the run.


=head2 Persistence control commands

=head3 save

  $r->save;

=head3 bgsave

  $r->bgsave;

=head3 lastsave

  $r->lastsave;


=head2 Scripting commands

=head3 eval

  $r->eval($lua_script, $num_keys, $key1, ..., $arg1, $arg2);

Executes a Lua script server side.

Note that this commands sends the Lua script every time you call it. See
L</evalsha> and L</script_load> for an alternative.

=head3 evalsha

  $r->eval($lua_script_sha1, $num_keys, $key1, ..., $arg1, $arg2);

Executes a Lua script cached on the server side by its SHA1 digest.

See L</script_load>.

=head3 script_load

  my ($sha1) = $r->script_load($lua_script);

Cache Lua script, returns SHA1 digest that can be used with L</evalsha>.

=head3 script_exists

  my ($exists1, $exists2, ...) = $r->script_exists($scrip1_sha, $script2_sha, ...);

Given a list of SHA1 digests, returns a list of booleans, one for each SHA1,
that report the existence of each script in the server cache.

=head3 script_kill

  $r->script_kill;

Kills the currently running script.

=head3 script_flush

  $r->script_flush;

Flush the Lua scripts cache.


=head2 Remote server control commands

=head3 info

  my $info_hash = $r->info;

The C<info> method is unique in that it decodes the server's response into a
hashref, if possible. This decoding happens in both synchronous and pipelined
modes.

=head3 shutdown

  $r->shutdown;

The C<shutdown> method does not support pipelined operation.


=head2 Multiple databases handling commands

=head3 select

  $r->select( $dbindex ); # 0 for new clients

=head3 move

  $r->move( $key, $dbindex );

=head3 flushdb

  $r->flushdb;

=head3 flushall

  $r->flushall;


=head1 ACKNOWLEDGEMENTS

The following persons contributed to this project (alphabetical order):

=over 4

=item *

Aaron Crane (pipelining and AUTOLOAD caching support)

=item *

Dirk Vleugels

=item *

Flavio Poletti

=item *

Jeremy Zawodny

=item *

sunnavy at bestpractical.com

=item *

Thiago Berlitz Rondon

=item *

Ulrich Habel

=back

=cut
