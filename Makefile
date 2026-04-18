SHELL := /bin/bash
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)
COMPOSE := HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) docker compose
DATA_DIRS := data data/grafana data/loki data/tempo data/mimir data/alloy

.PHONY: help init check up down restart logs smoke load clean reset-data

help:
	@printf "%s\n" \
	  "Targets:" \
	  "  make init        Create local data directories" \
	  "  make check       Validate compose config and Python imports" \
	  "  make up          Build and start the stack" \
	  "  make down        Stop the stack" \
	  "  make restart     Restart the stack" \
	  "  make logs        Tail compose logs" \
	  "  make smoke       Run the end-to-end smoke test" \
	  "  make load        Start the optional load generator" \
	  "  make clean       Stop the stack and remove containers/volumes" \
	  "  make reset-data  Remove bind-mounted local data"

init:
	mkdir -p $(DATA_DIRS)
	touch data/.gitkeep

check: init
	$(COMPOSE) config >/dev/null
	python3 -m compileall app >/dev/null

up: init
	$(COMPOSE) up --build -d

down:
	$(COMPOSE) down

restart: down up

logs:
	$(COMPOSE) logs -f --tail=200

smoke:
	./scripts/smoke.sh

load:
	./scripts/generate-load.sh

clean:
	$(COMPOSE) down -v --remove-orphans

reset-data:
	docker run --rm -v "$(CURDIR)/data:/data" busybox sh -c 'find /data -mindepth 1 -delete'
	mkdir -p $(DATA_DIRS)
	touch data/.gitkeep
