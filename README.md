# fw-os — Flight Wall Operating System

Application-layer bootc image for the Flight Wall LED display, deployed on Raspberry Pi 4.

## Architecture

```
Layer 2: fw-os (this repo)        — GPIO, quadlets, cert renewal, secrets
  ↓ FROM
Layer 1: fedora-bootc-pi          — WiFi, Tailscale, node-exporter, SSH
  ↓ FROM
Base:    quay.io/fedora/fedora-bootc:42
```

## Deploying to Raspberry Pi 4

### Prerequisites

- Fedora workstation with `arm-image-installer` installed (`dnf install arm-image-installer`)
- SD card (32GB+) and card reader
- Ethernet connection for initial RPi4 setup
- SSH key pair

### Step 1: Flash Fedora IoT to SD card

```bash
make flash SD_CARD=/dev/mmcblk0 SSH_KEY_PATH=~/.ssh/id_rsa.pub
```

This downloads the Fedora IoT aarch64 raw image and writes it to the SD
card using `arm-image-installer` with your SSH key injected. No root
password is set — SSH key only.

### Step 2: Boot and connect

Insert the SD card into the RPi4, connect ethernet, and power on. Find
the IP from your router or with:

```bash
nmap -sn 192.168.1.0/24
```

SSH in:

```bash
ssh root@<rpi4-ip>
```

### Step 3: Configure WiFi

```bash
nmcli device wifi connect "YourSSID" password "YourPassword"
```

Verify connectivity, then ethernet can be disconnected for subsequent
steps if WiFi is the primary network.

### Step 4: Switch to fw-os

```bash
bootc switch ghcr.io/tempest-concorde/fw-os:latest
systemctl reboot
```

After reboot the system is running fw-os with all Flight Wall
components. The previous Fedora IoT deployment is preserved for
rollback (`bootc rollback`).

### Step 5: Configure Tailscale

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up --authkey=tskey-auth-xxx --ssh --accept-routes
```

After this, the RPi4 is accessible via Tailscale SSH from anywhere on
your tailnet.

### Step 6: Verify

```bash
# Check bootc status
bootc status

# Check fw-app container (runs as core user, UID 1000)
sudo -u core XDG_RUNTIME_DIR=/run/user/1000 podman ps

# Check services
systemctl status tailscaled
systemctl --user -M core@ status fw-app
```

## Updating

fw-os uses bootc for atomic image-based updates:

```bash
bootc upgrade
systemctl reboot
```

Rollback if something breaks:

```bash
bootc rollback
systemctl reboot
```

## ISO path (VM testing)

For testing in VMs without hardware, use the ISO/QCOW2 path:

```bash
# Requires gomplate + podman
export SSH_KEY_PATH=~/.ssh/id_rsa.pub
export WIFI_SSID=MyNetwork
export WIFI_PSK=MyPassword
make iso    # or: make qcow
```

## Development

```bash
make container   # Build image locally
make test-local  # Run interactively
make show-config # Show current settings
make help        # All targets
```

## Components

| File | Purpose |
|---|---|
| `Containerfile` | Image build — GPIO packages, sysusers, tmpfiles, quadlets |
| `core-user.conf` | sysusers.d — creates core user (UID 1000) with gpio/i2c groups |
| `fw-os-dirs.conf` | tmpfiles.d — creates .fw-app data/cert directories |
| `subuid-subgid.conf` | tmpfiles.d — allocates subuid/subgid ranges for rootless podman |
| `fw-app.container` | Quadlet — rootless fw-app container unit |
| `fw-app.image` | Quadlet — pre-pulls fw-app image on boot |
| `sync-fw-secrets.sh` | Syncs podman secrets into quadlet drop-ins |
| `tailscale-cert-renew.sh` | Fetches Tailscale TLS certs, updates podman secrets |
| `tailscale-cert-renew.service/timer` | Daily + on-boot cert renewal |

## Related Repositories

- [fedora-bootc-pi](https://github.com/tempest-concorde/fedora-bootc-pi) — Platform base layer
- [fw-app](https://github.com/tempest-concorde/fw-app) — Flight Wall Go application
- [fw-cicd](https://github.com/tempest-concorde/fw-cicd) — Shared CI/CD workflows

## License

Apache License 2.0
