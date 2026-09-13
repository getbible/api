# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ARG GETBIBLE_VERSION=2.2.0
ARG GETBIBLE_REVISION=unknown
ARG GETBIBLE_IMAGE_PYTHONS=
LABEL org.opencontainers.image.title="getBible API" \
      org.opencontainers.image.source="https://github.com/getbible/api" \
      org.opencontainers.image.version="$GETBIBLE_VERSION" \
      org.opencontainers.image.revision="$GETBIBLE_REVISION" \
      org.opencontainers.image.description="Native getBible manager and services in one systemd container"

ENV container=docker \
    GB_EXECUTION_MODE=docker \
    LANG=C.UTF-8 \
    TZ=UTC

# Dependencies are installed when the image is built, never on first boot.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       systemd systemd-sysv dbus nginx certbot python3-certbot-dns-cloudflare \
       python3 python3-venv python3-pip whiptail rsync git openssh-client curl \
       logrotate acl ca-certificates openssl xz-utils tar util-linux procps \
       passwd tzdata iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/share/getbible/api
COPY . /usr/share/getbible/api
RUN chmod 0755 getbible.sh src/bin/* docker/*.sh \
    && ln -s /usr/share/getbible/api/getbible.sh /usr/local/bin/getbible \
    && ln -s /usr/share/getbible/api/getbible.sh /usr/local/bin/getbible.sh \
    && GB_EXECUTION_MODE=native GETBIBLE_IMAGE_PYTHONS="$GETBIBLE_IMAGE_PYTHONS" \
       bash docker/build-runtimes.sh /usr/share/getbible/runtime \
    && bash docker/prepare-image.sh

EXPOSE 80
STOPSIGNAL SIGRTMIN+3
HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --retries=3 \
    CMD ["/usr/share/getbible/api/docker/healthcheck.sh"]
ENTRYPOINT ["/usr/share/getbible/api/docker/entrypoint.sh"]
CMD ["/sbin/init"]
