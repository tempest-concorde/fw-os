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

### Deployment configuration and secrets

Before starting fw-app, create the deployment-specific non-secret config file.
Do not commit this file: it identifies the GitHub organization allowed to log in
and the Tailscale FQDN used for the TLS certificate and healthcheck.

```bash
sudo install -d -m 0755 /etc/fw-os
sudo cp /usr/share/fw-os/fw-app.env.example /etc/fw-os/fw-app.env
sudoedit /etc/fw-os/fw-app.env
```

Set these values for the deployment:

```ini
FW_AUTH_GITHUB_ORG=your-github-org
FW_SERVER_FQDN=your-device.your-tailnet.ts.net
```

Create application secrets in core's rootless podman store. Secret names are
the exact `FW_*` environment-variable names fw-app consumes; there is no
secret-name translation. TLS cert/key secrets are generated automatically by
the Tailscale certificate service and must not be created manually.

```bash
cd /tmp
echo '<github-oauth-client-id>' | sudo -u core sh -c 'XDG_RUNTIME_DIR=/run/user/1000 podman secret create FW_AUTH_GITHUB_CLIENT_ID -'
echo '<github-oauth-client-secret>' | sudo -u core sh -c 'XDG_RUNTIME_DIR=/run/user/1000 podman secret create FW_AUTH_GITHUB_CLIENT_SECRET -'
echo '<jwt-secret-32-or-more-random-characters>' | sudo -u core sh -c 'XDG_RUNTIME_DIR=/run/user/1000 podman secret create FW_AUTH_JWT_SECRET -'
```

Restart the provisioning and application services after changing config or
secrets:

```bash
sudo systemctl restart fw-app-secrets.service
sudo -u core sh -c 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart fw-app'
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

## ADS-B feed (USB RTL-SDR → flightradar24)

Adds optional ADS-B reception, local aircraft pull, and flightradar24 sharing
via three rootless quadlets (`fw-adsb-readsb`, `fw-adsb-fr24feed`,
`fw-adsb-status` on the `fw-adsb` podman network). Feature spec:
[fw-gsd specs/003-usb-adsb-feeder](https://github.com/tempest-concorde/fw-gsd/tree/main/specs/003-usb-adsb-feeder).

### Hardware

Plug in a USB RTL-SDR ADS-B antenna (RTL2832U-era dongles, IDs `0bda:2832` /
`0bda:2838`). The shipped udev rule exposes it as `/dev/radio-adsb/rtl-sdr0`
(group `adsbrx`); replugging restarts `fw-adsb-readsb` via a user path unit.

### Configure

```bash
sudo mkdir -p /etc/fw-os
sudo cp /usr/share/fw-os/fw-adsb.env.example /etc/fw-os/fw-adsb.env
sudoedit /etc/fw-os/fw-adsb.env   # FW_FR24_ENABLED=true, optional station position
echo 'YOUR_FR24_SHARING_KEY' | sudo -u core sh -c 'XDG_RUNTIME_DIR=/run/user/1000 podman secret create fr24-sharing-key -'
sudo -u core sh -c 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart fw-adsb-fr24feed'
```

The sharing key **never** lives in the env file or image — only in the podman
secret mounted at `/run/secrets/fr24-sharing-key` inside the fr24feed container.

### Interfaces (tailnet-only at runtime)

| Endpoint | Port | Purpose |
|---|---|---|
| `http://<tailscale-ip>:8080/data/aircraft.json` | 8080 | live aircraft snapshot (tar1090 format) |
| TCP | 30003 | SBS/BaseStation stream |
| TCP | 30005 | BEAST stream (also feeds fw-adsb-fr24feed internally) |
| `http://<tailscale-ip>:8081/api/v1/feed/status` | 8081 | aggregated feed status + `/metrics` |

Quadlet `PublishPort` entries bind to the tailscale IPv4 via the boot-time
`fw-adsb-tailnet-bind.service` drop-ins; do not hand-edit those drop-ins.

### Disable / rollback

```bash
# keep local pull, stop upstream push
sudoedit /etc/fw-os/fw-adsb.env   # FW_FR24_ENABLED=false + restart fr24feed (above)
# full rollback of the feature
bootc rollback && systemctl reboot
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
| `fw-app.env.example` | Template for deployment-specific GitHub org and Tailscale FQDN |
| `sync-fw-secrets.sh` | Syncs podman secrets into quadlet drop-ins |
| `tailscale-cert-renew.sh` | Fetches Tailscale TLS certs, updates podman secrets |
| `tailscale-cert-renew.service/timer` | Daily + on-boot cert renewal |

## Related Repositories

- [fedora-bootc-pi](https://github.com/tempest-concorde/fedora-bootc-pi) — Platform base layer
- [fw-app](https://github.com/tempest-concorde/fw-app) — Flight Wall Go application
- [fw-cicd](https://github.com/tempest-concorde/fw-cicd) — Shared CI/CD workflows

## License

Apache License 2.0
