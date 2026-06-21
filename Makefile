SHELL := /bin/bash

REGISTRY ?= ghcr.io/tempest-concorde
IMAGE_NAME ?= fw-os
TAG ?= latest
FULL_IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(TAG)

SSH_KEY_PATH ?= $(HOME)/.ssh/id_rsa.pub
DOCKER_AUTH_PATH ?= $(PWD)/docker-auth.json

TAILSCALE_AUTH_KEY ?=
WIFI_SSID_1 ?=
WIFI_PSK_1 ?=
WIFI_SSID_2 ?=
WIFI_PSK_2 ?=

BIB_IMAGE := quay.io/centos-bootc/bootc-image-builder:latest

.PHONY: help deps toml check-env iso raw-image qcow container test-local clean show-config

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deps: ## Install gomplate for config templating
	@command -v gomplate >/dev/null 2>&1 || \
		(echo "Installing gomplate..." && go install github.com/hairyhenderson/gomplate/v3/cmd/gomplate@latest)

toml: deps ## Generate config.toml from template with current env vars
	@echo "Generating config.toml..."
	@SSH_KEY_PATH="$(SSH_KEY_PATH)" \
	 DOCKER_AUTH_PATH="$(DOCKER_AUTH_PATH)" \
	 TAILSCALE_AUTH_KEY="$(TAILSCALE_AUTH_KEY)" \
	 WIFI_SSID_1="$(WIFI_SSID_1)" \
	 WIFI_PSK_1="$(WIFI_PSK_1)" \
	 WIFI_SSID_2="$(WIFI_SSID_2)" \
	 WIFI_PSK_2="$(WIFI_PSK_2)" \
	 gomplate -f config.toml.tmpl -o config.toml
	@echo "config.toml generated"

check-env: ## Validate required files and credentials
	@echo "Checking environment..."
	@test -f "$(SSH_KEY_PATH)" || (echo "ERROR: SSH key not found: $(SSH_KEY_PATH)" && exit 1)
	@test -f "$(DOCKER_AUTH_PATH)" || (echo "ERROR: Docker auth not found: $(DOCKER_AUTH_PATH)" && exit 1)
	@test -n "$(WIFI_SSID_1)" || (echo "ERROR: WIFI_SSID_1 not set" && exit 1)
	@test -n "$(WIFI_PSK_1)" || (echo "ERROR: WIFI_PSK_1 not set" && exit 1)
	@echo "Environment OK"

iso: toml check-env ## Build bootable ISO for SD card install
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
		$(FULL_IMAGE)
	@echo "ISO written to output/"

raw-image: toml check-env ## Build raw disk image for direct SD card flash
	@echo "Building raw disk image from $(FULL_IMAGE)..."
	@rm -rf output && mkdir -p output
	@podman run \
		--rm -it --privileged \
		--security-opt label=type:unconfined_t \
		-v $(CURDIR)/config.toml:/config.toml:ro \
		-v $(CURDIR)/output:/output \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		$(BIB_IMAGE) \
		--type raw \
		$(FULL_IMAGE)
	@echo "Raw image written to output/"

qcow: toml check-env ## Build QCOW2 image for VM testing
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
		$(FULL_IMAGE)
	@echo "QCOW2 written to output/"

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
	@echo "Docker auth: $(DOCKER_AUTH_PATH)"
	@echo "WiFi SSID:  $(WIFI_SSID_1)"
	@echo "WiFi SSID2: $(WIFI_SSID_2)"
	@echo "Tailscale:  $(if $(TAILSCALE_AUTH_KEY),set,not set)"
