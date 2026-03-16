# agent-browser Guide

CLI browser automation tool. Uses a ref-based accessibility tree for deterministic element selection. Connects to a persistent browser daemon.

## Setup

```bash
npm install -g agent-browser
agent-browser install

agent-browser --profile /home/fipauli/.chrome-profile open https://example.com
```

If Linux browser dependencies are missing:

```bash
agent-browser install --with-deps
```

If the daemon is already running, `--profile` is ignored. Restart it with:

```bash
agent-browser close
agent-browser --profile /home/fipauli/.chrome-profile open https://example.com
```

For this repo's logged-in Chrome workflow on recent Chrome versions:

- open Chrome first
- open `chrome://inspect/#remote-debugging`
- allow remote debugging
- on the first controlled run, click **Allow** so `agent-browser` can control the live logged-in session
- otherwise a fresh browser instance may be launched instead of the logged-in session

Prefer `--auto-connect` for this workflow because Chrome may expose a dynamic DevTools port. Also prefer a named session to avoid stale default-session state:

```bash
agent-browser --session live --auto-connect open https://example.com
AGENT_BROWSER_SESSION=live agent-browser snapshot -c
```

If Chrome was explicitly started with `--remote-debugging-port=9222`, use CDP mode as a fallback:

```bash
agent-browser connect 9222
agent-browser --cdp 9222 snapshot
```

To inspect session state:

```bash
agent-browser session list
agent-browser session
```

## Core usage

```bash
agent-browser open https://example.com
agent-browser wait --load networkidle
agent-browser snapshot -i
agent-browser click @e2
agent-browser fill @e3 "text"
agent-browser snapshot -i
```

## Good use cases

- checking recent news or live public webpages
- extracting headlines or article titles
- verifying current facts before replying

## Basic commands

```bash
agent-browser open <url>
agent-browser wait --load networkidle
agent-browser wait 2000
agent-browser snapshot -c
agent-browser get text @e1
agent-browser get attr @e1 href
agent-browser eval "document.title"
agent-browser get url
agent-browser screenshot --full
```

## Before declaring failure

Try this sequence first:

```bash
agent-browser open <url>
agent-browser wait --load networkidle
agent-browser wait 2000
agent-browser snapshot -c --max-output 8000
agent-browser eval "document.title"
agent-browser get url
```

If the page still looks empty or broken:

- try a nearby URL such as the home page or a likely section page
- prefer extracting any visible text before saying the site is inaccessible
- only declare failure after at least one retry path

Observed site behavior:

- CNBC and WSJ rendered normally in the live browser session.
- CNN was inconsistent: `agent-browser open https://www.cnn.com` could appear to hang, but the page later became readable after the fallback sequence.
- For CNN specifically, do not stop at the `open` result. Wait, re-check title, inspect `get url`, and run `snapshot -c` before concluding failure.
