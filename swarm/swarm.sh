#!/usr/bin/env bash
# swarm.sh — minimal tmux agent swarm.
# Companion to "Tmux Is All You Need" (Appendix A, but load-bearing).
#
# Layout:  one tmux server on its own socket (a NAMESPACE, not a sandbox),
#          one session, window "orch" for the orchestrator agent, and one
#          window per worker ("w0", "w1", ...) so the silence watchdog —
#          a per-WINDOW mechanism in tmux — is per-worker.
#
# Addressing: workers are addressed by immutable pane ID (%N), recorded in a
# registry at creation. Window/pane *indexes* renumber under topology changes
# and are never used for control.
#
# Completion: explicit. A worker's task ends by running `swarm.sh done <task>`,
# which sets @state=done and signals the unique channel done:<task>. Silence is
# a watchdog (worker may be stuck), never a success signal.

set -euo pipefail

SOCK="${SWARM_SOCKET:-swarm}"        # separate server namespace (tmux -L)
SES="${SWARM_SESSION:-proj}"
LOGDIR="${SWARM_LOGDIR:-$PWD/logs}"
SILENCE_SECS="${SWARM_SILENCE:-20}"  # silence => watchdog event, NOT completion
WORKER_CMD="${WORKER_CMD:-}"         # default: claude if installed, else bash
ORCH_CMD="${ORCH_CMD:-}"
REGISTRY="$LOGDIR/registry"          # lines: "<worker-index> <pane_id>"

T() { tmux -L "$SOCK" "$@"; }
die() { echo "swarm: $*" >&2; exit 1; }

default_agent() {
  if command -v claude >/dev/null 2>&1; then echo claude; else echo bash; fi
}

pane_of() {
  local id
  id=$(awk -v i="$1" '$1 == i { print $2 }' "$REGISTRY" 2>/dev/null | tail -1)
  [ -n "$id" ] || die "no worker $1 in registry $REGISTRY (swarm not up?)"
  echo "$id"
}

cmd_up() {
  local n="${1:-2}"
  command -v tmux >/dev/null 2>&1 || die "tmux not installed"
  if T has-session -t "$SES" 2>/dev/null; then
    die "session '$SES' already exists on socket '$SOCK' (run: $0 down)"
  fi
  mkdir -p "$LOGDIR"
  : > "$REGISTRY"
  local wcmd="${WORKER_CMD:-$(default_agent)}"
  local ocmd="${ORCH_CMD:-$(default_agent)}"

  # Durable detached session; corpses stay addressable so pane-died fires.
  T new-session -d -s "$SES" -n orch -x 220 -y 50
  T set-option -g remain-on-exit on
  T set-option -g history-limit 50000
  T set-option -p -t "$SES:orch.0" @role orchestrator
  T pipe-pane -o -t "$SES:orch.0" "cat >> '$LOGDIR/orchestrator.log'"
  T send-keys -t "$SES:orch.0" -l "$ocmd"
  T send-keys -t "$SES:orch.0" Enter

  # One window per worker: per-worker silence watchdog + stable pane ID.
  local i id
  for ((i = 0; i < n; i++)); do
    id=$(T new-window -dP -t "$SES" -n "w$i" -F '#{pane_id}')
    T set-option -p -t "$id" @role worker
    T set-option -p -t "$id" @state idle
    T pipe-pane -o -t "$id" "cat >> '$LOGDIR/worker-$i.log'"
    T set-option -w -t "$SES:w$i" monitor-silence "$SILENCE_SECS"
    T send-keys -t "$id" -l "$wcmd"
    T send-keys -t "$id" Enter
    echo "$i $id" >> "$REGISTRY"
  done

  # Watchdog events (quiet or dead worker) land in one append-only event log.
  T set-hook -g alert-silence \
    "run-shell \"echo \$(date +%s) silence #{pane_id} >> '$LOGDIR/events.log'\""
  T set-hook -g pane-died \
    "run-shell \"echo \$(date +%s) died #{pane_id} status=#{pane_dead_status} >> '$LOGDIR/events.log'\""

  echo "swarm up: session '$SES' on socket '$SOCK', $n worker(s) running '$wcmd'"
  echo "  attach:   tmux -L $SOCK attach -t $SES     (or: $0 attach)"
  echo "  registry: $REGISTRY   logs: $LOGDIR/"
  echo "  note: the socket is a namespace, not a sandbox; keep push/deploy"
  echo "        credentials out of worker panes."
}

cmd_dispatch() {
  local i="${1:?usage: dispatch <worker-index> <task...>}"; shift
  local task="$*"
  [ -n "$task" ] || die "empty task"
  local id; id=$(pane_of "$i")
  T set-option -p -t "$id" @state busy
  # -l: literal text, so a task containing "Enter" is not helpfully pressed.
  T send-keys -t "$id" -l "$task"
  T send-keys -t "$id" Enter
  echo "dispatched -> worker $i ($id)"
}

cmd_capture() {
  local i="${1:?usage: capture <worker-index> [lines]}"
  local lines="${2:-60}"
  T capture-pane -p -J -t "$(pane_of "$i")" -S "-$lines"
}

cmd_status() {
  T list-panes -a -F \
    '#{pane_id}  #{session_name}:#{window_name}  role=#{@role}  state=#{@state}  cmd=#{pane_current_command}  dead=#{pane_dead}  silent=#{window_silence_flag}'
}

cmd_events() { [ -f "$LOGDIR/events.log" ] && tail -n "${1:-20}" "$LOGDIR/events.log" || echo "(no events yet)"; }

# Completion protocol. wait-for is a one-bit LATCH per channel: a signal with no
# waiter is stored and consumed by the next waiter, but early signals coalesce
# and a reused channel can deliver a stale wake — so one unique channel per task
# attempt, never reused.
cmd_await() { T wait-for "done:${1:?usage: await <task-id>}"; }
cmd_done() {
  local task="${1:?usage: done <task-id>   (run inside a worker pane)}"
  [ -n "${TMUX_PANE:-}" ] && T set-option -p -t "$TMUX_PANE" @state done
  T wait-for -S "done:$task"
}

# Generic advisory barrier/signal (same latch semantics; prefer await/done).
cmd_barrier() { T wait-for "${1:?usage: barrier <channel>}"; }
cmd_signal()  { T wait-for -S "${1:?usage: signal <channel>}"; }

cmd_attach() { exec tmux -L "$SOCK" attach -t "$SES"; }

cmd_down() { T kill-server 2>/dev/null && echo "swarm down (socket '$SOCK')" || echo "no server on socket '$SOCK'"; }

# Self-contained end-to-end check with plain bash workers — no agents needed.
cmd_demo() {
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  WORKER_CMD=bash ORCH_CMD=bash cmd_up 2
  cmd_dispatch 0 "echo \"worker 0 reporting: \$(hostname)\" ; '$SELF' done demo-0-1"
  cmd_dispatch 1 'echo "worker 1 reporting: 6 * 7 = $((6 * 7))"'
  echo "awaiting explicit completion of demo-0-1 (latched, so order-safe)..."
  cmd_await demo-0-1 && echo "worker 0 signalled done:demo-0-1"
  echo; echo "== worker 0 =="; cmd_capture 0 8
  echo; echo "== worker 1 =="; cmd_capture 1 8
  echo; echo "== status ==";   cmd_status
  echo; echo "demo swarm left running — '$0 attach' to look around, '$0 down' to stop it."
}

usage() {
  cat <<EOF
usage: $0 <command> [args]

  up [n]                 create session: n workers (default 2), one window each,
                         plus an orchestrator window; pane IDs -> registry
  dispatch <i> <task..>  send a task to worker i (addressed by stable pane ID)
  capture <i> [lines]    print worker i's last lines (default 60)
  status                 list panes: id, role, @state, command, dead/silent flags
  events [n]             tail the silence/death watchdog log
  await <task-id>        block until 'done <task-id>' is signalled (one-bit latch;
                         use a unique task-id per attempt, never reuse)
  done <task-id>         run INSIDE a worker pane as a task's last step:
                         sets @state=done and signals done:<task-id>
  barrier|signal <chan>  raw wait-for on an arbitrary channel
  attach                 attach this terminal to the swarm
  down                   kill the swarm server (this socket only)
  demo                   end-to-end smoke test with bash workers

environment:
  SWARM_SOCKET=$SOCK  SWARM_SESSION=$SES  SWARM_SILENCE=$SILENCE_SECS
  SWARM_LOGDIR=$LOGDIR
  WORKER_CMD (default: claude if installed, else bash)   ORCH_CMD (same)

The socket is a namespace, not a sandbox. Do not give worker panes credentials
for pushes, deploys, or anything else you would want a human to approve.
EOF
  exit 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up|dispatch|capture|status|events|await|done|barrier|signal|attach|down|demo) "cmd_$cmd" "$@" ;;
  *) usage ;;
esac
