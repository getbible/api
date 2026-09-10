#!/usr/bin/env bash
# Restore local installation before systemd can start any data-reading service.
set -Eeuo pipefail
umask 027
if [[ "${1:-}" != /sbin/init ]]; then exec "$@"; fi
[[ "$(id -u)" == 0 ]] || { echo 'The getBible system container must start as root.' >&2; exit 1; }
[[ -e /sys/fs/cgroup/cgroup.controllers ]] || {
    echo 'getBible requires rootful Docker with a private cgroup v2 namespace.' >&2; exit 1;
}
# A private namespace presents this container as 0::/. Never remount the
# host hierarchy or add a host /sys/fs/cgroup bind mount to work around this.
[[ "$(cat /proc/1/cgroup)" == '0::/' ]] || {
    echo 'Refusing a shared host cgroup namespace. Use the supplied Compose cgroup: private setting.' >&2; exit 1;
}
if ! mount -o remount,rw /sys/fs/cgroup; then
    echo 'Cannot delegate the private cgroup tree. Check the documented SYS_ADMIN and AppArmor settings.' >&2
    exit 1
fi
# Disconnect propagation from the host, then allow service mount namespaces.
mount --make-rprivate /
mount --make-rshared /

install -d -m 0755 /var/lib/getbible /var/log/getbible /run/getbible
exec 8>/var/lib/getbible/container.lock
flock -n 8 || { echo 'Another container is initializing this persistent installation.' >&2; exit 1; }

# Empty bind mounts hide image files. Seed only missing distribution files;
# application units, enable links and operator Nginx configuration survive.
for item in nginx systemd; do
    target=/etc/nginx
    [[ "$item" != systemd ]] || target=/etc/systemd/system
    install -d -m 0755 "$target"
    if [[ ! -e "$target/.getbible-seeded" ]]; then
        cp -a --no-clobber "/usr/share/getbible/seed/$item/." "$target/"
        touch "$target/.getbible-seeded"
    fi
done
# Helpers and the default health vhost belong to the image, not user state.
install -d -m 0755 /usr/local/lib/getbible
install -m 0755 /usr/share/getbible/api/src/bin/* /usr/local/lib/getbible/
install -m 0644 /usr/share/getbible/api/docker/nginx-default.conf /etc/nginx/conf.d/getbible-container.conf

if [[ ! -s /var/lib/getbible/machine-id ]]; then
    tr -d '-' < /proc/sys/kernel/random/uuid > /var/lib/getbible/machine-id
fi
[[ "$(cat /var/lib/getbible/machine-id)" =~ ^[0-9a-f]{32}$ ]] || {
    echo 'Invalid persisted machine-id.' >&2; exit 1;
}
install -m 0444 /var/lib/getbible/machine-id /etc/machine-id
if [[ -n "${TZ:-}" ]]; then
    [[ "$TZ" != /* && "$TZ" != *..* && -f "/usr/share/zoneinfo/$TZ" ]] || {
        echo 'TZ must name an installed IANA time zone.' >&2; exit 1;
    }
    ln -sfn "/usr/share/zoneinfo/$TZ" /etc/localtime
fi

/usr/local/lib/getbible/getbible-identities restore
/usr/local/lib/getbible/getbible-identities record --group adm --group systemd-journal
install -d -m 0755 -o root -g adm /var/log/nginx
/usr/local/bin/getbible container-init
nginx -t
# This marker is ephemeral. Failed initialization never reports healthy.
touch /run/getbible/container-initialized
exec "$@"
