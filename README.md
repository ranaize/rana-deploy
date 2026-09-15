# rana-deploy

One published port — **9000** — is the `rana-socketd` door. LocalAI (the LLM) listens only on the internal `rana_server_net` bridge (8080) and is reachable solely from `rana-socketd`, which is the only component allowed to call it (the `ask` hop).

This repo orchestrates **both** rana roles from one place. Each role has its own
compose file and config; you bring a role up with a single `make` target.

## Layout

```
rana-deploy/
├── compose/
│   ├── docker-compose.server.yaml   # SERVER (tower): localai + rana-socketd — config/server.toml
│   └── docker-compose.client.yaml   # CLIENT (notebook): rana-client-daemon + rana-voice-agent
├── Makefile                    # server / client / down / ps / logs / sync-client / clean
├── config/
│   ├── server.toml             # tower daemon config (was rana-socket.toml)
│   └── client.toml             # notebook daemon config (was notebook_services.toml)
└── README.md
```

`server.toml` and `client.toml` are both `rana-socketd` daemon configs:

- **server.toml** — the tower. `rana-socketd` listens on TCP `:9000`; LocalAI
  (8080) is bridge-internal and only reachable from the daemon.
- **client.toml** — the notebook-side daemon. `rana-socketd` listens on a unix
  socket (`/run/rana/rana-local.sock`, shared via the `run/rana` bind mount)
  that the `rana-voice-agent` container forwards audio to.

## Prereqs

- Docker Compose v2.
- The `rana-voice-backend/` sibling for the LocalAI model config
  (`config/command.yaml`) and model binary (`models/`). The server compose
  bind-mounts `../rana-voice-backend/config` and `../rana-voice-backend/models`
  into LocalAI.
- The `rana-socket/` sibling is the `build:` context for the `rana-socketd` image
  (both roles). The agent image also needs the `rana-socket-client` Python package,
  which `make sync-client` (run automatically by `make client`) copies from
  `../rana-socket/client/py` into `../rana-voice-agent/vendors/`.
- The `rana-voice-models/` sibling provides the trained wake-word model and
  openWakeWord resources mounted into the agent container.

## Bring up a role

```sh
make server     # build + up the tower (localai + rana-socketd), follow logs
make client     # sync agent dep, build + up the notebook (daemon + agent), follow logs
```

Both bring the stack up detached, then follow logs. **ctrl-c** stops the logs and
takes the whole stack down. To leave a stack running and manage it separately, use
the individual targets below (a ctrl-c-free `up` is just `docker compose up -d`).

```sh
make ps        # show running containers (both roles)
make logs      # follow logs for whatever is running (both roles)
make down      # stop & remove every running rana service (both roles)
make sync-client   # copy the rana-socket client into the agent build context
make clean     # remove the copied client from the agent build context
```

LocalAI's `command` model must be present (download per the rana-voice-backend
README) for `ask` to route.

## The one door

```
consumer ──typed Command frame──▶ rana-socketd :9000
                                   └─ ask ─▶ rana-ask.sh ─▶ localai:8080 (bridge)
```

The notebook client forwards to its local `rana-socketd` (client.toml, unix
socket); the tower `rana-socketd` (server.toml, TCP 9000) is the only component
that reaches LocalAI. See the root `PLAN.md` for the full task breakdown (Tasks 1–7).
