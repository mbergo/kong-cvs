# Kong AI Gateway (Konnect data plane). Run `make help`.
SHELL := /bin/bash
include config.env
export

SUDO ?= sudo
DOCKER := $(SUDO) docker

.DEFAULT_GOAL := help
.PHONY: help up down restart status logs check clean-stale

help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

up: ## Step 01: start (or replace) the data plane and wait for Konnect
	$(SUDO) scripts/01-run-dataplane.sh

down: ## Stop and remove the data plane container
	-$(DOCKER) rm -f $(KONG_CONTAINER_NAME)

restart: ## Restart the data plane container
	$(DOCKER) restart $(KONG_CONTAINER_NAME)

status: ## Show container state and ports
	@$(DOCKER) ps -a --filter name=^/$(KONG_CONTAINER_NAME)$$ --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

logs: ## Follow data plane logs
	$(DOCKER) logs -f --tail 100 $(KONG_CONTAINER_NAME)

check: ## Konnect connection + proxy reachability
	@$(DOCKER) logs $(KONG_CONTAINER_NAME) 2>&1 | grep -q 'sync v2 is enabled in CP' && echo "konnect: connected" || echo "konnect: NOT connected"
	@echo "proxy :$(KONG_PROXY_PORT) -> HTTP $$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$(KONG_PROXY_PORT)/) (404 = up, no routes yet)"

clean-stale: ## Remove never-started containers of the Kong image
	@ids=$$($(DOCKER) ps -aq --filter status=created --filter ancestor=$(KONG_IMAGE)); \
	if [ -n "$$ids" ]; then $(DOCKER) rm $$ids; else echo "nothing to clean"; fi
