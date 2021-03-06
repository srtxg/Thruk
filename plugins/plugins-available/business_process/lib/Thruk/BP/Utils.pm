package Thruk::BP::Utils;

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use File::Temp qw/tempfile/;
use File::Copy qw/move/;
use File::Slurp qw/read_file/;
use Carp;

use Thruk::BP::Components::BP;

=head1 NAME

Thruk::BP::Utils - Helper for the business process addon

=head1 DESCRIPTION

Helper for the business process addon

=head1 METHODS

=cut

##########################################################

=head2 load_bp_data

    load_bp_data($c, [$num], [$editmode], [$drafts])

editmode:
    - 0/undef:    no edit mode
    - 1:          only edit mode

drafts:
    - 0/undef:    skip drafts
    - 1:          load drafts too

load all or specific business process

=cut
sub load_bp_data {
    my($c, $num, $editmode, $drafts) = @_;

    # make sure our folders exist
    my $base_folder = bp_base_folder($c);
    Thruk::Utils::IO::mkdir_r($c->config->{'var_path'}.'/bp');
    Thruk::Utils::IO::mkdir_r($base_folder);

    my $bps   = [];
    my $pattern = '*.tbp';
    if($num) {
        return($bps) unless $num =~ m/^\d+$/mx;
        $pattern = $num.'.tbp';
    }
    my $numbers = {};
    my @files   = glob($base_folder.'/'.$pattern);
    for my $file (@files) {
        my $bp = Thruk::BP::Components::BP->new($c, $file, undef, $editmode);
        if($bp) {
            push @{$bps}, $bp;
            $numbers->{$bp->{'id'}} = 1;
        }
    }
    if($drafts) {
        # load drafts too
        my @files = glob($c->config->{'var_path'}.'/bp/*.tbp.edit');
        for my $file (@files) {
            my $nr = $file;
            $nr =~ s|^.*/(\d+)\.tbp\.edit$|$1|mx;
            next if $numbers->{$nr};
            $file  = $base_folder.'/'.$nr.'.tbp';
            my $bp = Thruk::BP::Components::BP->new($c, $file, undef, 1);
            if($bp) {
                push @{$bps}, $bp;
                $numbers->{$bp->{'id'}} = 1;
            }
        }
    }

    # sort by name
    @{$bps} = sort { $a->{'name'} cmp $b->{'name'} } @{$bps};

    return($bps);
}

##########################################################

=head2 next_free_bp_file

    next_free_bp_file($c)

return next free bp file

=cut
sub next_free_bp_file {
    my($c) = @_;
    my $num = 1;
    my $base_folder = bp_base_folder($c);
    Thruk::Utils::IO::mkdir_r($c->config->{'var_path'}.'/bp');
    Thruk::Utils::IO::mkdir_r($base_folder);
    while(-e $base_folder.'/'.$num.'.tbp' || -e $c->config->{'var_path'}.'/bp/'.$num.'.tbp.edit') {
        $num++;
    }
    return($base_folder.'/'.$num.'.tbp', $num);
}

##########################################################

=head2 make_uniq_label

    make_uniq_label($c, $label, $bp_id)

returns new uniq label

=cut
sub make_uniq_label {
    my($c, $label, $bp_id) = @_;

    # gather names of all BPs and editBPs
    my $names = {};
    my @files = glob(bp_base_folder($c).'/*.tbp '.$c->config->{'var_path'}.'/bp/*.tbp.edit');
    for my $file (@files) {
        next if $bp_id and $file =~ m#/$bp_id\.tbp(.edit|)$#mx;
        my $data = Thruk::Utils::IO::json_lock_retrieve($file);
        $names->{$data->{'name'}} = 1;
    }

    my $num = 2;
    my $testlabel = $label;
    while(defined $names->{$testlabel}) {
        $testlabel = $label.' '.$num++;
    }

    return $testlabel;
}

##########################################################

=head2 update_bp_status

    update_bp_status($c, $bps)

update status of all given business processes

=cut
sub update_bp_status {
    my($c, $bps) = @_;
    for my $bp (@{$bps}) {
        $bp->update_status($c);
    }
    return;
}

##########################################################

=head2 save_bp_objects

    save_bp_objects($c, $bps)

save business processes objects to object file

=cut
sub save_bp_objects {
    my($c, $bps) = @_;

    my $file   = $c->config->{'Thruk::Plugin::BP'}->{'objects_save_file'};
    my $format = $c->config->{'Thruk::Plugin::BP'}->{'objects_save_format'} || 'nagios';
    if($format ne 'icinga2') { $format = 'nagios'; }
    return(0, 'no \'objects_save_file\' set') unless $file;

    my($rc, $msg) = (0, 'reload ok');
    my $obj = {'hosts' => {}, 'services' => {}};
    for my $bp (@{$bps}) {
        my $data = $bp->get_objects_conf();
        merge_obj_hash($obj, $data);
    }

    my($fh, $filename) = tempfile();
    binmode($fh, ":encoding(UTF-8)");
    print $fh "########################\n";
    print $fh "# thruk: readonly\n";
    print $fh "# don't change, file is generated by thruk and will be overwritten.\n";
    print $fh "########################\n\n\n";
    if($format eq 'nagios') {
        print $fh _get_nagios_objects($c, $obj);
    }
    elsif($format eq 'icinga2') {
        print $fh _get_icinga2_objects($c, $obj);
    }

    Thruk::Utils::IO::close($fh, $filename);

    my $new_hex = md5_hex(scalar read_file($filename));
    my $old_hex = -f $file ? md5_hex(scalar read_file($file)) : '';

    # check if something changed
    if($new_hex ne $old_hex) {
        if(!move($filename, $file)) {
            return(1, 'move '.$filename.' to '.$file.' failed: '.$!);
        }
        my $result_backend = $c->config->{'Thruk::Plugin::BP'}->{'result_backend'};
        if(!$result_backend && $Thruk::Backend::Pool::peer_order && scalar @{$Thruk::Backend::Pool::peer_order}) {
            my $peer_key = $Thruk::Backend::Pool::peer_order->[0];
            $result_backend = $c->{'db'}->get_peer_by_key($peer_key)->peer_name;
        }
        # and reload
        my $time = time();
        my $pkey;
        my $cmd = $c->config->{'Thruk::Plugin::BP'}->{'objects_reload_cmd'};
        my $reloaded = 0;
        if($cmd) {
            ($rc, $msg) = Thruk::Utils::IO::cmd($c, $cmd." 2>&1");
            $reloaded = 1;
        }
        elsif($result_backend) {
            # restart by livestatus
            my $peer = $c->{'db'}->get_peer_by_key($result_backend);
            die("no backend found by name ".$result_backend) unless $peer;
            $pkey = $peer->peer_key();
            my $options = {
                'command' => sprintf("COMMAND [%d] RESTART_PROCESS", time()),
                'backend' => [ $pkey ],
            };
            $c->{'db'}->send_command( %{$options} );
            ($rc, $msg) = (0, 'business process saved and core restarted');
            $reloaded = 1;
        }
        if($rc == 0 && $reloaded) {
            my $core_reloaded = Thruk::Utils::wait_after_reload($c, $pkey, $time-1);
            if(!$core_reloaded) {
                ($rc, $msg) = (1, 'business process saved but core failed to restart');
            }
        }
    } else {
        # discard file
        unlink($filename);
    }

    return($rc, $msg);
}

##########################################################

=head2 clean_function_args

    clean_function_args($args)

return clean args from a string

=cut
sub clean_function_args {
    my($args) = @_;
    return([]) unless defined $args;
    my @newargs = $args =~ m/('.*?'|".*?"|\d+)/gmx;
    for my $arg (@newargs) {
        $arg =~ s/^'(.*)'$/$1/mx;
        $arg =~ s/^"(.*)"$/$1/mx;
        if($arg =~ m/^(\d+|\d+.\d+)$/mx) {
            $arg = $arg + 0; # make it a real number
        }
    }
    return(\@newargs);
}

##########################################################

=head2 clean_orphaned_edit_files

  clean_orphaned_edit_files($c, [$threshold])

remove old edit files

=cut
sub clean_orphaned_edit_files {
    my($c, $threshold) = @_;
    $threshold = 86400 unless defined $threshold;
    my $base_folder = bp_base_folder($c);
    for my $pattern (qw/edit runtime/) {
    my @files = glob($c->config->{'var_path'}.'/bp/*.tbp.'.$pattern);
        for my $file (@files) {
            $file =~ m/\/(\d+)\.tbp\.$pattern/mx;
            if($1 && !-e $base_folder.'/'.$1.'.tbp') {
                my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($file);
                next if $mtime > (time() - $threshold);
                unlink($file);
            }
        }
    }
    return;
}

##########################################################

=head2 update_cron_file

  update_cron_file($c)

update reporting cronjobs

=cut
sub update_cron_file {
    my($c) = @_;

    my $rate = int($c->config->{'Thruk::Plugin::BP'}->{'refresh_interval'} || 1);
    if($rate <  1) { $rate =  1; }
    if($rate > 60) { $rate = 60; }

    # gather reporting send types from all reports
    my $cron_entries = [];
    my @files = glob(bp_base_folder($c).'/*.tbp');
    if(scalar @files > 0) {
        open(my $fh, '>>', $c->config->{'var_path'}.'/cron.log');
        Thruk::Utils::IO::close($fh, $c->config->{'var_path'}.'/cron.log');
        my $cmd = sprintf("cd %s && %s '%s bp all' >/dev/null 2>>%s/cron.log",
                                $c->config->{'project_root'},
                                $c->config->{'thruk_shell'},
                                $c->config->{'thruk_bin'},
                                $c->config->{'var_path'},
                        );
        push @{$cron_entries}, ['* * * * *', $cmd] if $rate == 1;
        push @{$cron_entries}, ['*/'.$rate.' * * * *', $cmd] if $rate != 1;
    }

    Thruk::Utils::update_cron_file($c, 'business process', $cron_entries);
    return 1;
}

##########################################################

=head2 get_custom_functions

  get_custom_functions($c)

returns list of custom functions

=cut
sub get_custom_functions {
    my($c) = @_;

    # get required files
    my $functions = [];
    my @files = glob(bp_base_folder($c).'/*.pm');
    for my $filename (@files) {
        next unless -s $filename;
        my $f = _parse_custom_functions($filename, 'function$');
        push @{$functions}, @{$f};
    }
    return $functions;
}

##########################################################

=head2 get_custom_filter

  get_custom_filter($c)

returns list of custom filter

=cut
sub get_custom_filter {
    my($c) = @_;

    # get required files
    my $functions = [];
    my @files = glob(bp_base_folder($c).'/*.pm');
    for my $filename (@files) {
        next unless -s $filename;
        my $f = _parse_custom_functions($filename, 'filter$');
        push @{$functions}, @{$f};
    }

    # sort by name
    @{$functions} = sort { $a->{'name'} cmp $b->{'name'} } @{$functions};

    return $functions;
}

##########################################################
sub _parse_custom_functions {
    my($filename, $filter) = @_;

    my $functions = [];
    my $last_help = "";
    my $last_args = [];

    open(my $fh, '<', $filename);
    while(my $line = <$fh>) {
        if($line =~ m/^\s*sub\s+([\w_]+)(\s|\{)/mx) {
            my $func = $1;
            my $name = $func;
            $last_help =~ s/^(Input|Output):\s(.*?):?$//mx;
            if($2) {
                $name = $1.": ". $2;
            }
            $name =~ s/:?\s*$//gmx;
            $last_help =~ s/^Arguments:\s$//mx;
            $last_help =~ s/\A\s*//msx;
            $last_help =~ s/\s*\Z//msx;
            if(!$filter || $func =~ m/$filter/mx) {
                push @{$functions}, { function => $func, help => $last_help, file => $filename, args => $last_args, name => $name };
            }
            $last_help = "";
            $last_args = [];
        }
        elsif($line =~ m/^\s*\#\s*arg\d+:\s*(.*)/mx) {
            my($name, $type, $args) = split(/\s*;\s*/mx,$1,3);
            if($type eq 'checkbox' or $type eq 'select') { $args = [split(/\s*;\s*/mx,$args)]; }
            push @{$last_args}, {name => $name, type => $type, args => $args};
        }
        elsif($line =~ m/^\s*\#\ ?(.*?$)/mx) {
            $last_help .= $1."\n";
        }
        elsif($line =~ m/^\s*$/mx) {
            $last_help = "";
            $last_args = [];
        }
    }
    CORE::close($fh);

    return $functions;
}

##########################################################

=head2 join_labels

    join_labels($nodes)

return string with joined labels

=cut
sub join_labels {
    my($nodes) = @_;
    my @labels;
    for my $n (@{$nodes}) {
        push @labels, $n->{'label'};
    }
    my $num = scalar @labels;
    if($num == 0) {
        return('');
    }
    if($num == 1) {
        return($labels[0]);
    }
    if($num == 2) {
        return($labels[0].' and '.$labels[1]);
    }
    my $last = pop @labels;
    return(join(', ', @labels).' and '.$last);
}

##########################################################

=head2 join_args

    join_args($args)

return string with joined args

=cut
sub join_args {
    my($args) = @_;
    my @arg;
    for my $e (@{$args}) {
        $e = '' unless defined $e;
        if($e =~ m/^(\d+|\d+\.\d+)$/mx) {
            push @arg, $e;
        } else {
            push @arg, "'".$e."'";
        }
    }
    return(join(', ', @arg));
}

##########################################################

=head2 state2text

    status2text($state)

return string of given state

=cut
sub state2text {
    my($nr) = @_;
    if($nr == 0) { return 'OK'; }
    if($nr == 1) { return 'WARNING'; }
    if($nr == 2) { return 'CRITICAL'; }
    if($nr == 3) { return 'UNKOWN'; }
    if($nr == 4) { return 'PENDING'; }
    return;
}

##########################################################

=head2 merge_obj_hash

    merge_obj_hash($hash, $data)

merge objects hash with more objects

=cut
sub merge_obj_hash {
    my($hash, $data) = @_;

    if(defined $data->{'hosts'}) {
        for my $hostname (keys %{$data->{'hosts'}}) {
            my $host = $data->{'hosts'}->{$hostname};
            $hash->{'hosts'}->{$hostname} = $host;
        }
    }

    if(defined $data->{'services'}) {
        for my $hostname (keys %{$data->{'services'}}) {
            for my $description (keys %{$data->{'services'}->{$hostname}}) {
                my $service = $data->{'services'}->{$hostname}->{$description};
                $hash->{'services'}->{$hostname}->{$description} = $service;
            }
        }
    }
    return($hash);
}

##########################################################

=head2 clean_nasty

    clean_nasty($string)

clean nasty chars from string

=cut
sub clean_nasty {
    my($str) = @_;
    confess("nothing?") unless defined $str;
    $str =~ s#[`~!\$%^&*\|'"<>\?,\(\)=]*##gmxo;
    return($str);
}

##########################################################

=head2 bp_base_folder

    bp_base_folder($c)

return base folder of business process files

=cut
sub bp_base_folder {
    my($c) = @_;
    return(Thruk::Utils::base_folder($c).'/bp');
}

##########################################################

=head2 looks_like_regex

    looks_like_regex($str)

returns true if $string looks like a regular expression

=cut
sub looks_like_regex {
    my($str) = @_;
    if($str =~ m%[\^\|\*\{\}\[\]]%gmx) {
        return(1);
    }
    return;
}

##########################################################
# return objects in nagios format
sub _get_nagios_objects {
    my($c, $obj) = @_;

    my $str = "";
    for my $hostname (sort keys %{$obj->{'hosts'}}) {
        $str .= 'define host {'. "\n";
        my $keys = _get_sorted_keys([keys %{$obj->{'hosts'}->{$hostname}}]);
        for my $attr (@{$keys}) {
            $str .= ' '. $attr. ' '. $obj->{'hosts'}->{$hostname}->{$attr}. "\n";
        }
        $str .= "}\n";
    }
    for my $hostname (sort keys %{$obj->{'services'}}) {
        for my $description (sort keys %{$obj->{'services'}->{$hostname}}) {
            $str .= 'define service {'. "\n";
            my $keys = _get_sorted_keys([keys %{$obj->{'services'}->{$hostname}->{$description}}]);
            for my $attr (@{$keys}) {
                $str .= ' '. $attr. ' '. $obj->{'services'}->{$hostname}->{$description}->{$attr}. "\n"
            }
            $str .= "}\n";
        }
    }

    return($str);
}

##########################################################
# return objects in icinga2 format
sub _get_icinga2_objects {
    my($c, $obj) = @_;

    my $str = "";
    for my $hostname (sort keys %{$obj->{'hosts'}}) {
        $str .= 'object Host "'.$hostname.'" {'. "\n";
        my $keys = _get_sorted_keys([keys %{$obj->{'hosts'}->{$hostname}}]);
        for my $attr (@{$keys}) {
            next if $attr eq 'host_name';
            next if $attr eq 'alias';
            $str .= _get_icinga2_object_attr('host', $attr, $obj->{'hosts'}->{$hostname}->{$attr});
        }
        $str .= "}\n";
    }
    for my $hostname (sort keys %{$obj->{'services'}}) {
        for my $description (sort keys %{$obj->{'services'}->{$hostname}}) {
            $str .= 'object Service "'.$description.'" {'. "\n";
            my $keys = _get_sorted_keys([keys %{$obj->{'services'}->{$hostname}->{$description}}]);
            for my $attr (@{$keys}) {
                next if $attr eq 'service_description';
                next if $attr eq 'alias';
                $str .= _get_icinga2_object_attr('service', $attr, $obj->{'services'}->{$hostname}->{$description}->{$attr});
            }
            $str .= "}\n";
        }
    }

    return($str);
}

##########################################################
sub _get_icinga2_object_attr {
    my($type, $attr, $val) = @_;
    my $key = $attr;
    if($attr =~ m/^_(.*)$/mx) {
        $key = 'vars.'.$1;
    }
    if($attr eq 'use') {
        my @templates = split(/\s*,\s*/mx, $val);
        my $str = "";
        for my $tpl (@templates) {
            $str .= ' import "'.$tpl. "\"\n";
        }
        return($str);
    }
    if($attr =~ m/_interval$/mx) {
        $val = $val.'m';
    }
    return(' '. $key. ' = "'.$val. "\"\n");

}

##########################################################
sub _get_sorted_keys {
    my($keys) = @_;
    eval {
        require Monitoring::Config::Object::Parent;
        require Monitoring::Config;
        Monitoring::Config::set_save_config();
        my @keys = @{Monitoring::Config::Object::Parent::get_sorted_keys(undef, $keys)};
        $keys = \@keys;
    };
    if($@) {
        # do a normal alphanumeric sort otherwise
        $keys = [sort @{$keys}];
    }
    return $keys;
}

##########################################################

=head1 AUTHOR

Sven Nierlein, 2009-present, <sven@nierlein.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
