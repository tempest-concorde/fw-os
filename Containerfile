# Flight Wall OS - Application Layer
# Layer 3: Application-specific configuration on top of fedora-bootc-pi

FROM ghcr.io/tempest-concorde/fedora-bootc-pi:latest

# Metadata
LABEL org.opencontainers.image.title="Flight Wall OS"
LABEL org.opencontainers.image.description="Application layer bootc image for Flight Wall LED display"
LABEL org.opencontainers.image.source="https://github.com/tempest-concorde/fw-os"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL containers.bootc="1"

# Install GPIO/I2C packages for LED matrix control
# Use Fedora 42 (stable) — Rawhide's Python 3.15 has OpenSSL 4.0 deps
# that conflict with the base image. Only the C library is needed since
# fw-app is Go, not Python.
RUN printf '[fedora-42]\nname=Fedora 42\nmetalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-42&arch=$basearch\nenabled=1\ngpgcheck=0\nskip_if_unavailable=False\n' \
    > /etc/yum.repos.d/fedora-42.repo && \
    dnf install -y \
    --disablerepo='*' --enablerepo='fedora-42' \
    libgpiod \
    libgpiod-utils \
    i2c-tools \
    && dnf clean all \
    && rm -f /etc/yum.repos.d/fedora-42.repo

# Add core user to gpio and i2c groups for hardware access
RUN usermod -aG gpio,i2c core 2>/dev/null || true

# Copy Tailscale certificate renewal automation
COPY tailscale-cert-renew.sh /usr/local/bin/
COPY tailscale-cert-renew.service /usr/lib/systemd/system/
COPY tailscale-cert-renew.timer /usr/lib/systemd/system/
RUN chmod +x /usr/local/bin/tailscale-cert-renew.sh && \
    systemctl enable tailscale-cert-renew.timer

# Copy application quadlet units (user-level systemd)
COPY fw-app.container /etc/containers/systemd/users/1000/
COPY fw-app.image /etc/containers/systemd/users/1000/

# Copy application secret sync script
RUN mkdir -p /usr/libexec/fw-os
COPY sync-fw-secrets.sh /usr/libexec/fw-os/
RUN chmod +x /usr/libexec/fw-os/sync-fw-secrets.sh

# Validate bootc image
RUN bootc container lint
