# Copyright (C) 2006, David Muir Sharnoff <muir@idiom.com>

package Plugins;

use strict;
use warnings;
use UNIVERSAL qw(can);
use Carp;
our $VERSION = 0.3;
our $debug = 0;

sub new
{
	my ($pkg, %args) = @_;

	my $context = $args{context} || {};
	my $pkg_override = $context->{pkg_override} || '';

	if ($pkg_override ne __PACKAGE__ 
		and scalar(caller()) ne $pkg_override
		and can($pkg_override, 'new')
		and can($pkg_override, 'new') ne \&new)
	{
		my $new = can($pkg_override, 'new');
		croak "no new in $pkg_override" unless $new;
		@_ = ($pkg_override, %args);
		goto &$new;  # so caller() works
	}

	my $self = bless {
		%args,
		list			=> undef,
		new_list		=> undef,
		plugins			=> {},
		new_config		=> undef,
		config			=> {},
		configfile		=> $args{configfile} || $context->{configfile},
		context			=> $context,
		requestor		=> $args{requestor} || scalar(caller()),
		api			=> $args{api},
	}, $pkg;

	return $self;
}

sub startconfig
{
	my ($self) = @_;

	$self->{new_list} = [];
	$self->{new_config} = {};
}

sub readconfig
{
	my ($self, $configfile, %args) = @_;

	croak "only one call to readconfig() before initialize()" if $self->{new_list};

	$self->startconfig();
	$args{self} ||= scalar(caller());
	$self->parseconfig($configfile, %args);
}

sub parseconfig { croak "Plugins must be subclassed and the subclass must define a parseconfig() method"; };

our %required;

sub pkg_invoke
{
	my ($self, $pkg, $method, @args) = @_;
	unless ($required{$pkg}++) {
		my $p = $pkg;
		$p =~ s!::!/!g;
		eval { require "$p.pm" };
		die "require $p: $@" if $@;
	}
	return undef unless $method;
	my $f = can($pkg, $method);
	return undef unless $f;
	return &$f(@args);
}

sub genkey
{
	my ($self, $context) = @_;
	my $key = "$context->{pkg}/$context->{configfile}";
	return $key;
}

sub registerplugin
{
	my ($self, %context) = @_;
	my $pkg = $context{pkg};
	{ 
		no strict qw(refs);
		$self->pkg_invoke($pkg)
			unless %{"${pkg}::"};
	}
	my $key = $self->genkey(\%context);
	$context{requestor} = $self->{requestor} unless $context{requestor};
	croak "Duplicate registration of $pkg plugin at $context{file}:$context{lineno} and $self->{new_config}{$key}{file}:$self->{new_config}{$key}{lineno}\n"
		if $self->{new_config}{$key};
	$self->{new_config}{$key} = \%context;
	push(@{$self->{new_list}}, $key);
	return \%context;
}

sub initialize
{
	my ($self, %args) = @_;

	confess "readconfig() not called yet" unless defined $self->{new_list};

	if ($self->{list}) {
		my @shutargs;
		@shutargs = @{$args{shutdown_args}} if $args{shutdown_args};
		for my $old (@{$self->{list}}) {
			$self->{plugins}{$old}->shutdown();
			delete $self->{plugins}{$old};
		}
	}

	$self->{config} = $self->{new_config};
	$self->{new_config} = undef;
	$self->{list} = $self->{new_list};
	$self->{new_list} = undef;

	for my $key (@{$self->{list}}) {
		$self->{plugins}{$key} = $self->initialize_plugin($self->{config}{$key});
	}
}

sub post_initialize { }

sub api
{
	my ($self, $new) = @_;
	my $old = $self->{api};
	$self->{api} = $new if @_ > 1;
	return $old;
}

sub initialize_plugin
{
	my ($self, $context) = @_;
	my $pkg = $context->{pkg};
	$context->{pkg_override} = ref($self)
		unless $context->{pkg_override};
	my $new = can($pkg, 'new')
		or confess "no new() method for $pkg.  \@ISA for $pkg should include Plugins::Plugin";
	my $p = &$new($pkg, { context => $context, api => $self->{api} }, @{$context->{new_args}})
		or confess "$pkg->new() returned false";
	$self->post_initialize($context, $p);
	return $p;
}

sub addplugin
{
	my ($self, %context) = @_;
	my $pkg = $context{pkg};
	{ 
		no strict qw(refs);
		$self->pkg_invoke($pkg)
			unless %{"${pkg}::"};
	}
	my $key = $self->genkey(\%context);
	if ($self->{plugins}{$key}) {
		$self->{plugins}{$key}->shutdown();
	} else {
		push(@{$self->{list}}, $key);
	}
	$context{requestor} = $self->{requestor} unless $context{requestor};
	$self->{config}{$key} = \%context;
	$self->{plugins}{$key} = $self->initialize_plugin(\%context);
}

sub invoke
{
	my ($self, $method, @args) = @_;
	confess "readconfig() not called yet" unless defined $self->{list};
	confess if $method =~ /::/;
	for my $pkg (@{$self->{list}}) {
		my $plugin = $self->{plugins}{$pkg};
		$plugin->invoke($method, @args);
	}
}

sub invoke_until
{
	my ($self, $method, $satisfied, @args) = @_;
	confess "readconfig() not called yet" unless defined $self->{list};
	for my $plugin ($self->plugins) {
		my @r;
		my $m = $plugin->can($method);
		my $pkg = ref($plugin);
		print STDERR "invoke_until $method on $pkg...\n" if $debug;
		next unless $m;
		if (wantarray) {
			@r = eval { &$m($plugin, @args); };
		} else {
			$r[0] = eval { &$m($plugin, @args); };
		}
		print STDERR " results = @r\n" if $debug;
		warn $@ if $@;
		if (&$satisfied(@r)) {
			print STDERR " satisfied!\n" if $debug;
			return @r if wantarray;
			return $r[0];
		}
		print STDERR " NOT satisfied!\n" if $debug;
	}
	return () if wantarray;
	return undef;
}


sub plugins
{
	my ($self) = @_;
	confess "readconfig() not called yet" unless defined $self->{list};
	return map { $self->{plugins}{$_} } @{$self->{list}};
}

sub iterator
{
	my ($self, $method) = @_;
	confess "readconfig() not called yet" unless defined $self->{list};
	my @plugins = @{$self->{list}};
	return sub {
		for (;;) {
			return () unless @plugins;
			my $plugin = shift(@plugins);
			my $f = $self->{plugins}{$plugin}->can($method);
			next unless $f;
			return &$f($self->{plugins}{$plugin}, @_);
		}
	}
}


package Plugins::Plugin;

use strict;
use warnings;
use Carp qw(cluck confess);

our $AUTOLOAD;

sub DESTROY {}
sub shutdown {}

sub invoke
{
	my ($self, $method, @args) = @_;
	if ($Plugins::debug) {
		my $pkg = ref($self);
		print STDERR "Invoking $method on $pkg\n";
	}
	confess if $method =~ /::/;
	my $m = $self->can($method);
	return undef unless $m;
	&$m($self, @args);
}

sub new
{
	my ($pkg, $pconfig,  %args) = @_;
	return bless { context => $pconfig->{context}, api => $pconfig->{api}, config => \%args }, $pkg;
}

sub AUTOLOAD
{
	my $self = shift;

	my $auto = $AUTOLOAD;
	my $ref = ref($self);
	my $p = __PACKAGE__;
	$auto =~ s/^${ref}::// or $auto =~ s/^${p}:://;
	return $self->{myapi}->invoke($auto, @_)
		if $self->{myapi};
	return $self->{api}->invoke($auto, @_)
		if $self->{api};
	cluck "No method '$auto'";
}

1;
