# Copyright (C) 2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

package OpenQA::File;
use Mojo::Base 'Mojolicious::Controller';
BEGIN { $ENV{MAGICK_THREAD_LIMIT}=1; }
use openqa;
use File::Basename;

use Data::Dump qw(pp);

use Mojolicious::Static;

sub needle {
    my $self = shift;

    my $name = $self->param('name');
    my $distri = $self->param('distri');
    my $version = $self->param('version') || '';
    my $needle = openqa::needle_info($name, $distri, $version);
    return $self->render_not_found unless $needle;

    $self->{static} = Mojolicious::Static->new;
    # needledir is an absolute path from the needle database
    push @{$self->{static}->paths}, $needle->{needledir};

    # name is an URL parameter and can't contain slashes, so it should be safe
    return $self->serve_static_($name . "." . $self->stash('format'));
}

sub _set_test($) {
    my $self = shift;

    $self->{job} = Scheduler::job_get($self->param('testid'));
    return undef unless $self->{job};

    $self->{testdirname} = $self->{job}->{'settings'}->{'NAME'};
    $self->{static} = Mojolicious::Static->new;
    push @{$self->{static}->paths}, openqa::testresultdir($self->{testdirname});
    push @{$self->{static}->paths}, openqa::testresultdir($self->{testdirname} . '/ulogs');
    return 1;
}

sub test_file {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;

    return $self->serve_static_($self->param('filename'));
}

sub test_asset {
    my $self = shift;

    # FIXME: make sure asset belongs to the job

    my $asset;
    if ($self->param('assetid')) {
        $asset = Scheduler::asset_get(id => $self->param('assetid'))->single();
    }
    else {
        $asset = Scheduler::asset_get(type => $self->param('assettype'), name => $self->param('assetname'))->single();
    }

    return $self->render_not_found unless $asset;

    my $path = '/assets/'.$asset->type.'/'.$asset->name;
    if ($self->param('subpath')) {
        $path .= '/'.$self->param('subpath');
        # better safe than sorry. Mojo seems to canonicalize the
        # urls for us already so this is actually not needed
        return $self->render_exception("invalid character in path") if ($path =~ /\/\.\./ || $path =~ /\.\.\//);
    }

    $self->app->log->debug("redirect to $path");
    return $self->redirect_to($path);
}


sub test_diskimage {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;

    my $diskimg = $self->param('imageid');

    my $basepath = back_log($self->{testdirname});

    return $self->render_not_found if (!-d $basepath);

    my $imgpath = "$basepath/$diskimg";
    return $self->render_not_found if (!-e $imgpath);

    # TODO: the original had gzip compression here
    #print header(-charset=>"UTF-8", -type=>"application/x-gzip", -attachment => $testname.'_'.$diskimg.'.gz', -expires=>'+24h', -max_age=>'86400', -Last_Modified=>awstandard::HTTPdate($mtime));
    return $self->serve_static_($imgpath);
}

sub test_isoimage {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;
    push @{$self->{static}->paths}, $openqa::isodir;

    return $self->serve_static_($self->{job}->{settings}->{ISO});
}

sub serve_static_($$) {
    my $self = shift;

    my $asset = shift;

    $self->app->log->debug("looking for " . pp($asset) . " in " . pp($self->{static}->paths));
    if ($asset && !ref($asset)) {
        # TODO: check for plain file name
        $asset = $self->{static}->file($asset);
    }

    $self->app->log->debug("found " . pp($asset));

    return $self->render_not_found unless $asset;

    if (ref($asset) eq "Mojo::Asset::File") {
        my $filename = basename($asset->path);
        # guess content type from extension
        if ($filename =~ m/\.([^\.]+)$/) {
            my $ext = $1;
            my $filetype = $self->app->types->type($ext);
            if ($filetype) {
                $self->res->headers->content_type($filetype);
            }
            if ($ext eq 'iso') {
                # force saveAs
                $self->res->headers->content_disposition("attatchment; filename=$filename;");
            }
        }
    }

    $self->{static}->serve_asset($self, $asset);
    return !!$self->rendered;
}

# images are served by test_file, only thumbnails are special
sub test_thumbnail {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;

    my $asset = $self->{static}->file(".thumbs/" . $self->param('filename'));
    return $self->serve_static_($asset);
}

1;
# vim: set sw=4 et:
