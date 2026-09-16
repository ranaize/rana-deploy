# rana-deploy — orchestrates both rana roles from one place.
#
# Architecture: the rana-socketd DAEMON (the "socket") runs NATIVELY on the host.
# It needs host resources — the browser/display, local light scripts, xdg-open —
# and reaches LocalAI over the host-published 8080. The SERVICES (LocalAI, the
# voice agent) run in docker compose. `make socket` builds the statically-linked
# daemon + its hop scripts from the sibling rana-socket image and installs them to
# /usr/local/bin; `make server` / `make client` bring up the compose services and
# launch the matching host daemon, following both logs. ctrl-c takes it all down.
#
#   make server   Build+install the socket, up LocalAI (docker), launch the tower
#                 daemon on the host, follow logs (ctrl-c stops everything)
#   make client   Sync agent dep + config, up the agent (docker), launch the
#                 notebook daemon on the host, follow logs (ctrl-c stops everything)
#   make socket   Build+install the rana-socketd runtime (binary + scripts) only
#   make down     Stop the host daemons AND the compose services (both roles)
#   make ps       Show running containers + host daemons (both roles)
#   make logs     Follow logs for whatever is running (daemons + compose)
#   make sync-client  Copy the sibling rana-socket client into the agent build ctx
#   make sync-config  Seed config/ from rana-socket templates (no .template); existing kept
#   make clean    Remove the copied client from the agent build context
#
# Config templates live in the sibling rana-socket/ repo under config/
# (client.template.toml / server.template.toml). `make sync-config` (run
# automatically by `server`/`client`) seeds config/client.toml / config/server.toml
# the first time only — existing runtime configs are never overwritten. Gitignored.

SERVER_COMPOSE := docker compose -f compose/docker-compose.server.yaml
CLIENT_COMPOSE := docker compose -f compose/docker-compose.client.yaml

# rana-socket sibling repo — build context for the rana-socketd docker image.
RANA_SOCKET_SRC ?= ../rana-socket
# Host install location for the daemon (runtime scripts land here too via predep).
SOCK_BIN := /usr/local/bin/rana-socketd

# rana-socket client package copied into the agent build context (../rana-voice-agent)
# so the agent image can pip-install it (see rana-voice-agent/AGENTS.md).
RANA_SOCKET_CLIENT_SRC ?= ../rana-socket/client/py
RANA_SOCKET_CLIENT_DST := ../rana-voice-agent/vendors/rana-socket-client

# Host dir bind-mounted into the agent container as the shared UDS location
# (/run/rana). The host daemon creates the socket here so the agent can reach it.
RUN_SOCK_DIR := run/rana

.DEFAULT_GOAL := help

.PHONY: help server client socket down ps logs sync-client sync-config gen-schema clean

help:
	@echo "rana-deploy — available targets:"
	@echo "  make server     Build+install socket, up LocalAI, launch tower daemon (host), follow logs"
	@echo "  make client     Sync agent dep + config, up agent, launch notebook daemon (host), follow logs"
	@echo "  make socket     Build+install the rana-socketd runtime (binary + hop scripts) only"
	@echo "  make down       Stop the host daemons AND all compose services"
	@echo "  make ps         Show running containers + host daemons"
	@echo "  make logs       Follow logs for running services + daemons"
	@echo "  make sync-client   Copy the sibling rana-socket client into the agent build ctx"
	@echo "  make gen-schema    Re-extract FlatBuffers python from the daemon image (schema lockstep)"
	@echo "  make sync-config   Seed config/ from rana-socket templates (existing kept)"
	@echo "  make clean         Remove the copied client from the agent build ctx"

# Copy only the Python package (py/) into the agent build context, but only when
# its contents actually change. We hash every source file (not just a touch
# sentinel) so any edit to the vendored client forces a re-copy on the next build.
# Depends on gen-schema so the regenerated FlatBuffers module is always present
# (never rely on a committed/stale copy).
sync-client: gen-schema
	@H=$$(find $(RANA_SOCKET_CLIENT_SRC) -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1); if [ ! -f $(RANA_SOCKET_CLIENT_DST)/.hash ] || [ "$$H" != "$$(cat $(RANA_SOCKET_CLIENT_DST)/.hash 2>/dev/null)" ]; then rm -rf $(RANA_SOCKET_CLIENT_DST); mkdir -p $(RANA_SOCKET_CLIENT_DST); cp -r $(RANA_SOCKET_CLIENT_SRC)/. $(RANA_SOCKET_CLIENT_DST)/; echo "$$H" > $(RANA_SOCKET_CLIENT_DST)/.hash; echo "rana-socket-client synced ($(RANA_SOCKET_CLIENT_SRC) -> $(RANA_SOCKET_CLIENT_DST))"; else echo "rana-socket-client up to date"; fi

# Seed the runtime configs from the rana-socket templates (sibling repo), stripping
# the .template suffix. Existing files are left untouched — to re-pull a default,
# delete the config first. Safe to run repeatedly.
sync-config:
	mkdir -p config
	[ -f config/client.toml ] || cp ../rana-socket/config/client.template.toml config/client.toml
	[ -f config/server.toml ] || cp ../rana-socket/config/server.template.toml config/server.toml
	@echo "rana-deploy: config/ seeded from rana-socket templates (existing configs kept)"

# Build + install the rana-socketd runtime onto the HOST via predep's install
# stage (defined in ../rana-socket/predep.toml). predep builds the bundle (docker)
# then copies the daemon binary, the serializer CLI, and the hop scripts into
# /usr/local/bin — auto-sudo'ing when needed and chown'ing the files to the
# invoking user so re-runs don't require root. The daemon configs already point
# at /usr/local/bin/*, so no path edits are needed.
socket:
	@echo "rana-deploy: installing rana-socketd runtime via predep (builds + auto-sudo to /usr/local/bin)…"
	cd $(RANA_SOCKET_SRC) && predep install
	@echo "rana-deploy: socket runtime installed -> $(SOCK_BIN) (+ serializer, hop scripts)"

# Re-extract the FlatBuffers Python module the daemon image regenerated from
# command.fbs, writing it over the agent client's vendored copy. We create a
# throwaway container from the built image and `docker cp` the file out (no
# `run`/console involved, which avoids the compose entrypoint-console bug).
gen-schema:
	@docker rm -f rana-schema-export >/dev/null 2>&1 || true
	@if ! docker create --name rana-schema-export rana-socketd >/dev/null 2>&1; then \
		docker build -t rana-socketd $(RANA_SOCKET_SRC) >/dev/null 2>&1 && \
		docker create --name rana-schema-export rana-socketd >/dev/null 2>&1; \
	fi
	docker cp rana-schema-export:/opt/rana/client_command_generated.py $(RANA_SOCKET_CLIENT_SRC)/rana_socket/command_generated.py
	docker rm -f rana-schema-export >/dev/null 2>&1 || true
	@echo "rana-deploy: client schema synced from rana-socketd image -> $(RANA_SOCKET_CLIENT_SRC)/rana_socket/command_generated.py"

# server: ensure config + socket, up LocalAI (docker), launch the tower daemon on
# the host, follow logs; ctrl-c stops the daemon + takes the compose stack down.
server: sync-config socket
	$(SERVER_COMPOSE) up -d --build
	@./scripts/rana-socketd-run.sh start server $(CURDIR)/config/server.toml http://127.0.0.1:8080
	@$(SERVER_COMPOSE) logs -f > run/socket/server.docker.log 2>&1 & LOGPID=$$!; trap 'kill $$LOGPID 2>/dev/null; $(SERVER_COMPOSE) down 2>/dev/null; ./scripts/rana-socketd-run.sh stop server; exit 0' INT TERM; echo "following logs (ctrl-c stops the stack): daemon -> run/socket/server.log"; tail -f run/socket/server.log run/socket/server.docker.log 2>/dev/null

# client: sync agent dep + config, up the agent (docker), launch the notebook
# daemon on the host, follow logs; ctrl-c stops the daemon + takes the stack down.
#
# gen-schema (pulled in via sync-client's dependency) extracts the FlatBuffers
# Python module the daemon build regenerated from command.fbs, so the agent ships
# the exact schema the daemon compiled against — keeping union ordinals / status
# codes in lockstep.
client: $(RUN_SOCK_DIR) socket sync-client sync-config
	$(CLIENT_COMPOSE) up -d --build
	@./scripts/rana-socketd-run.sh start client $(CURDIR)/config/client.toml
	@$(CLIENT_COMPOSE) logs -f > run/socket/client.docker.log 2>&1 & LOGPID=$$!; trap 'kill $$LOGPID 2>/dev/null; $(CLIENT_COMPOSE) down 2>/dev/null; ./scripts/rana-socketd-run.sh stop client; exit 0' INT TERM; echo "following logs (ctrl-c stops the stack): daemon -> run/socket/client.log"; tail -f run/socket/client.log run/socket/client.docker.log 2>/dev/null

$(RUN_SOCK_DIR):
	mkdir -p $(RUN_SOCK_DIR)
	chown 1000:1000 $(RUN_SOCK_DIR) 2>/dev/null || true

# --- individual controls (work on whatever is currently running) ---

down:
	-$(SERVER_COMPOSE) down
	-$(CLIENT_COMPOSE) down
	@./scripts/rana-socketd-run.sh stop server
	@./scripts/rana-socketd-run.sh stop client

ps:
	-$(SERVER_COMPOSE) ps
	-$(CLIENT_COMPOSE) ps
	@./scripts/rana-socketd-run.sh status

logs:
	@$(SERVER_COMPOSE) logs -f > run/socket/server.docker.log 2>&1 & SPID=$$!; $(CLIENT_COMPOSE) logs -f > run/socket/client.docker.log 2>&1 & CPID=$$!; trap 'kill $$SPID $$CPID 2>/dev/null; exit 0' INT TERM; tail -f run/socket/server.log run/socket/client.log run/socket/server.docker.log run/socket/client.docker.log 2>/dev/null

clean:
	rm -rf $(RANA_SOCKET_CLIENT_DST)
