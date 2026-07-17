#!/usr/bin/env bash
# swarm.sh — minimal tmux agent swarm.
# Companion to "Tmux Is All You Need" (Appendix A, but load-bearing).
#
# Layout:  one tmux server on its own socket, one session,
#          window "impl" tiled with N worker panes (Claude Code / codex / bash),
#          window "orch" holding the orchestrator agent.
#
# Everything an orchestrator needs is exposed as subcommands, so an agent
# sitting in the orch pane can drive the swarm by running this script.

set -euo pipefail

SOCK="${SWARM_SOCKET:-swarm}"        # isolated server namespace (tmux -L)
SES="${SWARM_SESSION:-proj}"
LOGDIR="${SWARM_LOGDIR:-$PWD/logs}"
SILENCE_SECS="${SWARM_SILENCE:-20}"  # silence => probably finished a step
WORKER_CMD="${WORKER_CMD:-}"         # default: claude if installed, else bash
ORCH_CMD="${ORCH_CMD:-}"

T() { tmux -L "$SOCK" "$@"; }
die() { echo "swarm: $*" >&2; exit 1; }

default_agent() {
  if command -v claude >/dev/null 2>&1; then echo claude; else echo bash; fi
}

cmd_up() {
  local n="${1:-2}"
  command -v tmux >/dev/null 2>&1 || die "tmux not installed"
  if T has-session -t "$SES" 2>/dev/null; then
    die "session '$SES' already exists on socket '$SOCK' (run: $0 down)"
  fi
  mkdir -p "$LOGDIR"
  local wcmd="${WORKER_CMD:-$(default_agent)}"
  local ocmd="${ORCH_CMD:-$(default_agent)}"

  # Durable detached session; corpses stay addressable so pane-died fires.
  T new-session -d -s "$SES" -n impl -x 220 -y 50
  T set-option -g remain-on-exit on
  T set-option -g history-limit 50000

  # Worker panes: tagged by role, tiled, with a residual log each.
  local i
  for ((i = 0; i < n; i++)); do
    if ((i > 0)); then
      T split-window -t "$SES:impl"
      T select-layout -t "$SES:impl" tiled
    fi
    T set-option -p -t "$SES:impl.$i" @role worker
    T pipe-pane -o -t "$SES:impl.$i" "cat >> '$LOGDIR/worker-$i.log'"
    T send-keys -t "$SES:impl.$i" -l "$wcmd"
    T send-keys -t "$SES:impl.$i" Enter
  done

  # Orchestrator head.
  T new-window -t "$SES" -n orch
  T set-option -p -t "$SES:orch.0" @role orchestrator
  T pipe-pane -o -t "$SES:orch.0" "cat >> '$LOGDIR/orchestrator.log'"
  T send-keys -t "$SES:orch.0" -l "$ocmd"
  T send-keys -t "$SES:orch.0" Enter

  # Event encoding: silence and death land in one append-only event log.
  T set-option -w -t "$SES:impl" monitor-silence "$SILENCE_SECS"
  T set-hook -g alert-silence \
    "run-shell \"echo \$(date +%s) silence #{session_name}:#{window_index}.#{pane_index} >> '$LOGDIR/events.log'\""
  T set-hook -g pane-died \
    "run-shell \"echo \$(date +%s) died #{session_name}:#{window_index}.#{pane_index} status=#{pane_dead_status} >> '$LOGDIR/events.log'\""

  echo "swarm up: session '$SES' on socket '$SOCK', $n worker(s) running '$wcmd'"
  echo "  attach:  tmux -L $SOCK attach -t $SES     (or: $0 attach)"
  echo "  logs:    $LOGDIR/"
}

cmd_dispatch() {
  local pane="${1:?usage: dispatch <worker-index> <task...>}"; shift
  local task="$*"
  [ -n "$task" ] || die "empty task"
  local target="$SES:impl.$pane"
  # -l: literal text, so a task containing "Enter" is not helpfully pressed.
  T send-keys -t "$target" -l "$task"
  T send-keys -t "$target" Enter
  echo "dispatched -> $target"
}

cmd_capture() {
  local pane="${1:?usage: capture <worker-index> [lines]}"
  local lines="${2:-60}"
  T capture-pane -p -J -t "$SES:impl.$pane" -S "-$lines"
}

cmd_status() {
  T list-panes -a -F \
    '#{session_name}:#{window_index}.#{pane_index}  role=#{@role}  cmd=#{pane_current_command}  dead=#{pane_dead}  silent=#{window_silence_flag}'
}

cmd_events() { [ -f "$LOGDIR/events.log" ] && tail -n "${1:-20}" "$LOGDIR/events.log" || echo "(no events yet)"; }

# Barriers: arm BEFORE dispatching the task that will signal (signals are
# not queued — a -S with no waiter is lost).
cmd_barrier() { T wait-for "${1:?usage: barrier <channel>}"; }
cmd_signal()  { T wait-for -S "${1:?usage: signal <channel>}"; }

cmd_attach() { exec tmux -L "$SOCK" attach -t "$SES"; }

cmd_down() { T kill-server 2>/dev/null && echo "swarm down (socket '$SOCK')" || echo "no server on socket '$SOCK'"; }

# Self-contained end-to-end check with plain bash workers — no agents needed.
cmd_demo() {
  WORKER_CMD=bash ORCH_CMD=bash cmd_up 2
  cmd_dispatch 0 'echo "worker 0 reporting: $(hostname) at $(date +%T)"'
  cmd_dispatch 1 'echo "worker 1 reporting: 6 * 7 = $((6 * 7))"'
  sleep 2
  echo; echo "== worker 0 =="; cmd_capture 0 8
  echo; echo "== worker 1 =="; cmd_capture 1 8
  echo; echo "== status ==";   cmd_status
  echo; echo "demo swarm left running — '$0 attach' to look around, '$0 down' to stop it."
}

usage() {
  cat <<EOF
usage: $0 <command> [args]

  up [n]                 create session with n workers (default 2) + orchestrator
  dispatch <i> <task..>  send a task to worker pane i
  capture <i> [lines]    print worker i's last lines (default 60)
  status                 list panes: role, current command, dead/silent flags
  events [n]             tail the silence/death event log
  barrier <channel>      block until <channel> is signalled (arm before dispatch)
  signal <channel>       signal <channel>
  attach                 attach this terminal to the swarm
  down                   kill the swarm server
  demo                   end-to-end smoke test with bash workers

environment:
  SWARM_SOCKET=$SOCK  SWARM_SESSION=$SES  SWARM_SILENCE=$SILENCE_SECS
  SWARM_LOGDIR=$LOGDIR
  WORKER_CMD (default: claude if installed, else bash)   ORCH_CMD (same)
EOF
  exit 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up|dispatch|capture|status|events|barrier|signal|attach|down|demo) "cmd_$cmd" "$@" ;;
  *) usage ;;
esac
