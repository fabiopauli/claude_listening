# Tmux Is All You Need — paper & minimal swarm

Companion README for the paper and its runnable artifacts. (The repository's main
`README.md` documents the assistant project; this file covers only the paper and
the swarm scripts.)

## Files

| File | What it is |
|---|---|
| `tmux-is-all-you-need.md` | The paper in Markdown |
| `tmux-is-all-you-need.tex` | LaTeX source, single-column NeurIPS-2017 style with TikZ figures |
| `tmux-is-all-you-need.pdf` | Compiled paper (9 pages) |
| `adversarial-review.md` | Reviewer-2-style adversarial review: 12 findings + changelog of fixes |
| `swarm/swarm.sh` | Minimal working swarm: the paper's Appendix A, made load-bearing |
| `swarm/orchestrator-prompt.md` | Briefing to paste into the orchestrator agent's pane |

## Building the PDF

Requires a TeX distribution with `tikz`, `booktabs`, `listings` (Debian/Ubuntu:
`texlive-latex-base texlive-latex-recommended texlive-latex-extra
texlive-fonts-recommended`):

```bash
pdflatex tmux-is-all-you-need.tex
pdflatex tmux-is-all-you-need.tex   # second pass resolves cross-references
```

## Running a minimal swarm

Requires `tmux` ≥ 3.2 (the paper's version pin; tested on 3.4). Workers default
to `claude` if installed, otherwise plain `bash`.

```bash
# Smoke test with bash workers — no agents needed:
./swarm/swarm.sh demo

# Real thing: 3 Claude Code workers + an orchestrator pane
./swarm/swarm.sh up 3

# Mixed swarm: the substrate is model-agnostic (paper §6.3)
WORKER_CMD=codex ./swarm/swarm.sh up 2
```

Then either drive it yourself:

```bash
./swarm/swarm.sh dispatch 0 "run the tests; then ./swarm/swarm.sh done tests-0-1"
./swarm/swarm.sh await tests-0-1 # block until worker 0 signals that unique id
./swarm/swarm.sh status          # pane IDs, roles, @state, dead/silent flags
./swarm/swarm.sh capture 0 80    # read worker 0's last 80 lines
./swarm/swarm.sh events          # silence/death watchdog log (not completion!)
./swarm/swarm.sh attach          # watch everything live (detach: C-b d)
./swarm/swarm.sh down            # kill the swarm server (this socket only)
```

…or make the loop recursive: attach, go to the `orch` window, and paste
`swarm/orchestrator-prompt.md` into the agent running there. It will drive the
workers through the same subcommands, and you supervise from the root — in the
loop, eventually.

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `WORKER_CMD` / `ORCH_CMD` | `claude`, else `bash` | Command started in each pane |
| `SWARM_SOCKET` | `swarm` | tmux socket name (`tmux -L`) — one namespace per swarm |
| `SWARM_SESSION` | `proj` | Session name |
| `SWARM_SILENCE` | `20` | Seconds of quiet before a silence event is logged |
| `SWARM_LOGDIR` | `./logs` | Residual logs: `worker-<i>.log`, `orchestrator.log`, `events.log` |

### How the script maps to the paper

| Script behavior | Paper section |
|---|---|
| Own socket (a namespace, not a sandbox), detached session, `remain-on-exit on` | §3.1; review W2, E7 |
| Stable `%id` addressing via a pane registry; indexes never used for control | §3.5; review E5 |
| One window per worker so the silence watchdog is per-worker | §3.5; review E6 |
| `pipe-pane` logs per pane | §3.1 residual path |
| `dispatch` uses `send-keys -l` + separate `Enter`, sets `@state busy` | §3.2.1; review W7 |
| `capture` / `status` with `@role`/`@state` keys | §3.2.1 keys and values |
| Explicit completion: `done <task-id>` / `await <task-id>`, unique per attempt | §3.3; review E1, E6 |
| `monitor-silence` + hooks into `events.log` — watchdog only | §3.5; review E6 |
| You, attached at the root, holding the only credentials | §5.4; review E8 |

## Safety notes

- **A tmux socket is a namespace, not a sandbox.** Separate sockets keep swarms
  from colliding; they share your user, filesystem, credentials, and network.
  Confining an untrusted agent takes an OS boundary (user/container/VM).
- **The gate is a capability boundary.** Keep push/deploy/delete credentials out
  of worker panes entirely; the orchestrator briefing has workers write pending
  requests for you to review on attach, and only you execute them.
- Don't run workers with permission checks disabled just to make the swarm
  smoother; the gate is the point (paper Table 2, row D: "fastest and least
  safe; not advised").
- Each swarm lives on its own socket. `./swarm/swarm.sh down` kills only that
  socket's server, not your personal tmux.
