package Thruk::Utils::Cluster;

=head1 NAME

Thruk::Utils::Cluster - Cluster Utilities Collection for Thruk

=head1 DESCRIPTION

Cluster Utilities Collection for Thruk

=cut

use strict;
use warnings;
use Thruk::Utils;
use Thruk::Backend::Provider::HTTP;
use Time::HiRes qw/gettimeofday tv_interval/;
use Digest::MD5 qw(md5_hex);
use Carp qw/confess/;

##########################################################

=head1 METHODS

=head2 new

create new cluster instance

=cut
sub new {
    my($class, $c, $nodes) = @_;
    $nodes = Thruk::Utils::list($nodes);
    my $self = {
         nodes      => $nodes,
        _nodes      => {},
        config      => $c->config,
        nodes_by_id => {},
        statefile   => $c->config->{'var_path'}.'/cluster/nodes',
    };
    bless $self, $class;

    for my $n (@{$nodes}) {
        $self->{'_nodes'}->{$n} = Thruk::Backend::Provider::HTTP->new({ peer => $n, auth => $c->config->{'secret_key'} }, undef, undef, undef, undef, $c->config);
    }

    return $self;
}

##########################################################

=head2 is_clustered

return 1 if a cluster is configured

=cut
sub is_clustered {
    my($self) = @_;
    return 0 if scalar @{$self->{'nodes'}} <= 1;
    return 1;
}

##########################################################

=head2 run_cluster

run something on our cluster

    - type: can be 'all' or the node url
    - sub: class / sub name
    - args: arguments

returns 0 if no cluster is in use and caller can continue locally
returns 1 if given sub will be started on given nodes

=cut
sub run_cluster {
    my($self, $type, $sub, $args) = @_;
    return 0 unless $self->is_clustered();
    return 0 if $ENV{'THRUK_SKIP_CLUSTER'};
    local $ENV{'THRUK_SKIP_CLUSTER'} = 1;

    my $nodes = [$type];
    if($type eq 'all') {
        $nodes = $self->{'nodes'};
    }

    if($type eq 'once') {
        return 0 unless $ENV{'THRUK_CRON'};
        confess("no args supported") if $args;
        # check if cmd is already running
        my $digest = md5_hex(sprintf("%s-%s", POSIX::strftime("%Y-%m-%d %H:%M", localtime()), $sub));
        my $jobs_path = $self->{'config'}->{'var_path'}.'/cluster/jobs';
        Thruk::Utils::IO::mkdir_r($jobs_path);
        Thruk::Utils::IO::write($jobs_path.'/'.$digest, $Thruk::NODE_ID."\n", undef, 1);
        my $lock = [split(/\n/mx, Thruk::Utils::IO::read($jobs_path.'/'.$digest))]->[0];
        if($lock ne $Thruk::NODE_ID) {
            print "uniq cluster job already started\n";
            return(1);
        }
        $self->_cleanup_jobs_folder();

        # continue and run on this node
        return(0);
    }

    # replace $c in args with placeholder
    if($args && ref $args eq 'ARRAY') {
        for(my $x = 0; $x <= scalar @{$args}; $x++) {
            # reverse function is in Thruk::Utils::CLI
            if(ref $args->[$x] eq 'Thruk::Context') {
                $args->[$x] = 'Thruk::Context';
            }
            if(ref $args->[$x] eq 'Thruk::Utils::Cluster') {
                $args->[$x] = 'Thruk::Utils::Cluster';
            }
        }
    }

    # expand nodeurls
    for my $n (@{$nodes}) {
        if(!$self->{'_nodes'}->{$n}) {
            my $node = $self->get_nodeurl_by_id($n);
            if($node) {
                $n = $node;
            }
        }
    }

    # if request contains only a single node and thats our own id, simply pass, no need to run that through extra web request
    if(scalar @{$nodes} == 1 && $nodes->[0] eq $self->get_nodeurl_by_id($Thruk::NODE_ID)) {
        return(0);
    }

    # run function on each cluster node
    # TODO: run in background or create queue to avoid delay on non-available nodes
    my $res = [];
    for my $n (@{$nodes}) {
        next unless $self->{'_nodes'}->{$n};
        push @{$res}, $self->{'_nodes'}->{$n}->_req($sub, $args);
    }

    return $res;
}

##########################################################

=head2 get_nodeurl_by_id

returns node for given id

=cut
sub get_nodeurl_by_id {
    my($self, $id) = @_;
    if($self->{'nodes_by_id'}->{$id}) {
        return($self->{'nodes_by_id'}->{$id});
    }
    if($self->{'_nodes'}->{$id}) {
        # is a nodeurl already
        return($id);
    }

    my $cache   = Thruk::Utils::IO::json_lock_retrieve($self->{'statefile'}) || {};
    my $changed = 0;
    for my $nodeurl (keys %{$cache}) {
        if(!$self->{'_nodes'}->{$nodeurl}) {
            $changed = 1;
            delete $cache->{$nodeurl};
        }
        $self->{'_nodes'}->{$nodeurl}->{'node_id'} = $cache->{$nodeurl}->{'id'};
        $self->{'nodes_by_id'}->{$cache->{$nodeurl}->{'id'}} = $nodeurl;
    }
    if($changed) {
        Thruk::Utils::IO::json_lock_store($self->{'statefile'}, $cache);
    }

    if($self->{'nodes_by_id'}->{$id}) {
        return($self->{'nodes_by_id'}->{$id});
    }

    # nothing found, ping all to update url <-> id relatation
    for my $nodeurl (@{$self->{'nodes'}}) {
        my $n = $self->{'_nodes'}->{$nodeurl};
        next unless $n;
        if(!$n->{'node_id'}) {
            $self->ping($nodeurl);
        }
    }

    return($self->{'nodes_by_id'}->{$id});
}

########################################

=head2 kill

  kill($c, $node, $signal, @pids)

cluster aware kill wrapper

=cut

sub kill {
    my($self, $c, $node, $sig, @pids) = @_;
    my $res = $self->run_cluster($node, "Thruk::Utils::Cluster::kill", [$self, $c, $node, $sig, @pids]);
    if(!$res) {
        return(CORE::kill($sig, @pids));
    }
    return(@{$res->[0]});
}

##########################################################

=head2 ping

request a ping from given cluster node

=cut
sub ping {
    my($self, $nodeurl) = @_;
    my $t0 = [gettimeofday];
    my $n   = $self->{'_nodes'}->{$nodeurl};
    my $res = $n->_req("Thruk::Utils::Cluster::pong");
    my $elapsed = tv_interval($t0);
    if(ref $res eq 'ARRAY' && $res->[0] && $res->[0]->{'instance'}) {
        if(!$n->{'node_id'} || $n->{'node_id'} ne $res->[0]->{'instance'}) {
            $n->{'node_id'} = $res->[0]->{'instance'};
            my $cache = Thruk::Utils::IO::json_lock_retrieve($self->{'statefile'}) || {};
            $cache->{$nodeurl}->{'id'}           = $n->{'node_id'};
            $cache->{$nodeurl}->{'last_contact'} = time();
            Thruk::Utils::IO::json_lock_store($self->{'statefile'}, $cache);
        }
    }
    return(1, $elapsed, (ref $res eq 'ARRAY' ? $res->[0] : undef));
}

##########################################################

=head2 pong

answer a ping request

=cut
sub pong {
    return({
        time     => time(),
        instance => $Thruk::NODE_ID,
    });
}

##############################################
sub _cleanup_jobs_folder {
    my($self) = @_;
    my $keep = time() - 600;
    my $jobs_path = $self->{'config'}->{'var_path'}.'/cluster/jobs';
    for my $file (glob($jobs_path.'/*')) {
        my @stat = stat($file);
        if($stat[9] && $stat[9] < $keep) {
            unlink($file);
        }
    }
    return;
}

##############################################

1;

__END__

=head1 AUTHOR

Sven Nierlein, 2009-present, <sven@nierlein.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
