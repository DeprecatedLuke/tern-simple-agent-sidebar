# Flat agent rows: one ordered list, no headers

## Sub-features

- No session headers and no tab boxes: `build_view` emits one `agent-nav-agent` button per
  navigable pane (an empty state div when there is no row).
- **Subagents come from omp's session files**: `poll_subagents` runs `tern inspect --json` every 4 s to
  map each pane to its `omp_session_file` directory, then one `sh` pass per directory lists the
  non-`__` `*.jsonl` files written in the last 30 minutes whose last line is not `session_exit`,
  with the newest `"i":"…"` intent near the end as the doing line. The rows read the cache; a
  subagent is shown whatever the parent's own state is.
- **Grouped by directory**: agents sharing a cwd sit under one `agent-nav-cwd-group` label and their
  rows show titles only. The flat row order decides the group order (by each group's first row) and
  the order inside a group; a cross-directory drop therefore moves a row's group, never its cwd.
- Each row's title is the pane title the harness writes; omp, Codex and Copilot put their session
  title there. The row falls back to the cwd's last folder or `Pane <id>` when untitled, and to the
  remembered title when a finished agent stops titling its pane.
- Codex marks a working turn with a braille spinner frame (U+2800..U+28FF) at the title start;
  `strip_leading_glyphs` and `spinnerTitle` remove it.
- **Order**: a row the user moved keeps its remembered position; unlisted rows follow native order
  (Tern session order, then tab position, then the window's pane order). The order is a list of pane
  ids in `agent_nav.order`; `pane_closed` drops an id from it.
- **Moving a row**: the canvas reports clicks only (`CanvasAction` with `mods`), so there is no drag.
  Shift-click picks a row up (`is-carried`), any row click drops the picked row directly above the
  clicked one, and shift-clicking the picked row again or plain-clicking it cancels. A click with
  nothing picked up focuses that agent's pane.

## How to get to it (user POV)

Toggle the panel on (`Ctrl+Alt+N` or palette `Agent Nav: Toggle`); the rows appear in every tab.
Shift-click a row, click another row to move the first above it.

## Driving it with the harness

```sh
tern capture "Agent Navigations" --surfaces     # plain text rows in display order
tern ctl 'tree .agent-nav-agent'                # row boxes, class and text
tern ctl 'click X Y shift'                      # pick a row up (coordinates from the tree)
tern ctl 'click X2 Y2'                          # drop it above the row at X2 Y2
cat /tmp/tern-sandbox/config/plugin-data/agent-nav/kv.json   # agent_nav.order
```

## Gotchas

- The capture loses CSS classes; it proves order and titles, not status styling (see 02/03).
- Titles update asynchronously: omp writes the session title only once the turn names the session,
  so a drive right after spawning an agent may show the fallback title.
- Row rectangles move when rows are added or removed: read `tree .agent-nav-agent` again before
  each click, and never reuse coordinates from an earlier capture.
- A drop click is consumed by the move, so it does not also focus the clicked pane; only a click
  with nothing picked up navigates.
- `agent_nav.order` keeps only pane ids: a pane that is closed disappears from it, and ids are never
  reused, so a stale id can only be dead weight, never a wrong row.

## Proof (2026-11-09 pass)

- Live: shift-clicked the last row and clicked the first; the capture then listed the moved row's
  directory first and `agent_nav.order` held the moved pane id ahead of the rest. Shift-clicking a row and clicking it
  again left both the order and the focused pane unchanged, and a plain click on another row focused
  its pane.
- The order survived a plugin reload and a reinstall, and no session header or workspace button
  appears in the capture.
