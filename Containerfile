# Flight Wall OS - Application Layer
# Layer 3: Application-specific configuration on top of fedora-bootc-pi

# Base pinned to SemVer tag + SHA256 digest. Dependabot opens a PR when
# fedora-bootc-pi rebuilds the 3.0.2 tag (new digest) or releases 3.0.3+.
FROM ghcr.io/tempest-concorde/fedora-bootc-pi:3.0.2@sha256:038889b0a1a156a1ba20ccda1e69398a806f59c8e463b394a460dbfd613fdabd

# Metadata
LABEL org.opencontainers.image.title="Flight Wall OS"
LABEL org.opencontainers.image.description="Application layer bootc image for Flight Wall LED display"
LABEL org.opencontainers.image.source="https://github.com/tempest-concorde/fw-os"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.vendor="tempest-concorde"
LABEL containers.bootc="1"

# GPIO/I2C packages for LED matrix control + systemd-container (machinectl)
RUN dnf install -y \
    libgpiod \
    libgpiod-utils \
    i2c-tools \
    systemd-container \
    && dnf clean all

# Create core user (UID 1000) with gpio/i2c groups at boot via sysusers
COPY core-user.conf /usr/lib/sysusers.d/50-fw-core.conf

# Create fw-app directories with correct ownership at boot via tmpfiles
COPY fw-os-dirs.conf /usr/lib/tmpfiles.d/50-fw-os.conf

# Create subuid/subgid entries for core user at boot via tmpfiles
# Required for rootless podman user namespace mapping
COPY subuid-subgid.conf /usr/lib/tmpfiles.d/50-fw-subuid-subgid.conf

# Tailscale certificate renewal automation
COPY tailscale-cert-renew.sh /usr/local/bin/
COPY tailscale-cert-renew.service /usr/lib/systemd/system/
COPY tailscale-cert-renew.timer /usr/lib/systemd/system/
RUN chmod +x /usr/local/bin/tailscale-cert-renew.sh && \
    systemctl enable tailscale-cert-renew.timer

# First-boot secret sync — provisions podman secrets (TLS certs, OAuth, JWT)
# before the fw-app quadlet starts. WantedBy=multi-user.target ensures ordering.
COPY fw-app-secrets.service /usr/lib/systemd/system/
COPY fw-app-secrets.sh /usr/libexec/fw-os/
COPY wait-for-fw-secrets.sh /usr/libexec/fw-os/
COPY fw-app.env.example /usr/share/fw-os/fw-app.env.example
RUN chmod +x /usr/libexec/fw-os/fw-app-secrets.sh && \
    chmod +x /usr/libexec/fw-os/wait-for-fw-secrets.sh && \
    systemctl enable fw-app-secrets.service

# Application quadlet units (user-level systemd)
COPY fw-app.container /etc/containers/systemd/users/1000/
COPY fw-app.image /etc/containers/systemd/users/1000/

# Start the core user's systemd instance at boot so the rootless quadlet
# units under /etc/containers/systemd/users/1000/ are generated and run.
# Bootc-native equivalent of `loginctl enable-linger core` (no first-boot
# script; survives bootc upgrade/reboot).
RUN systemctl enable user@1000.service

# Allow rootless podman to publish privileged port 443 on the host loopback
# (net.ipv4.ip_unprivileged_port_start=0), required for
# PublishPort=127.0.0.1:443:8443.
COPY 99-fw-unprivileged-ports.conf /usr/lib/sysctl.d/

# Application secret sync script
RUN mkdir -p /usr/libexec/fw-os
COPY sync-fw-secrets.sh /usr/libexec/fw-os/
RUN chmod +x /usr/libexec/fw-os/sync-fw-secrets.sh

# Set device hostname
RUN echo 'fw' > /etc/hostname

RUN bootc container lint
