SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DELETE_ON_ERROR:

include versions.mk

CONTAINER_ENGINE ?= podman
IMAGE            ?= rust-dev
CONTEXT          := image
CONTAINERFILE    := $(CONTEXT)/Containerfile

GIT_REVISION := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)
BUILD_DATE   := $(shell date -u '+%Y-%m-%dT%H:%M:%SZ')

CLAUDE_RELEASES_URL := https://downloads.claude.ai/claude-code-releases

# Linter images, pinned by digest; the tag is for the reader.
HADOLINT_IMAGE   := docker.io/hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d
SHELLCHECK_IMAGE := docker.io/koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d

.PHONY: help check image info lint update vendor vendor-check vendor-check-drift

.DEFAULT_GOAL := help

##@ Help

help: ## List available targets
	@awk 'BEGIN { FS = ":.*?## " } /^##@ / { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } /^[a-zA-Z0-9_.-]+:.*?## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Main

check: image ## Build the image, then smoke test it
	@$(CONTAINER_ENGINE) run --rm \
	  -v /var/cache/rust-dev \
	  -e RUST_FMT_TOOLCHAIN="$(RUST_FMT_TOOLCHAIN)" \
	  -v "$(CURDIR)/scripts/smoke-test.sh:/smoke-test.sh:ro" \
	  $(IMAGE):$(GIT_REVISION) /smoke-test.sh

image: lint ## Build the image
	@scripts/vendor.sh fetch
	@claude=$$(curl -fsSL "$(CLAUDE_RELEASES_URL)/latest"); \
	  [ -n "$$claude" ] || { echo "failed to resolve claude-code version" >&2; exit 1; }; \
	  echo "building $(IMAGE):$(GIT_REVISION): claude-code=$$claude"; \
	  $(CONTAINER_ENGINE) build -f $(CONTAINERFILE) \
	    --pull=newer \
	    --build-arg BUILD_DATE="$(BUILD_DATE)" \
	    --build-arg CARGO_BLOAT_VERSION="$(CARGO_BLOAT_VERSION)" \
	    --build-arg CARGO_DENY_VERSION="$(CARGO_DENY_VERSION)" \
	    --build-arg CARGO_LLVM_LINES_VERSION="$(CARGO_LLVM_LINES_VERSION)" \
	    --build-arg CARGO_MACHETE_VERSION="$(CARGO_MACHETE_VERSION)" \
	    --build-arg CARGO_NEXTEST_VERSION="$(CARGO_NEXTEST_VERSION)" \
	    --build-arg CLAUDE_VERSION="$$claude" \
	    --build-arg DPRINT_VERSION="$(DPRINT_VERSION)" \
	    --build-arg GIT_REVISION="$(GIT_REVISION)" \
	    --build-arg RUSTFILT_VERSION="$(RUSTFILT_VERSION)" \
	    --build-arg RUST_FMT_TOOLCHAIN="$(RUST_FMT_TOOLCHAIN)" \
	    -t $(IMAGE):$(GIT_REVISION) \
	    -t $(IMAGE):latest $(CONTEXT)

info: ## Show the image's build timestamp and provenance labels
	@$(CONTAINER_ENGINE) image inspect --format 'created: {{.Created}}' $(IMAGE):$(GIT_REVISION)
	@$(CONTAINER_ENGINE) image inspect \
	  --format '{{range $$k, $$v := .Config.Labels}}{{$$k}}={{$$v}}{{"\n"}}{{end}}' \
	  $(IMAGE):$(GIT_REVISION) | sort

lint: ## Lint the Containerfile, shell scripts and YAML
	@$(CONTAINER_ENGINE) run --rm -i -v "$(CURDIR)/.hadolint.yaml:/.hadolint.yaml:ro" \
	  $(HADOLINT_IMAGE) hadolint --config /.hadolint.yaml - < $(CONTAINERFILE)
	@$(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/mnt:ro" -w /mnt \
	  $(SHELLCHECK_IMAGE) scripts/*.sh image/rust-dev-entrypoint
	@yamllint .
	@for f in scripts/*.sh image/rust-dev-entrypoint; do \
	   [ -x "$$f" ] || { echo "$$f is not executable" >&2; exit 1; }; \
	 done
	@# Syntax check only: RUST_CACHE_KEY short-circuits rust-dev's cargo call.
	@$(MAKE) --no-print-directory -f $(CONTEXT)/rust-dev \
	  RUST_CACHE_KEY=parse-check CARGO_TARGET_BASE=/nonexistent -n check >/dev/null
	@echo "lint ok"

##@ More

vendor: ## Fetch any missing or invalid vendored file, and update the manifest
	@scripts/vendor.sh fetch

vendor-check: ## Verify vendored files against the manifest
	@scripts/vendor.sh check

vendor-check-drift: ## Re-fetch every vendored file from upstream and verify it against the manifest
	@scripts/vendor.sh force-fetch

update: ## Apply newer upstream releases to versions.mk and the manifest
	@scripts/update-crates.sh update
	@scripts/vendor.sh update
