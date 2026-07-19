# Flight Wall OS - Application Layer
# Layer 3: Application-specific configuration on top of fedora-bootc-pi

FROM ghcr.io/tempest-concorde/fedora-bootc-pi:latest

# Metadata
LABEL org.opencontainers.image.title="Flight Wall OS"
LABEL org.opencontainers.image.description="Application layer bootc image for Flight Wall LED display"
LABEL org.opencontainers.image.source="https://github.com/tempest-concorde/fw-os"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.vendor="tempest-concorde"
LABEL containers.bootc="1"

# GPIO/I2C packages for LED matrix control
RUN dnf install -y \
    libgpiod \
    libgpiod-utils \
    i2c-tools \
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

# Application quadlet units (user-level systemd)
COPY fw-app.container /etc/containers/systemd/users/1000/
COPY fw-app.image /etc/containers/systemd/users/1000/

# Application secret sync script
RUN mkdir -p /usr/libexec/fw-os
COPY sync-fw-secrets.sh /usr/libexec/fw-os/
RUN chmod +x /usr/libexec/fw-os/sync-fw-secrets.sh

# Set device hostname
RUN echo 'fw' > /etc/hostname

RUN bootc container lint
