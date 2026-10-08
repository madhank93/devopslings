#!/bin/bash
set -e

# Restart the two services that loaded the library
systemctl restart widget.service
systemctl restart cache.service

# Unattended: daily, security archive only, never reboot on its own
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'CONF'
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
CONF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

# Write the answer file
cat > /root/answers/patch.md <<'ANS'
stale_library: libwidget.so.1
found_with: (deleted)
reboot_required: linux-image-6.12.57+deb13-amd64
ANS
