package FusionInventory::Agent::Task::Inventory::Virtualization::Vmsystem;

use strict;
use warnings;

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Solaris;

my @vmware_patterns = (
    'VMware vmxnet virtual NIC driver',
    'Vendor: VMware\s+Model: Virtual disk',
    'Vendor: VMware,\s+Model: VMware Virtual ',
    ': VMware Virtual IDE CDROM Drive'
);
my $vmware_pattern = _assemblePatterns(@vmware_patterns);

my @qemu_patterns = (
    ' QEMUAPIC ',
    'QEMU Virtual CPU',
    ': QEMU HARDDISK,',
    ': QEMU CD-ROM,'
);
my $qemu_pattern = _assemblePatterns(@qemu_patterns);

my @virtual_machine_patterns = (
    ': Virtual HD,',
    ': Virtual CD,'
);
my $virtual_machine_pattern = _assemblePatterns(@virtual_machine_patterns);

my @virtualbox_patterns = (
    ' VBOXBIOS ',
    ': VBOX HARDDISK,',
    ': VBOX CD-ROM,',
);
my $virtualbox_pattern = _assemblePatterns(@virtualbox_patterns);

my @xen_patterns = (
    'Hypervisor signature: xen',
    'Xen virtual console successfully installed',
    'Xen reported:',
    'Xen: \d+ - \d+',
    'xen-vbd: registered block device',
    'ACPI: [A-Z]{4} \(v\d+\s+Xen ',
);
my $xen_pattern = _assemblePatterns(@xen_patterns);

my %module_patterns = (
    '^vmxnet\s' => 'VMware',
    '^xen_\w+front\s' => 'Xen',
);

sub isEnabled {
    return 1;
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};
    my $logger    = $params{logger};

    my $type = _getType($inventory->getSection('BIOS'), $logger);

    # for consistency with HVM domU
    if ($type eq 'Xen' && !$inventory->getBios('SMANUFACTURER')) {
        $inventory->setBios({
            SMANUFACTURER => 'Xen',
            SMODEL => 'PVM domU'
        });
    }

    # compute a compound identifier, as Virtuozzo uses the same identifier
    # for the host and for the guests
    if ($type eq 'Virtuozzo') {
        my $hostID  = $inventory->getHardware('UUID') || '';
        my $guestID = getFirstMatch(
            file => '/proc/self/status',
            pattern => qr/^envID:\s*(\d+)/
        ) || '';
        $inventory->setHardware({ UUID => $hostID . '-' . $guestID });
    }

    $inventory->setHardware({
        VMSYSTEM => $type,
    });
}

sub _getType {
    my ($bios, $logger) = @_;

    if ($bios->{SMANUFACTURER}) {
        return 'Hyper-V' if $bios->{SMANUFACTURER} =~ /Microsoft/;
        return 'VMware'  if $bios->{SMANUFACTURER} =~ /VMware/;
    }
    if ($bios->{BMANUFACTURER}) {
        return 'QEMU'       if $bios->{BMANUFACTURER} =~ /(QEMU|Bochs)/;
        return 'VirtualBox' if $bios->{BMANUFACTURER} =~ /(VirtualBox|innotek)/;
        return 'Xen'        if $bios->{BMANUFACTURER} =~ /^Xen/;
    }
    if ($bios->{SMODEL}) {
        return 'VMware'          if $bios->{SMODEL} =~ /VMware/;
        return 'Virtual Machine' if $bios->{SMODEL} =~ /Virtual Machine/;
    }
    if ($bios->{BVERSION}) {
        return 'VirtualBox'  if $bios->{BVERSION} =~ /VirtualBox/;
    }

    if (-f '/.dockerinit') {
        return 'Docker';
    }

    # Solaris zones
    if (canRun('/usr/sbin/zoneadm')) {
        my $zone = getZone();
        return 'SolarisZone' if $zone ne 'global';
    }

    # Xen PV host
    if (
        -d '/proc/xen' ||
        getFirstMatch(
            file    => '/sys/devices/system/clocksource/clocksource0/available_clocksource',
            pattern => qr/xen/
        )
    ) {
        if (getFirstMatch(
            file    => '/proc/xen/capabilities',
            pattern => qr/control_d/
        )) {
            # dom0 host
            return 'Physical';
        } else {
            # domU PV host
            return 'Xen';
        }
    }

    my $result;

    if (canRun('/sbin/sysctl')) {
        my $handle = getFileHandle(
            command => '/sbin/sysctl -n security.jail.jailed',
            logger => $logger
        );
        my $line = <$handle>;
        close $handle;
        return 'BSDJail' if $line && $line == 1;
    }

    # loaded modules

    if (-f '/proc/modules') {
        my $handle = getFileHandle(
            file => '/proc/modules',
            logger => $logger
        );
        while (my $line = <$handle>) {
            foreach my $pattern (keys %module_patterns) {
                next unless $line =~ /$pattern/;
                $result = $module_patterns{$pattern};
                last;
            }
        }
        close $handle;
    }
    return $result if $result;

    # dmesg

    my $handle;
    if (-r '/var/log/dmesg') {
        $handle = getFileHandle(file => '/var/log/dmesg', logger => $logger);
    } elsif (-x '/bin/dmesg') {
        $handle = getFileHandle(command => '/bin/dmesg', logger => $logger);
    } elsif (-x '/sbin/dmesg') {
        # On OpenBSD, dmesg is in sbin
        # http://forge.fusioninventory.org/issues/402
        $handle = getFileHandle(command => '/sbin/dmesg', logger => $logger);
    }

    if ($handle) {
        $result = _matchPatterns($handle);
        close $handle;
        return $result if $result;
    }

    # scsi

    if (-f '/proc/scsi/scsi') {
        my $handle = getFileHandle(
            file => '/proc/scsi/scsi',
            logger => $logger
        );
        $result = _matchPatterns($handle);
        close $handle;
    }
    return $result if $result;

    if (getFirstMatch(
        file    => '/proc/1/environ',
        pattern => qr/container=lxc/
    )) {
        return 'lxc';
    }

    # OpenVZ
    if (-f '/proc/self/status') {
        my $handle = getFileHandle(
            file => '/proc/self/status',
            logger => $logger
        );
        while (my $line = <$handle>) {
            my ($key, $value) = split(/:/, $line);
            $result = "Virtuozzo" if $key eq 'envID' && $value > 0;
        }
    }
    return $result if $result;

    return 'Physical';
}

sub _assemblePatterns {
    my (@patterns) = @_;

    my $pattern = '(?:' . join('|', @patterns) . ')';
    return qr/$pattern/;
}

sub _matchPatterns {
    my ($handle) = @_;

    while (my $line = <$handle>) {
        return 'VMware'          if $line =~ $vmware_pattern;
        return 'QEMU'            if $line =~ $qemu_pattern;
        return 'Virtual Machine' if $line =~ $virtual_machine_pattern;
        return 'VirtualBox'      if $line =~ $virtualbox_pattern;
        return 'Xen'             if $line =~ $xen_pattern;
    }
}

1;
