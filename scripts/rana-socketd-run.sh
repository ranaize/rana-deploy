#!/usr/bin/env bash
#
# rana-socketd-run.sh — run the rana-socketd daemon NATIVELY on the host.
#
# The socket is deliberately run outside docker: it needs host resources (the
# browser/display, local light scripts, xdg-open) and reaches LocalAI on the
# host-published 8080. The services (LocalAI, the voice agent) stay in compose.
#
# Subcommands (invoked by the rana-deploy Makefile):
#   start   <role> <config>         launch the daemon; logs to run/socket/<role>.log
#   stop    <role>                  stop the daemon (kill its pidfile)
#   status                              show which daemons are running
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolve the daemon via PATH so the installed (/usr/local/bin) and the
# build-folder (added to PATH) binaries both work. Override with RANA_SOCK_BIN
# when launching an explicit binary path (see `make socket`'s not-installed branch).
SOCK_BIN="${RANA_SOCK_BIN:-$(command -v rana-socketd 2>/dev/null || echo /usr/local/bin/rana-socketd)}"
LOG_DIR="$ROOT/run/socket"
RUN_UID=1000

cmd="${1:-}"; role="${2:-}"; cfg="${3:-}"

mkdir -p "$LOG_DIR"

start() {
    local role="$1" cfg="$2"
    [ -x "$SOCK_BIN" ] || { echo "error: $SOCK_BIN missing — run 'make socket' first" >&2; exit 1; }
    if [ -f "$LOG_DIR/$role.pid" ] && kill -0 "$(cat "$LOG_DIR/$role.pid")" 2>/dev/null; then
        echo "rana-socketd ($role) already running (pid $(cat "$LOG_DIR/$role.pid"))"
        return 0
    fi
    cd "$ROOT"
    local prefix=()
    # Keep the daemon's own directory on PATH for spawned scripts (harmless now
    # that the LLM/STT hops are in-process .pluto scripts).
    export PATH="$(dirname "$SOCK_BIN")${PATH:+:$PATH}"
    # Drop to the unprivileged uid so the unix socket it creates is owned by that
    # user — the agent container runs as the same uid and connects to it.
    if [ "$(id -u)" -eq 0 ] && id -u "$RUN_UID" >/dev/null 2>&1; then
        chown -R "$RUN_UID:$RUN_UID" "$LOG_DIR" 2>/dev/null || true
        if command -v setpriv >/dev/null 2>&1; then
            prefix=(setpriv --reuid="$RUN_UID" --regid="$RUN_UID" --clear-groups)
        else
            echo "warning: setpriv unavailable; running as root — the notebook UDS may not be connectable by the agent (uid $RUN_UID)" >&2
        fi
    fi
    nohup "${prefix[@]}" "$SOCK_BIN" "$cfg" > "$LOG_DIR/$role.log" 2>&1 &
    echo $! > "$LOG_DIR/$role.pid"
    echo "rana-socketd ($role) started pid $(cat "$LOG_DIR/$role.pid"); log: $LOG_DIR/$role.log"
}

stop() {
    local role="$1"
    if [ -f "$LOG_DIR/$role.pid" ]; then
        local p="$(cat "$LOG_DIR/$role.pid")"
        if kill "$p" 2>/dev/null; then echo "rana-socketd ($role) stopped (pid $p)"; else echo "rana-socketd ($role) was not running"; fi
        rm -f "$LOG_DIR/$role.pid"
    else
        echo "rana-socketd ($role) not running (no pidfile)"
    fi
}

status() {
    for r in server client; do
        if [ -f "$LOG_DIR/$r.pid" ] && kill -0 "$(cat "$LOG_DIR/$r.pid")" 2>/dev/null; then
            echo "$r: running (pid $(cat "$LOG_DIR/$r.pid"))"
        else
            echo "$r: stopped"
        fi
    done
}

case "$cmd" in
    start)  [ -n "$role" ] && [ -n "$cfg" ] || { echo "usage: $0 start <role> <config>" >&2; exit 2; }; start "$role" "$cfg" ;;
    stop)   [ -n "$role" ] || { echo "usage: $0 stop <role>" >&2; exit 2; }; stop "$role" ;;
    status) status ;;
    *) echo "usage: $0 {start|stop|status} [args]" >&2; exit 2 ;;
esac
