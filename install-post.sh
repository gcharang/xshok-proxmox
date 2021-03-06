#!/usr/bin/env bash
################################################################################
# This is property of eXtremeSHOK.com
# You are free to use, modify and distribute, however you may not remove this notice.
# Copyright (c) Adrian Jon Kriel :: admin@extremeshok.com
################################################################################
#
# Script updates can be found at: https://github.com/extremeshok/xshok-proxmox
#
# post-installation script for Proxmox
#
# License: BSD (Berkeley Software Distribution)
#
################################################################################
#
# Assumptions: proxmox installed
#
# Notes:
# to disable the MOTD banner, set the env NO_MOTD_BANNER to true (export NO_MOTD_BANNER=true)
#
################################################################################
#
#    THERE ARE NO USER CONFIGURABLE OPTIONS IN THIS SCRIPT
#
################################################################################

export NO_MOTD_BANNER=true

# Set the local
export LANG="en_US.UTF-8"
export LC_ALL="C"

## Force APT to use IPv4
echo -e "Acquire::ForceIPv4 \"true\";\\n" >/etc/apt/apt.conf.d/99force-ipv4

## disable enterprise proxmox repo
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  echo -e "#deb https://enterprise.proxmox.com/debian buster pve-enterprise\\n" >/etc/apt/sources.list.d/pve-enterprise.list
fi
## enable public proxmox repo
if [ ! -f /etc/apt/sources.list.d/proxmox.list ] && [ ! -f /etc/apt/sources.list.d/pve-public-repo.list ] && [ ! -f /etc/apt/sources.list.d/pve-install-repo.list ]; then
  echo -e "deb http://download.proxmox.com/debian buster pve-no-subscription\\n" >/etc/apt/sources.list.d/pve-public-repo.list
fi

## Add non-free to sources
sed -i "s/main contrib/main non-free contrib/g" /etc/apt/sources.list

## Add the latest ceph provided by proxmox
echo "deb http://download.proxmox.com/debian/ceph-luminous buster main" >/etc/apt/sources.list.d/ceph.list

## Refresh the package lists
apt-get update >/dev/null

## Remove conflicting utilities
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' purge ntp openntpd chrony ksm-control-daemon

## Fix no public key error for debian repo
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' install debian-archive-keyring

## Update proxmox and install various system utils
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' dist-upgrade
pveam update

## Install openvswitch for a virtual internal network
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' install openvswitch-switch

## Install missing ksmtuned
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' install ksmtuned
systemctl enable ksmtuned
systemctl enable ksm

## Install common system utilities
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' install whois omping tmux sshpass wget axel nano pigz net-tools htop iptraf iotop iftop iperf vim vim-nox unzip zip software-properties-common aptitude curl dos2unix dialog mlocate build-essential git ipset
#snmpd snmp-mibs-downloader

## Remove no longer required packages and purge old cached updates
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' autoremove
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' autoclean

## Disable portmapper / rpcbind (security)
systemctl disable rpcbind
systemctl stop rpcbind

## Set Timezone to UTC and enable NTP
timedatectl set-timezone UTC
cat <<EOF >/etc/systemd/timesyncd.conf
[Time]
NTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=2048
EOF
service systemd-timesyncd start
timedatectl set-ntp true

## Set pigz to replace gzip, 2x faster gzip compression
cat <<EOF >/bin/pigzwrapper
#!/bin/sh
PATH=/bin:\$PATH
GZIP="-1"
exec /usr/bin/pigz "\$@"
EOF
mv -f /bin/gzip /bin/gzip.original
cp -f /bin/pigzwrapper /bin/gzip
chmod +x /bin/pigzwrapper
chmod +x /bin/gzip

## Detect if this is an OVH server by getting the global IP and checking the ASN
if [ "$(whois -h v4.whois.cymru.com " -t $(curl ipinfo.io/ip 2>/dev/null)" | tail -n 1 | cut -d'|' -f3 | grep -i "ovh")" != "" ]; then
  echo "Deteted OVH Server, installing OVH RTM (real time monitoring)"
  # http://help.ovh.co.uk/RealTimeMonitoring
  # https://docs.ovh.com/gb/en/dedicated/install-rtm/
  wget -qO - https://last-public-ovh-infra-yak.snap.mirrors.ovh.net/yak/archives/apply.sh | OVH_PUPPET_MANIFEST=distribyak/catalog/master/puppet/manifests/common/rtmv2.pp bash
fi

## Protect the web interface with fail2ban
/usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' install fail2ban
# shellcheck disable=1117
cat <<EOF >/etc/fail2ban/filter.d/proxmox.conf
[Definition]
failregex = pvedaemon\[.*authentication failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
EOF
cat <<EOF >/etc/fail2ban/jail.d/proxmox.conf
[proxmox]
enabled = true
port = https,http,8006
filter = proxmox
logpath = /var/log/daemon.log
maxretry = 3
# 1 hour
bantime = 3600
EOF
cat <<EOF >/etc/fail2ban/jail.local
[DEFAULT]
banaction = iptables-ipset-proto4
EOF
systemctl enable fail2ban
##testing
#fail2ban-regex /var/log/daemon.log /etc/fail2ban/filter.d/proxmox.conf

## Increase vzdump backup speed, enable pigz and fix ionice
sed -i "s/#bwlimit:.*/bwlimit: 0/" /etc/vzdump.conf
sed -i "s/#pigz:.*/pigz: 1/" /etc/vzdump.conf
sed -i "s/#ionice:.*/ionice: 5/" /etc/vzdump.conf

## Bugfix: pve 5.1 high swap usage with low memory usage
echo "vm.swappiness=10" >>/etc/sysctl.conf
sysctl -p

## Bugfix: reserve 512MB memory for system
echo "vm.min_free_kbytes = 524288" >>/etc/sysctl.conf
sysctl -p

## Remove subscription banner
if [ -f "/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js" ]; then
  sed -i "s/data.status !== 'Active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
  # create a daily cron to make sure the banner does not re-appear
  cat <<'EOF' >/etc/cron.daily/proxmox-nosub
#!/bin/sh
# eXtremeSHOK.com Remove subscription banner
sed -i "s/data.status !== 'Active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
EOF
  chmod 755 /etc/cron.daily/proxmox-nosub
fi

## Pretty MOTD BANNER
if [ -z "${NO_MOTD_BANNER}" ]; then
  if ! grep -q https "/etc/motd"; then
    cat <<'EOF' >/etc/motd.new
	   This system is optimised by:            https://eXtremeSHOK.com
	     __   ___                            _____ _    _  ____  _  __
	     \ \ / / |                          / ____| |  | |/ __ \| |/ /
	  ___ \ V /| |_ _ __ ___ _ __ ___   ___| (___ | |__| | |  | | ' /
	 / _ \ > < | __| '__/ _ \ '_ ` _ \ / _ \\___ \|  __  | |  | |  <
	|  __// . \| |_| | |  __/ | | | | |  __/____) | |  | | |__| | . \
	 \___/_/ \_\\__|_|  \___|_| |_| |_|\___|_____/|_|  |_|\____/|_|\_\


EOF

    cat /etc/motd >>/etc/motd.new
    mv /etc/motd.new /etc/motd
  fi
fi

## Increase max user watches
# BUG FIX : No space left on device
echo 1048576 >/proc/sys/fs/inotify/max_user_watches
echo "fs.inotify.max_user_watches=1048576" >>/etc/sysctl.conf
sysctl -p /etc/sysctl.conf

## Increase max FD limit / ulimit
cat <<EOF >>/etc/security/limits.conf
# eXtremeSHOK.com Increase max FD limit / ulimit
* soft     nproc          256000
* hard     nproc          256000
* soft     nofile         256000
* hard     nofile         256000
root soft     nproc          256000
root hard     nproc          256000
root soft     nofile         256000
root hard     nofile         256000
EOF

## Enable TCP BBR congestion control
cat <<EOF >/etc/sysctl.d/10-kernel-bbr.conf
# eXtremeSHOK.com
# TCP BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

## Increase kernel max Key limit
cat <<EOF >/etc/sysctl.d/60-maxkeys.conf
# eXtremeSHOK.com
# Increase kernel max Key limit
kernel.keys.root_maxkeys=1000000
kernel.keys.maxkeys=1000000
EOF

## Set systemd ulimits
echo "DefaultLimitNOFILE=256000" >>/etc/systemd/system.conf
echo "DefaultLimitNOFILE=256000" >>/etc/systemd/user.conf
echo 'session required pam_limits.so' | tee -a /etc/pam.d/common-session-noninteractive
echo 'session required pam_limits.so' | tee -a /etc/pam.d/common-session
echo 'session required pam_limits.so' | tee -a /etc/pam.d/runuser-l

## Set ulimit for the shell user
cd ~ && echo "ulimit -n 256000" >>.bashrc
echo "ulimit -n 256000" >>.profile

# propagate the setting into the kernel
update-initramfs -u -k all

## Script Finish
echo -e '\033[1;33m Finished....please restart the system \033[0m'
