#!/usr/bin/perl -w

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;
use Data::Dump qw/pp dd/;
use openqa::distri::opensuse qw(generate_jobs);

use Test::More tests => 1;

my @testdata = (
    {
        iso => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
        params => [
            {
                DESKTOP     => "kde",
                DISTRI      => "opensuse",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME        => "openSUSE-Factory-DVD-x86_64-Build0725-RAID0",
                PRIO        => 45,
                RAIDLEVEL   => 0,
                VERSION     => "Factory",
            },
            {
                DESKTOP     => "kde",
                DISTRI      => "opensuse",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME        => "openSUSE-Factory-DVD-x86_64-Build0725-RAID1",
                PRIO        => 46,
                RAIDLEVEL   => 1,
                VERSION     => "Factory",
            },
            {
                DESKTOP     => "kde",
                DISTRI      => "opensuse",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME        => "openSUSE-Factory-DVD-x86_64-Build0725-RAID10",
                PRIO        => 46,
                RAIDLEVEL   => 10,
                VERSION     => "Factory",
            },
            {
                DESKTOP     => "kde",
                DISTRI      => "opensuse",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME        => "openSUSE-Factory-DVD-x86_64-Build0725-RAID5",
                PRIO        => 46,
                RAIDLEVEL   => 5,
                VERSION     => "Factory",
            },
            {
                BTRFS     => 1,
                DESKTOP   => "kde",
                DISTRI    => "opensuse",
                DVD       => 1,
                ENCRYPT   => 1,
                FLAVOR    => "DVD",
                HDDSIZEGB => 20,
                ISO       => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                LVM       => 1,
                NAME      => "openSUSE-Factory-DVD-x86_64-Build0725-btrfscryptlvm",
                NICEVIDEO => 1,
                PRIO      => 45,
                VERSION   => "Factory",
            },
            {
                DESKTOP            => "kde",
                DISTRI             => "opensuse",
                DVD                => 1,
                ENCRYPT            => 1,
                FLAVOR             => "DVD",
                ISO                => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                LVM                => 1,
                NAME               => "openSUSE-Factory-DVD-x86_64-Build0725-cryptlvm",
                NICEVIDEO          => 1,
                PRIO               => 45,
                REBOOTAFTERINSTALL => 0,
                VERSION            => "Factory",
            },
            {
                DESKTOP => "kde",
                DISTRI  => "opensuse",
                DOCRUN  => 1,
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-doc",
                PRIO    => 55,
                QEMUVGA => "std",
                VERSION => "Factory",
            },
            {
                DESKTOP    => "kde",
                DISTRI     => "opensuse",
                DUALBOOT   => 1,
                DVD        => 1,
                FLAVOR     => "DVD",
                HDD_1      => "Windows-8.hda",
                HDDMODEL   => "ide-hd",
                HDDVERSION => "Windows 8",
                ISO        => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME       => "openSUSE-Factory-DVD-x86_64-Build0725-dual_windows8",
                NUMDISKS   => 1,
                PRIO       => 45,
                VERSION    => "Factory",
            },
            {
                DESKTOP => "gnome",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                LVM     => 1,
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-gnome",
                PRIO    => 40,
                VERSION => "Factory",
            },
            {
                BTRFS     => 1,
                DESKTOP   => "gnome",
                DISTRI    => "opensuse",
                DVD       => 1,
                FLAVOR    => "DVD",
                HDDSIZEGB => 20,
                ISO       => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                LVM       => 1,
                NAME      => "openSUSE-Factory-DVD-x86_64-Build0725-gnome+btrfs",
                PRIO      => 45,
                VERSION   => "Factory",
            },
            {
                DESKTOP => "gnome",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                LAPTOP  => 1,
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-gnome+laptop",
                PRIO    => 45,
                VERSION => "Factory",
            },
            {
                DESKTOP => "kde",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-kde",
                PRIO    => 35,
                VERSION => "Factory",
            },
            {
                BTRFS     => 1,
                DESKTOP   => "kde",
                DISTRI    => "opensuse",
                DVD       => 1,
                FLAVOR    => "DVD",
                HDDSIZEGB => 20,
                ISO       => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME      => "openSUSE-Factory-DVD-x86_64-Build0725-kde+btrfs",
                PRIO      => 45,
                VERSION   => "Factory",
            },
            {
                DESKTOP => "kde",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                LAPTOP  => 1,
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-kde+laptop",
                PRIO    => 45,
                VERSION => "Factory",
            },
            {
                DESKTOP => "kde",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-kde+usb",
                PRIO    => 40,
                USBBOOT => 1,
                VERSION => "Factory",
            },
            {
                DESKTOP => "lxde",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                LVM     => 1,
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-lxde",
                PRIO    => 44,
                VERSION => "Factory",
            },
            {
                DESKTOP => "minimalx",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-minimalx",
                PRIO    => 40,
                VERSION => "Factory",
            },
            {
                BTRFS     => 1,
                DESKTOP   => "minimalx",
                DISTRI    => "opensuse",
                DVD       => 1,
                FLAVOR    => "DVD",
                HDDSIZEGB => 20,
                ISO       => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME      => "openSUSE-Factory-DVD-x86_64-Build0725-minimalx+btrfs",
                PRIO      => 45,
                VERSION   => "Factory",
            },
            {
                BTRFS       => 1,
                DESKTOP     => "minimalx",
                DISTRI      => "opensuse",
                DVD         => 1,
                FLAVOR      => "DVD",
                HDDSIZEGB   => 20,
                INSTALLONLY => 1,
                ISO         => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME        => "openSUSE-Factory-DVD-x86_64-Build0725-minimalx+btrfs+nosephome",
                PRIO        => 45,
                TOGGLEHOME  => 1,
                VERSION     => "Factory",
            },
            {
                DESKTOP => "kde",
                DISTRI => "opensuse",
                DOCRUN => 1,
                DVD => 1,
                FLAVOR => "DVD",
                ISO => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME => "openSUSE-Factory-DVD-x86_64-Build0725-nice",
                NICEVIDEO => 1,
                PRIO => 45,
                REBOOTAFTERINSTALL => 0,
                SCREENSHOTINTERVAL => 0.25,
                VERSION => "Factory",
            },
            {
                DESKTOP     => "kde",
                DISTRI      => "opensuse",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME        => "openSUSE-Factory-DVD-x86_64-Build0725-smp",
                NICEVIDEO   => 1,
                PRIO        => 45,
                QEMUCPUS    => 4,
                VERSION     => "Factory",
            },
            {
                DESKTOP   => "kde",
                DISTRI    => "opensuse",
                DVD       => 1,
                FLAVOR    => "DVD",
                ISO       => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME      => "openSUSE-Factory-DVD-x86_64-Build0725-splitusr",
                NICEVIDEO => 1,
                PRIO      => 45,
                SPLITUSR  => 1,
                VERSION   => "Factory",
            },
            {
                DESKTOP   => "textmode",
                DISTRI    => "opensuse",
                DVD       => 1,
                FLAVOR    => "DVD",
                ISO       => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME      => "openSUSE-Factory-DVD-x86_64-Build0725-textmode",
                PRIO      => 35,
                VERSION   => "Factory",
                VIDEOMODE => "text",
            },
            {
                BTRFS     => 1,
                DESKTOP   => "textmode",
                DISTRI    => "opensuse",
                DVD       => 1,
                FLAVOR    => "DVD",
                HDDSIZEGB => 20,
                ISO       => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME      => "openSUSE-Factory-DVD-x86_64-Build0725-textmode+btrfs",
                PRIO      => 45,
                VERSION   => "Factory",
                VIDEOMODE => "text",
            },
            {
                DESKTOP     => "kde",
                DISTRI      => "opensuse",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME        => "openSUSE-Factory-DVD-x86_64-Build0725-uefi",
                PRIO        => 40,
                QEMUCPU     => "qemu64",
                UEFI        => 1,
                VERSION     => "Factory",
            },
            {
                DESKTOP    => "kde",
                DISTRI     => "opensuse",
                DVD        => 1,
                FLAVOR     => "DVD",
                HDD_1      => "openSUSE-12.1-x86_64.hda",
                HDDVERSION => "openSUSE-12.1",
                ISO        => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME       => "openSUSE-Factory-DVD-x86_64-Build0725-update_121",
                PRIO       => 45,
                UPGRADE    => 1,
                VERSION    => "Factory",
            },
            {
                DESKTOP    => "kde",
                DISTRI     => "opensuse",
                DVD        => 1,
                FLAVOR     => "DVD",
                HDD_1      => "openSUSE-12.2-x86_64.hda",
                HDDVERSION => "openSUSE-12.2",
                ISO        => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME       => "openSUSE-Factory-DVD-x86_64-Build0725-update_122",
                PRIO       => 45,
                UPGRADE    => 1,
                VERSION    => "Factory",
            },
            {
                DESKTOP    => "kde",
                DISTRI     => "opensuse",
                DVD        => 1,
                FLAVOR     => "DVD",
                HDD_1      => "openSUSE-12.3-x86_64.hda",
                HDDVERSION => "openSUSE-12.3",
                ISO        => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME       => "openSUSE-Factory-DVD-x86_64-Build0725-update_123",
                PRIO       => 45,
                UPGRADE    => 1,
                VERSION    => "Factory",
            },
            {
                DESKTOP => "xfce",
                DISTRI  => "opensuse",
                DVD     => 1,
                FLAVOR  => "DVD",
                ISO     => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
                NAME    => "openSUSE-Factory-DVD-x86_64-Build0725-xfce",
                PRIO    => 44,
                VERSION => "Factory",
            },
        ],
    },
);

for my $t (@testdata) {
    my $params = openqa::distri::opensuse->generate_jobs({}, iso => $t->{iso});
    if ($t->{params}) {
        is_deeply($params, $t->{params}) or diag("failed params: ". pp($params));
    } else {
        ok(!defined $params, $t->{iso});
    }
}
