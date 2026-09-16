# rana-deploy

`rana-socketd` runs **on the host** and binds **9000** there as the door. LocalAI (the LLM) is published to the host on **8080** and is reachable solely from `rana-socketd` (the `ask`/`stt` hops), which is the only component allowed to call it.

This repo orchestrates **both** rana roles from one place. Each role has its own
compose file and config; you bring a role up with a single `make` target.

## Layout

```
rana-deploy/
├── compose/
│   ├── docker-compose.server.yaml   # SERVER: localai + rana-socketd — config/server.toml
│   └── docker-compose.client.yaml   # CLIENT (notebook): rana-client-daemon + rana-voice-agent
├── Makefile                    # server / client / down / ps / logs / sync-client / clean
├── config/
│   ├── server.toml             # server daemon config (was rana-socket.toml)
│   └── client.toml             # notebook daemon config (was notebook_services.toml)
└── README.md
```

`server.toml` and `client.toml` are both `rana-socketd` daemon configs:

- **server.toml** — the server (tower). `rana-socketd` runs **natively on the
  host** (see below) and listens on TCP `:9000`; LocalAI (8080) is published to
  the host and only reachable from the daemon at `http://127.0.0.1:8080`.
- **client.toml** — the notebook-side daemon. `rana-socketd` also runs **natively
  on the host** and listens on a unix socket (`run/rana/rana-local.sock`, relative
  to this dir, bind-mounted into the agent container at `/run/rana`) that the
  `rana-voice-agent` container forwards audio to.

## The socket runs on the host

The `rana-socketd` daemon is **not** containerized. It needs host resources — the
browser/display, local light scripts, `xdg-open` — and reaches LocalAI over the
host-published 8080. So `make socket` builds the statically-linked daemon + hop
scripts from the sibling `rana-socket` image and installs them to `/usr/local/bin`;
`make server`/`make client` then launch the matching daemon process on the host
(in the background, logging to `run/socket/<role>.log`) alongside the docker
services. **ctrl-c** stops the host daemon and takes the compose stack down.

The SERVICES (LocalAI, the voice agent) stay in docker compose.

## Prereqs

- Docker Compose v2.
- `predep`, `flatc` (FlatBuffers compiler), and `premake5` must be installed on
  the host — `make socket` runs `predep install` in the sibling `rana-socket`
  repo, which uses `premake5` to build the daemon and `flatc` to generate the
  schema bindings. `make server`/`make client` depend on `socket`, so these are
  required to run anything in this repo.
- A host toolchain-free runtime: the daemon is a static binary; the hop scripts
  need `curl`, `jq`, `python3` (and `espeak-ng`/`xdg-open` for those commands).
- `setpriv` (util-linux) so the daemon can drop to uid 1000 for the notebook UDS
  (matching the agent container's uid). Falls back to root if unavailable.
- The `rana-voice-backend/` sibling for the LocalAI model config
  (`config/command.yaml`) and model binary (`models/`). The server compose
  bind-mounts `../rana-voice-backend/config` and `../rana-voice-backend/models`
  into LocalAI.
- The `rana-socket/` sibling is the build context for the `rana-socketd` image
  (from which `make socket` extracts the binary + scripts). The agent image also
  needs the `rana-socket-client` Python package, which `make sync-client` (run
  automatically by `make client`) copies from `../rana-socket/client/py` into
  `../rana-voice-agent/vendors/`.
- The `rana-voice-models/` sibling provides the trained wake-word model and
  openWakeWord resources mounted into the agent container.

## Bring up a role

```sh
make server     # build+install socket, up LocalAI (docker), launch tower daemon (host), follow logs
make client     # sync agent dep, build+install socket, up agent (docker), launch notebook daemon (host), follow logs
```

Both bring the docker services up detached, launch the host daemon, then follow
logs (both the docker services and the host daemon's `run/socket/<role>.log`).
**ctrl-c** stops the host daemon and takes the whole stack down.

```sh
make socket    # build + install the rana-socketd runtime only (binary + hop scripts)
make ps        # show running containers + host daemons (both roles)
make logs      # follow logs for whatever is running (daemons + compose)
make down      # stop the host daemons AND all compose services (both roles)
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
socket); the server `rana-socketd` (server.toml, TCP 9000) is the only component
that reaches LocalAI. Both roles share one generic `Command{key,action,target,params,data}`
envelope and a `scripts/` folder — `[commands.allowed]` picks which scripts each
role exposes (server: ask/talk/power/mc_server/lookup_machine; client: the device
commands like speak/browser/lights). Voice runs server-side as `talk → stt → ask`
pipeline hops; device intents the server does not own are forwarded back to the
client daemon.
