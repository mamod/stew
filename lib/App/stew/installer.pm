package App::stew::installer;

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Carp qw(croak);
use File::Path qw(rmtree);
use File::Basename qw(basename dirname);
use App::stew::builder;
use App::stew::util
  qw(cmd info debug error _chdir _mkpath _rmtree _copy _unlink _tree _tree_diff);

sub new {
    my $class = shift;
    my (%params) = @_;

    my $self = {};
    bless $self, $class;

    $self->{root_dir}  = $params{root_dir};
    $self->{build_dir} = $params{build_dir};
    $self->{repo}      = $params{repo};
    $self->{snapshot}  = $params{snapshot};

    $self->{from_source} = $params{from_source};
    $self->{reinstall}   = $params{reinstall};

    return $self;
}

sub build {
    my $self = shift;
    my ($stew_tree, $mode) = @_;

    my $stew = $stew_tree->{stew};

    my $reinstall   = !$mode && $self->{reinstall};
    my $from_source = !$mode && $self->{from_source};

    if (!$reinstall && $self->{snapshot}->is_up_to_date($stew->name, $stew->version)) {
        info sprintf "'%s' is up to date", $stew->package;
        return;
    }

    croak '$ENV{PREFIX} not defined' unless $ENV{PREFIX};

    _mkpath($ENV{PREFIX});

    info sprintf "Building & installing '%s'...", $stew->package;

    my $work_dir = File::Spec->catfile($self->{build_dir}, $stew->package);
    _rmtree $work_dir;
    _mkpath($work_dir);

    my $cwd = getcwd();
    my $tree = [];
    eval {
        info sprintf "Resolving dependencies...", $stew->package;
        $self->_resolve_dependencies($stew, $stew_tree);

        if ($stew->is('cross-platform')) {
            info sprintf 'Cross platform package';

            my $builder = $self->_build_builder;

            $tree = $builder->build($stew_tree);

            my $dist_path = $self->{repo}->mirror_dist_dest($stew->name, $stew->version);

            my $dist_archive = basename $dist_path;
            my ($dist_name) = $dist_archive =~ m/^(.*)\.tar\.gz$/;

            _chdir $work_dir;
            _chdir "$dist_name/$ENV{PREFIX}";

            cmd("cp --remove-destination -ra * $ENV{PREFIX}/");
        }
        else {
            my $dist_path = $self->{repo}->mirror_dist_dest($stew->name, $stew->version);

            eval { $self->{repo}->mirror_dist($stew->name, $stew->version) };

            if ($from_source || !-f $dist_path) {
                my $builder = $self->_build_builder;

                $tree = $builder->build($stew_tree);
            }

            $self->_install_from_binary($stew, $dist_path);
        }

        _chdir($cwd);
    } or do {
        my $e = $@;

        _chdir($cwd);

        die $e;
    };

    info sprintf "Done installing '%s'", $stew->package;
    $self->{snapshot}->mark_installed($stew->name, $stew->version, $tree);

    return $self;
}

sub _install_from_binary {
    my $self = shift;
    my ($stew, $dist_path) = @_;

    info sprintf "Installing '%s' from binaries '%s'...", $stew->package, $dist_path;

    my $basename = basename $dist_path;

    my $work_dir = File::Spec->catfile($self->{build_dir}, $stew->package);
    _chdir $work_dir;

    my ($dist_name) = $basename =~ m/^(.*)\.tar\.gz$/;
    _rmtree $dist_name;
    _mkpath $dist_name;

    _copy($dist_path, "$dist_name/$basename");
    _chdir $dist_name;
    cmd("tar xzf $basename");
    _unlink $basename;

    cmd("cp --remove-destination -ra * $ENV{PREFIX}/");

    return _tree(".", ".");
}

sub _resolve_dependencies {
    my $self = shift;
    my ($stew, $tree) = @_;

    my @depends = @{$tree->{dependencies} || []};
    if (@depends) {
        info "Found dependencies: " . join(', ', map { $_->{stew}->package } @depends);
    }
    foreach my $tree (@depends) {
        my $stew = $tree->{stew};

        _chdir($self->{root_dir});

        $self->build($tree, 'dep');

        _chdir($self->{root_dir});
    }
}

sub _build_builder {
    my $self = shift;

    return App::stew::builder->new(
        root_dir  => $self->{root_dir},
        build_dir => $self->{build_dir},
        repo      => $self->{repo},
        snapshot  => $self->{snapshot},
    );
}

1;