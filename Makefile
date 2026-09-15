# rana-deploy — orchestrates both rana roles from one place.
#
#   make server   Build & bring up the TOWER (localai + rana-socketd), follow logs
#                 (ctrl-c stops the stack and takes it down)
#   make client   Sync the agent dep + config, build & bring up the NOTEBOOK
#                 (rana-client-daemon + rana-voice-agent), follow logs
#                 (ctrl-c stops the stack and takes it down)
#   make down     Stop & remove every running rana service (both roles)
#   make ps       Show running containers for both roles
#   make logs     Follow logs for whatever is currently running (both roles)
#   make sync-client  Copy the sibling rana-socket client into the agent build ctx
#   make sync-config  Seed config/ from rana-socket templates (no .template); existing kept
#   make clean    Remove the copied client from the agent build context
#
# Config templates live in the sibling rana-socket/ repo as client.template.toml /
# server.template.toml. `make sync-config` (run automatically by `server`/`client`)
# seeds config/client.toml / config/server.toml the first time only — existing
# runtime configs are never overwritten. They are gitignored.

SERVER_COMPOSE := docker compose -f compose/docker-compose.server.yaml
CLIENT_COMPOSE := docker compose -f compose/docker-compose.client.yaml

# rana-socket client package copied into the agent build context (../rana-voice-agent)
# so the agent image can pip-install it (see rana-voice-agent/AGENTS.md).
RANA_SOCKET_CLIENT_SRC ?= ../rana-socket/client/py
RANA_SOCKET_CLIENT_DST := ../rana-voice-agent/vendors/rana-socket-client

# Host dir bind-mounted into both notebook containers as the shared UDS location
# (/run/rana). Created with uid 1000 so the non-root daemon/agent can use it.
RUN_SOCK_DIR := run/rana

.DEFAULT_GOAL := help

.PHONY: help server client down ps logs sync-client sync-config clean

help:
	@echo "rana-deploy — available targets:"
	@echo "  make server        Build & up the tower (localai + rana-socketd), follow logs"
	@echo "  make client        Sync agent dep + config, build & up the notebook, follow logs"
	@echo "  make down          Stop all running rana services"
	@echo "  make ps            Show running containers"
	@echo "  make logs          Follow logs for running services"
	@echo "  make sync-client   Copy the sibling rana-socket client into the agent build ctx"
	@echo "  make sync-config   Seed config/ from rana-socket templates (existing kept)"
	@echo "  make clean         Remove the copied client from the agent build ctx"

# Copy only the Python package (py/) into the agent build context, but only when
# its contents actually change. We hash every source file (not just a touch
# sentinel) so any edit to the vendored client forces a re-copy on the next build.
sync-client:
	@H=$$(find $(RANA_SOCKET_CLIENT_SRC) -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1); if [ ! -f $(RANA_SOCKET_CLIENT_DST)/.hash ] || [ "$$H" != "$$(cat $(RANA_SOCKET_CLIENT_DST)/.hash 2>/dev/null)" ]; then rm -rf $(RANA_SOCKET_CLIENT_DST); mkdir -p $(RANA_SOCKET_CLIENT_DST); cp -r $(RANA_SOCKET_CLIENT_SRC)/. $(RANA_SOCKET_CLIENT_DST)/; echo "$$H" > $(RANA_SOCKET_CLIENT_DST)/.hash; echo "rana-socket-client synced ($(RANA_SOCKET_CLIENT_SRC) -> $(RANA_SOCKET_CLIENT_DST))"; else echo "rana-socket-client up to date"; fi

# Seed the runtime configs from the rana-socket templates (sibling repo), stripping
# the .template suffix. Existing files are left untouched — to re-pull a default,
# delete the config first. Safe to run repeatedly.
sync-config:
	mkdir -p config
	[ -f config/client.toml ] || cp ../rana-socket/client.template.toml config/client.toml
	[ -f config/server.toml ] || cp ../rana-socket/server.template.toml config/server.toml
	@echo "rana-deploy: config/ seeded from rana-socket templates (existing configs kept)"

# server: ensure config, build + up the tower (detached), follow logs; ctrl-c takes it down.
server: sync-config
	$(SERVER_COMPOSE) up -d --build
	@trap '$(SERVER_COMPOSE) down; exit 130' INT TERM; $(SERVER_COMPOSE) logs -f

# client: ensure shared socket dir + agent dep + config, build + up the notebook
# (detached), follow logs; ctrl-c takes it down.
client: $(RUN_SOCK_DIR) sync-client sync-config
	$(CLIENT_COMPOSE) up -d --build
	@trap '$(CLIENT_COMPOSE) down; exit 130' INT TERM; $(CLIENT_COMPOSE) logs -f

$(RUN_SOCK_DIR):
	mkdir -p $(RUN_SOCK_DIR)
	chown 1000:1000 $(RUN_SOCK_DIR) 2>/dev/null || true

# --- individual controls (work on whatever is currently running) ---

down:
	-$(SERVER_COMPOSE) down
	-$(CLIENT_COMPOSE) down

ps:
	-$(SERVER_COMPOSE) ps
	-$(CLIENT_COMPOSE) ps

logs:
	-$(SERVER_COMPOSE) logs -f
	-$(CLIENT_COMPOSE) logs -f

clean:
	rm -rf $(RANA_SOCKET_CLIENT_DST)
