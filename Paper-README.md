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
./swarm/swarm.sh dispatch 0 "run the test suite and summarize failures"
./swarm/swarm.sh dispatch 1 "review the diff in src/ for concurrency bugs"
./swarm/swarm.sh status          # who is busy, who is back at a prompt
./swarm/swarm.sh capture 0 80    # read worker 0's last 80 lines
./swarm/swarm.sh events          # silence/death event log
./swarm/swarm.sh attach          # watch everything live (detach: C-b d)
./swarm/swarm.sh down            # kill the swarm server
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
| Isolated socket, detached session, `remain-on-exit on` | §3.1 stacks; review W2/W5 |
| `pipe-pane` logs per pane | §3.1 residual path |
| `dispatch` uses `send-keys -l` + separate `Enter` | §3.2.1; review W7 |
| `capture` / `status` with `@role`, `pane_current_command` | §3.2.1 keys and values |
| `barrier` / `signal` via `wait-for`, armed before dispatch | §3.3; review W4 |
| `monitor-silence` + hooks into `events.log` | §3.5 positional encoding |
| You, attached at the root | §5.4 the regularizer |

## Safety notes

- The orchestrator briefing hard-codes a **human gate**: nothing irreversible or
  outward-facing (push, deploy, delete) without your explicit go-ahead.
- Don't run workers with permission checks disabled just to make the swarm
  smoother; the gate is the point (paper Table 2, row D: "fastest and least
  safe; not advised").
- Each swarm lives on its own socket. `./swarm/swarm.sh down` kills only that
  socket's server, not your personal tmux.
