# rana-deploy — orchestrates both rana roles from one place.
#
# Architecture: the rana-socketd DAEMON (the "socket") runs NATIVELY on the host.
# It needs host resources — the browser/display, local light scripts, xdg-open —
# and reaches LocalAI over the host-published 8080. The SERVICES (LocalAI, the
# voice agent) run in docker compose. `make socket` builds the statically-linked
# daemon + its hop scripts from the sibling rana-socket repo IN-PLACE (never
# installs to /usr/local/bin — `predep` builds only); `make server` / `make client`
# bring up the compose services and launch the matching host daemon from the build
# folder, following both logs. ctrl-c takes it all down.
#
#   make server   Build the socket in-place, up LocalAI (docker), launch the tower
#                 daemon on the host, follow logs (ctrl-c stops everything)
#   make client   Sync agent dep + config, up the agent (docker), launch the
#                 notebook daemon on the host, follow logs (ctrl-c stops everything)
#   make socket   Build the rana-socketd runtime in-place (predep build; no install)
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

# Compose images are NOT rebuilt on every `up` by default — only containers are
# recreated if their image/config changed. Set BUILD=1 to force an image rebuild
# (e.g. after editing the agent/Dockerfile), or use `make build` / `make rebuild`.
UP_FLAGS ?= -d

# rana-socket sibling repo — build context for the rana-socketd docker image.
# `?=` would be overridden by an empty env var (`export RANA_SOCKET_SRC=`), so use
# $(or ...) to fall back to the default whenever the value is empty/undefined.
# These must be defined BEFORE GEN_FBS/GEN_PY below, since those use `:=` (immediate
# expansion) and would otherwise capture the empty pre-default value.
RANA_SOCKET_SRC := $(or $(RANA_SOCKET_SRC),../rana-socket)
# rana-socket client package copied into the agent build context (../rana-voice-agent)
# so the agent image can pip-install it (see rana-voice-agent/AGENTS.md).
RANA_SOCKET_CLIENT_SRC := $(or $(RANA_SOCKET_CLIENT_SRC),../rana-socket/client/py)
RANA_SOCKET_CLIENT_DST := ../rana-voice-agent/vendors/rana-socket-client

# The daemon is built in-place (predep builds, never installs), so SOCK_BIN points
# at the build-folder binary. The launch scripts are copied next to it by `socket`.
SOCK_BIN := $(abspath $(RANA_SOCKET_SRC)/socket/bin/Release/rana-socketd)
# Source-of-truth locations used by the schema-sync guard below.
GEN_FBS := $(RANA_SOCKET_SRC)/schema/command.fbs
GEN_PY  := $(RANA_SOCKET_CLIENT_SRC)/rana_socket/command_generated.py

# Host dir bind-mounted into the agent container as the shared UDS location
# (/run/rana). The host daemon creates the socket here so the agent can reach it.
RUN_SOCK_DIR := run/rana

.DEFAULT_GOAL := help

.PHONY: help server client socket build rebuild down ps logs sync-client sync-config gen-schema clean

help:
	@echo "rana-deploy — available targets:"
	@echo "  make server     Build+install socket, up LocalAI (reuse images), launch tower daemon (host), follow logs"
	@echo "  make client     Sync agent dep + config, up agent (reuse images), launch notebook daemon (host), follow logs"
	@echo "  make socket     Build the rana-socketd runtime (install if predep on PATH, else in-place)"
	@echo "  make build      (Re)build compose images only (use after editing the agent/Dockerfile)"
	@echo "  make rebuild    Force a clean no-cache rebuild of compose images"
	@echo "  make down       Stop the host daemons AND all compose services"
	@echo "  make ps         Show running containers + host daemons"
	@echo "  make logs       Follow logs for running services + daemons"
	@echo "  make sync-client   Copy the sibling rana-socket client into the agent build ctx"
	@echo "  make gen-schema    Re-extract FlatBuffers python from the daemon image (skips if up to date)"
	@echo "  make sync-config   Seed config/ from rana-socket templates (existing kept)"
	@echo "  make clean         Remove the copied client from the agent build ctx"
	@echo "  note: pass BUILD=1 to server/client to force a compose image rebuild (default reuses images)"

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

# Build the rana-socketd runtime. Two paths, depending on whether `predep` is
# reachable:
#   - predep on PATH        -> `predep install` builds + installs the daemon, the
#                              serializer CLI, and the hop scripts to /usr/local/bin
#                              (auto-sudo'ing + chown'ing as needed). The daemon
#                              configs already point at /usr/local/bin/*, so no path
#                              edits are required.
#   - predep NOT on PATH    -> build in-place via a local predep (./predep inside
#                              the rana-socket dir) and run from the build folder.
#                              Nothing is installed. The hop scripts are copied next
#                              to the built binary so a build-folder daemon works
#                              out of the box; launch it with RANA_SOCK_BIN set
#                              (see the printed line). The daemon configs still point
#                              at /usr/local/bin/*, so for full local operation copy
#                              them and rewrite the script paths to the build folder.
# Build the rana-socketd runtime in-place — never `predep install` (no /usr/local/bin
# writes). Two paths, both gated on whether `predep` is reachable:
#   - predep on PATH   -> `predep` builds the daemon/serializer into
#                         socket/bin/Release/ (and we copy the hop scripts alongside).
#   - predep NOT on PATH -> `./predep build` in-place; same build-folder result.
# The daemon is then launched from that build folder (see SOCK_BIN / server / client).
socket:
	@cd $(RANA_SOCKET_SRC); \
	if command -v predep >/dev/null 2>&1; then \
		echo "rana-deploy: predep on PATH — building rana-socketd in-place (no install)…"; \
		predep || { echo "rana-deploy: ERROR: predep build failed"; exit 1; }; \
	else \
		if [ ! -x ./predep ]; then \
			echo "error: predep not on PATH and no ./predep in $(RANA_SOCKET_SRC)" >&2; \
			echo "       install predep (see README) or drop the predep binary into $(RANA_SOCKET_SRC)" >&2; \
			exit 1; \
		fi; \
		echo "rana-deploy: predep not on PATH — building in-place (no install)…"; \
		./predep build || { echo "rana-deploy: ERROR: in-place predep build failed"; exit 1; }; \
	fi; \
	cp -f scripts/rana-*.sh scripts/*.py serializer/bin/Release/rana-serializer socket/bin/Release/ 2>/dev/null || true; \
	chmod +x socket/bin/Release/rana-*.sh socket/bin/Release/*.py socket/bin/Release/rana-serializer 2>/dev/null || true; \
	SOCK=$$(pwd)/socket/bin/Release/rana-socketd; \
	echo "rana-deploy: built -> $$SOCK"; \
	echo "rana-deploy: launch with: RANA_SOCK_BIN=$$SOCK $(CURDIR)/scripts/rana-socketd-run.sh start <role> <config>"

# Re-extract the FlatBuffers Python module the daemon image regenerated from
# command.fbs, writing it over the agent client's vendored copy. We create a
# throwaway container from the built image and `docker cp` the file out (no
# `run`/console involved, which avoids the compose entrypoint-console bug).
# Skip entirely when the extracted module is already newer than command.fbs, so a
# `make client` no longer triggers a docker extraction (or a daemon-image build)
# on every invocation.
gen-schema:
	@if [ -f $(GEN_PY) ] && [ ! "$(GEN_FBS)" -nt "$(GEN_PY)" ]; then \
		echo "rana-deploy: client schema up to date ($(GEN_PY)) — skipping docker extraction"; \
	else \
		docker rm -f rana-schema-export >/dev/null 2>&1 || true; \
		if ! docker create --name rana-schema-export rana-socketd >/dev/null 2>&1; then \
			docker build -t rana-socketd $(RANA_SOCKET_SRC) || { echo "rana-deploy: ERROR: rana-socketd image build failed"; exit 1; }; \
			docker create --name rana-schema-export rana-socketd || { echo "rana-deploy: ERROR: could not create schema-export container"; exit 1; }; \
		fi; \
		mkdir -p $(dir $(GEN_PY)); \
		docker cp rana-schema-export:/opt/rana/client_command_generated.py $(GEN_PY) || { echo "rana-deploy: ERROR: schema export (docker cp) failed"; exit 1; }; \
		docker rm -f rana-schema-export >/dev/null 2>&1 || true; \
		echo "rana-deploy: client schema synced from rana-socketd image -> $(GEN_PY)"; \
	fi

# server: ensure config + socket, up LocalAI (docker), launch the tower daemon on
# the host, follow logs; ctrl-c stops the daemon + takes the compose stack down.
server: sync-config socket
	$(SERVER_COMPOSE) up $(UP_FLAGS) || { echo "rana-deploy: ERROR: server compose up failed"; exit 1; }
	@RANA_SOCK_BIN=$(SOCK_BIN) ./scripts/rana-socketd-run.sh start server $(CURDIR)/config/server.toml http://127.0.0.1:8080
	@$(SERVER_COMPOSE) logs -f > run/socket/server.docker.log 2>&1 & LOGPID=$$!; trap 'kill $$LOGPID 2>/dev/null; $(SERVER_COMPOSE) down 2>/dev/null; ./scripts/rana-socketd-run.sh stop server; exit 0' INT TERM; echo "following logs (ctrl-c stops the stack): daemon -> run/socket/server.log"; tail -f run/socket/server.log run/socket/server.docker.log 2>/dev/null

# client: sync agent dep + config, up the agent (docker), launch the notebook
# daemon on the host, follow logs; ctrl-c stops the daemon + takes the stack down.
#
# gen-schema (pulled in via sync-client's dependency) extracts the FlatBuffers
# Python module the daemon build regenerated from command.fbs, so the agent ships
# the exact schema the daemon compiled against — keeping union ordinals / status
# codes in lockstep.
client: $(RUN_SOCK_DIR) socket sync-client sync-config
	$(CLIENT_COMPOSE) up $(UP_FLAGS) || { echo "rana-deploy: ERROR: client compose up failed"; exit 1; }
	@RANA_SOCK_BIN=$(SOCK_BIN) ./scripts/rana-socketd-run.sh start client $(CURDIR)/config/client.toml
	@$(CLIENT_COMPOSE) logs -f > run/socket/client.docker.log 2>&1 & LOGPID=$$!; trap 'kill $$LOGPID 2>/dev/null; $(CLIENT_COMPOSE) down 2>/dev/null; ./scripts/rana-socketd-run.sh stop client; exit 0' INT TERM; echo "following logs (ctrl-c stops the stack): daemon -> run/socket/client.log"; tail -f run/socket/client.log run/socket/client.docker.log 2>/dev/null

# Explicit image builds (only when you actually changed an image's sources).
build:
	$(SERVER_COMPOSE) build
	$(CLIENT_COMPOSE) build

rebuild:
	$(SERVER_COMPOSE) build --no-cache
	$(CLIENT_COMPOSE) build --no-cache

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
