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
# Re-add Fedora Rawhide repo (base image removes it after its own installs)
RUN printf '[fedora-rawhide]\nname=Fedora - Rawhide\nmetalink=https://mirrors.fedoraproject.org/metalink?repo=rawhide&arch=$basearch\nenabled=1\ngpgcheck=0\nskip_if_unavailable=False\n' \
    > /etc/yum.repos.d/fedora-rawhide.repo && \
    dnf install -y \
    --disablerepo='*' --enablerepo='fedora-rawhide' \
    python3-libgpiod \
    i2c-tools \
    && dnf clean all \
    && rm -f /etc/yum.repos.d/fedora-rawhide.repo

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
