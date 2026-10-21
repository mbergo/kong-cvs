# Kong AI Gateway (Konnect data plane). Run `make help`.
SHELL := /bin/bash
include config.env
export

SUDO ?= sudo
DOCKER := $(SUDO) docker

.DEFAULT_GOAL := help
.PHONY: help up down restart status logs check clean-stale metrics prometheus-plugin alloy-up alloy-down alloy-logs traffic traffic-stop traffic-logs cloud cloud-diff dashboards

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

metrics: ## Show the first Kong metrics lines (needs step 02)
	@curl -s http://127.0.0.1:$(KONG_STATUS_PORT)/metrics | grep -v '^#' | head -20

prometheus-plugin: ## Step 02: enable the global Prometheus plugin in Konnect
	scripts/02-enable-prometheus-plugin.sh

alloy-up: ## Step 03: ship metrics to Grafana Cloud with Alloy
	$(SUDO) scripts/03-run-alloy.sh

alloy-down: ## Remove the Alloy container
	-$(DOCKER) rm -f $(GRAFANA_ALLOY_CONTAINER_NAME)

alloy-logs: ## Follow Alloy logs
	$(DOCKER) logs -f --tail 100 $(GRAFANA_ALLOY_CONTAINER_NAME)

traffic: ## Step 10: start continuous mixed traffic against the Kong Cloud route
	-$(DOCKER) rm -f kong-traffic >/dev/null 2>&1
	$(DOCKER) run -d --name kong-traffic --restart unless-stopped --env-file secrets/tester.env --env-file secrets/demo-consumers.env \
	  -v $(CURDIR)/scripts/10-traffic-gen.sh:/gen.sh:ro --entrypoint sh curlimages/curl /gen.sh

traffic-stop: ## Stop the traffic generator
	-$(DOCKER) rm -f kong-traffic

traffic-logs: ## Generator container status
	@$(DOCKER) ps -a --filter name=kong-traffic --format '{{.Names}} {{.Status}}'

cloud: ## From zero: decK sync kong/kong-cloud.yaml to Kong Cloud + smoke test + traffic
	scripts/00-bootstrap-cloud.sh

cloud-diff: ## Show what decK would change in Kong Cloud
	@set -a; . secrets/konnect.env; . secrets/grafana-otlp.env; . secrets/demo-consumers.env; set +a; \
	DECK_OTLP_AUTH="$$GRAFANA_OTLP_AUTH_HEADER" DECK_KEY_MOBILE_APP="$$KEY_MOBILE_APP" DECK_KEY_WEB_APP="$$KEY_WEB_APP" \
	DECK_KEY_PARTNER_ACME="$$KEY_PARTNER_ACME" DECK_KEY_INTERNAL_BATCH="$$KEY_INTERNAL_BATCH" \
	deck gateway diff --konnect-token "$$KONNECT_TOKEN" --konnect-addr $(KONNECT_API) kong/kong-cloud.yaml

dashboards: ## Step 12: publish dashboards to Grafana (+7424) and print the public link
	scripts/12-dashboards.sh
