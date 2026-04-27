.DEFAULT_GOAL := help
.PHONY: help build release install test test-functional test-all test-sanitize test-valgrind test-amqp test-redis fmt lint clean check

INSTALL_DIR ?= $(HOME)/.local/bin

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

test: ## Run unit tests
	zig build test --summary all

test-functional: ## Run functional tests
	zig build test-functional --summary all

test-all: ## Run all unit and functional tests
	zig build test-all --summary all

test-sanitize: ## Run all tests with sanitizers enabled
	zig build test-sanitize --summary all

test-valgrind: build ## Run binary under valgrind to detect memory leaks
	valgrind --leak-check=full --error-exitcode=1 zig-out/bin/ztick --help

test-amqp: ## Run AMQP integration tests against a real broker
	docker compose up -d --wait
	zig build test-infrastructure -Damqp-integration --summary all; status=$$?; \
		docker compose down; \
		exit $$status

test-redis: ## Run Redis integration tests against a real broker
	docker compose up -d --wait
	zig build test-functional -Dredis-integration --summary all; status=$$?; \
		docker compose down; \
		exit $$status

fmt: ## Format source code
	zig fmt .

lint: ## Check formatting
	zig fmt --check .

check: lint test test-functional ## Run all checks (lint + unit + functional)

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache
