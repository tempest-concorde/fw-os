SHELL := /bin/bash

REGISTRY ?= ghcr.io/tempest-concorde
IMAGE_NAME ?= fw-os
TAG ?= latest
FULL_IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(TAG)

# Fedora IoT base image for arm-image-installer
FEDORA_IOT_IMAGE ?= Fedora-IoT-42-20250422.0.aarch64.raw.xz
FEDORA_IOT_URL ?= https://download.fedoraproject.org/pub/alt/iot/42/IoT/aarch64/images/$(FEDORA_IOT_IMAGE)

SSH_KEY_PATH ?= $(HOME)/.ssh/id_rsa.pub
SD_CARD ?=

TAILSCALE_AUTH_KEY ?=
WIFI_SSID ?=
WIFI_PSK ?=

BIB_IMAGE := quay.io/centos-bootc/bootc-image-builder:latest

.PHONY: help download flash bootc-switch wifi tailscale deploy \
        iso qcow container test-local clean show-config

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# =============================================================================
# Primary deployment path: Fedora IoT → bootc switch
# =============================================================================

download: ## Download Fedora IoT raw image
	@test -f "$(FEDORA_IOT_IMAGE)" && echo "Image already downloaded" || \
		(echo "Downloading $(FEDORA_IOT_IMAGE)..." && curl -LO "$(FEDORA_IOT_URL)")

flash: download ## Flash Fedora IoT to SD card (requires SD_CARD=/dev/sdX)
	@test -n "$(SD_CARD)" || (echo "ERROR: Set SD_CARD=/dev/sdX (e.g. /dev/mmcblk0)" && exit 1)
	@test -f "$(SSH_KEY_PATH)" || (echo "ERROR: SSH key not found: $(SSH_KEY_PATH)" && exit 1)
	@echo "Flashing $(FEDORA_IOT_IMAGE) to $(SD_CARD)..."
	@echo "WARNING: This will erase all data on $(SD_CARD)"
	sudo arm-image-installer \
		--image=$(FEDORA_IOT_IMAGE) \
		--media=$(SD_CARD) \
		--addkey=$(SSH_KEY_PATH) \
		--norootpass \
		--resizefs \
		--target=rpi4 \
		-y
	@echo "Flash complete. Insert SD card into RPi4 and boot."

bootc-switch: ## Switch running Fedora IoT to fw-os (run ON the RPi4 via SSH)
	@echo "Switching to $(FULL_IMAGE)..."
	bootc switch --enforce-container-sigpolicy $(FULL_IMAGE)
	@echo "Switch staged. Reboot to apply: systemctl reboot"

wifi: ## Configure WiFi on the RPi4 (run ON the RPi4 via SSH)
	@test -n "$(WIFI_SSID)" || (echo "ERROR: Set WIFI_SSID" && exit 1)
	@test -n "$(WIFI_PSK)" || (echo "ERROR: Set WIFI_PSK" && exit 1)
	nmcli device wifi connect "$(WIFI_SSID)" password "$(WIFI_PSK)"
	@echo "Connected to $(WIFI_SSID)"

tailscale: ## Join Tailscale network (run ON the RPi4 via SSH)
	@test -n "$(TAILSCALE_AUTH_KEY)" || (echo "ERROR: Set TAILSCALE_AUTH_KEY" && exit 1)
	sudo systemctl enable --now tailscaled
	sudo tailscale up --authkey="$(TAILSCALE_AUTH_KEY)" --ssh --accept-routes
	@echo "Joined Tailscale network"

deploy: flash ## Full deploy guide (prints next steps after flash)
	@echo ""
	@echo "=== Next steps ==="
	@echo "1. Insert SD card into RPi4, connect ethernet, boot"
	@echo "2. Find RPi4 IP: nmap -sn 192.168.1.0/24 | grep -B2 'Raspberry'"
	@echo "3. SSH in:  ssh root@<ip>"
	@echo "4. WiFi:    nmcli device wifi connect <SSID> password <PSK>"
	@echo "5. Switch:  bootc switch $(FULL_IMAGE)"
	@echo "6. Reboot:  systemctl reboot"
	@echo "7. Tailscale (after reboot): tailscale up --authkey=<key> --ssh"

# =============================================================================
# ISO path (for VM testing or installer-based deploys)
# =============================================================================

deps: ## Install gomplate for config templating
	@command -v gomplate >/dev/null 2>&1 || \
		(echo "Installing gomplate..." && go install github.com/hairyhenderson/gomplate/v3/cmd/gomplate@latest)

toml: deps ## Generate config.toml from template
	@echo "Generating config.toml..."
	@SSH_KEY_PATH="$(SSH_KEY_PATH)" \
	 TAILSCALE_AUTH_KEY="$(TAILSCALE_AUTH_KEY)" \
	 WIFI_SSID_1="$(WIFI_SSID)" \
	 WIFI_PSK_1="$(WIFI_PSK)" \
	 gomplate -f config.toml.tmpl -o config.toml
	@echo "config.toml generated"

iso: toml ## Build bootable ISO (for VM testing)
	@echo "Building ISO from $(FULL_IMAGE)..."
	@rm -rf output && mkdir -p output
	@podman run \
		--rm -it --privileged \
		--security-opt label=type:unconfined_t \
		-v $(CURDIR)/config.toml:/config.toml:ro \
		-v $(CURDIR)/output:/output \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		$(BIB_IMAGE) \
		--type iso \
		--rootfs ext4 \
		$(FULL_IMAGE)
	@echo "ISO written to output/"

qcow: toml ## Build QCOW2 image (for VM testing)
	@echo "Building QCOW2 from $(FULL_IMAGE)..."
	@rm -rf output && mkdir -p output
	@podman run \
		--rm -it --privileged \
		--security-opt label=type:unconfined_t \
		-v $(CURDIR)/config.toml:/config.toml:ro \
		-v $(CURDIR)/output:/output \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		$(BIB_IMAGE) \
		--local \
		--type qcow2 \
		--rootfs ext4 \
		$(FULL_IMAGE)
	@echo "QCOW2 written to output/"

# =============================================================================
# Development
# =============================================================================

container: ## Build the container image locally
	@echo "Building $(FULL_IMAGE)..."
	@podman build --platform=linux/arm64 -t $(FULL_IMAGE) .

test-local: container ## Run container interactively for inspection
	@podman run --rm -it --platform=linux/arm64 $(FULL_IMAGE) /bin/bash

clean: ## Remove build artifacts
	@rm -rf output/ config.toml
	@podman rmi $(FULL_IMAGE) 2>/dev/null || true

show-config: ## Show current build configuration
	@echo "Image:      $(FULL_IMAGE)"
	@echo "SSH key:    $(SSH_KEY_PATH)"
	@echo "SD card:    $(SD_CARD)"
	@echo "WiFi SSID:  $(WIFI_SSID)"
	@echo "Tailscale:  $(if $(TAILSCALE_AUTH_KEY),set,not set)"
