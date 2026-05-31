# fw-os - Flight Wall Operating System Layer

Application-specific bootc image layer for the Flight Wall project.

## Architecture

This is **Layer 3** in the Flight Wall bootc image stack:

```
Layer 3: fw-os (this repo)
  ↓ FROM
Layer 2: ghcr.io/tempest-concorde/fedora-bootc-pi (platform base)
  ↓ FROM
Layer 1: quay.io/hummingbird-community/bootc-os (Fedora Hummingbird)
```

## What This Layer Adds

On top of the fedora-bootc-pi platform base, fw-os adds:

- **GPIO/I2C packages** for LED matrix control (`python3-libgpiod`, `i2c-tools`)
- **Tailscale certificate automation** - daily renewal of TLS certs for HTTPS
- **fw-app quadlet** - systemd container unit for the Flight Wall application
- **Secret synchronization** - syncs podman secrets into fw-app environment

## Usage

### Building the Container Image

```bash
podman build --platform linux/arm64 -t ghcr.io/tempest-concorde/fw-os:latest .
```

### Creating Bootable Media

Use the separate `fw-site-config` repository (private) to build bootable ISOs/disk images with site-specific secrets.

## Components

### Containerfile

Inherits from `ghcr.io/tempest-concorde/fedora-bootc-pi:latest` and layers application-specific configuration.

### Quadlet Units

- `fw-app.container` - Main application container (rootless, UID 1000)
- `fw-app.image` - Pre-pull fw-app image for offline boot

### Scripts

- `tailscale-cert-renew.sh` - Fetches Tailscale TLS certificates
- `sync-fw-secrets.sh` - Syncs podman secrets to quadlet drop-ins

### Systemd Units

- `tailscale-cert-renew.service` - One-shot cert fetch
- `tailscale-cert-renew.timer` - Daily + on-boot trigger

## Development

### Local Testing

```bash
# Build the image
podman build -t fw-os:dev .

# Run bootc lint
podman run --rm fw-os:dev bootc container lint
```

### CI/CD

This repository uses reusable workflows from `tempest-concorde/fw-cicd`:

- **PR builds** - Build + test on ARM64 runner
- **Semantic release** - Conventional commits → version tags
- **Container release** - Build + sign + attest + push to GHCR
- **Cascade trigger** - Rebuilds on `fedora-bootc-pi` releases via `repository_dispatch`

## Hardware Compatibility

Tested on:
- Raspberry Pi 4 (8GB) - primary target
- Raspberry Pi 5 - compatible

## License

Apache License 2.0 - see [LICENSE](LICENSE)

## Related Repositories

- [fedora-bootc-pi](https://github.com/tempest-concorde/fedora-bootc-pi) - Platform base layer
- [fw-app](https://github.com/tempest-concorde/fw-app) - Flight Wall Go application
- [fw-cicd](https://github.com/tempest-concorde/fw-cicd) - Shared CI/CD workflows
