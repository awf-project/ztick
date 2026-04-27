.DEFAULT_GOAL := help
.PHONY: help build release install test test-functional test-all test-sanitize test-valgrind test-amqp test-redis fmt lint clean check compose-up compose-down

INSTALL_DIR ?= $(HOME)/.local/bin
INTEGRATION_FLAGS ?= -Damqp-integration -Dredis-integration

# Bring up brokers, run a zig build target with integration flags, always tear down.
# Usage: $(call run_with_compose,<zig-build-target>,<extra-flags>)
define run_with_compose
	docker compose up -d --wait rabbitmq redis
	zig build $(1) $(2) --summary all; status=$$?; \
		docker compose down rabbitmq redis; \
		exit $$status
endef

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the server binary (Debug)
	zig build --summary all

release: ## Build optimized binary (ReleaseSafe)
	zig build -Doptimize=ReleaseSafe --summary all

install: release ## Install optimized binary to $(INSTALL_DIR) (default: ~/.local/bin)
	@mkdir -p $(INSTALL_DIR)
	@install -m 755 zig-out/bin/ztick $(INSTALL_DIR)/ztick
	@echo "ztick installed to $(INSTALL_DIR)/ztick"
	@case ":$$PATH:" in \
		*":$(INSTALL_DIR):"*) ;; \
		*) echo "warning: $(INSTALL_DIR) is not in your PATH"; \
		   echo "  Add to your shell profile: export PATH=\"\$$PATH:$(INSTALL_DIR)\"" ;; \
	esac

compose-up: ## Start AMQP/Redis brokers for integration tests
	docker compose up -d --wait rabbitmq redis

compose-down: ## Stop AMQP/Redis brokers
	docker compose down rabbitmq redis

test: ## Run unit tests with integration brokers (boots docker, tears down on exit)
	$(call run_with_compose,test,$(INTEGRATION_FLAGS))

test-functional: ## Run functional tests with integration brokers (boots docker, tears down on exit)
	$(call run_with_compose,test-functional,$(INTEGRATION_FLAGS))

test-all: ## Run all unit and functional tests with integration brokers
	$(call run_with_compose,test-all,$(INTEGRATION_FLAGS))

test-sanitize: ## Run all tests with sanitizers and integration brokers
	$(call run_with_compose,test-sanitize,$(INTEGRATION_FLAGS))

test-valgrind: build ## Run binary under valgrind to detect memory leaks
	valgrind --leak-check=full --error-exitcode=1 zig-out/bin/ztick --help

test-amqp: ## Run AMQP integration tests against a real broker
	$(call run_with_compose,test-infrastructure,-Damqp-integration)

test-redis: ## Run Redis integration tests against a real broker
	$(call run_with_compose,test-infrastructure,-Dredis-integration)

fmt: ## Format source code
	zig fmt .

lint: ## Check formatting
	zig fmt --check .

check: lint test test-functional ## Run all checks (lint + unit + functional)

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache
