#!/usr/bin/env bash
# Image assembly only. No installation or network activity is needed at boot.
set -Eeuo pipefail
[[ "$(id -u)" == 0 ]]
install -d -m 0755 /usr/share/getbible/seed /usr/local/lib/getbible
install -m 0755 /usr/share/getbible/api/src/bin/* /usr/local/lib/getbible/
rm -f /etc/nginx/sites-enabled/default
install -m 0644 /usr/share/getbible/api/docker/nginx-default.conf /etc/nginx/conf.d/getbible-container.conf
systemctl enable nginx.service
# Docker owns the network, device tree, shutdown and operating system updates.
# Endpoint services retain their full systemd isolation settings.
systemctl mask getty.target console-getty.service systemd-logind.service \
    systemd-udevd.service systemd-udev-trigger.service systemd-resolved.service \
    systemd-networkd.service systemd-networkd-wait-online.service \
    apt-daily.timer apt-daily-upgrade.timer
systemctl disable certbot.timer
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/getbible-container.conf <<'CONF'
[Journal]
Storage=persistent
SystemMaxUse=256M
RuntimeMaxUse=32M
ForwardToConsole=yes
CONF
cp -a /etc/nginx /usr/share/getbible/seed/nginx
cp -a /etc/systemd/system /usr/share/getbible/seed/systemd
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname
