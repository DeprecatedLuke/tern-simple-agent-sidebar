# Rails: one per tab, remembered width, side, toggle, reset width

## Sub-features

- **One rail per tab**: `ensure_rails` rebuilds the rail map from `cx.canvas:list()` (canvases this
  plugin owns under `Agent Navigations`) and maps each to its tab through `cx.session:tab_of`. Every
  tab with content ends up with exactly one rail; extras close; a tab that holds only its rail
  closes that rail.
- **No jump on a tab switch**: every rail draws the same view and nothing moves on `focus`. A single
  rail moved into the shown tab could only follow `focus`, which arrives after the switch painted.
- **Opened at the remembered share**: a rail opens with `how = "beside"` on the content leaf of the
  configured edge at `storedShare()` (default 0.2), `focus = false`. Two opens per pass at most; the
  rest continue on the `FAST_TICK_MS` follow-up pass.
- **The share is a tab fraction, not a split ratio**: `rail_geometry` walks the tab tree and
  multiplies the horizontal split ratios along the path from the root, so a rail nested beside the
  edge pane of a multi-pane tab is measured in tab width. `fit_rail` measures what one cell is worth
  there and pushes the rail's own divider until the absolute fraction matches.
- **Manual width is remembered and synced live**: `note_drag` saves a shown-tab divider change larger
  than 0.005 once it holds still for 400 ms (or at once when the tab is left), and `fit_rail` fits the
  other tabs to it, three per pass with the rest on the follow-up pass. The tab being switched to is
  fitted in the same pass, before its draw, whenever its ratio differs by more than 0.01, so a switch
  never shows a stale width; the shown tab is never fitted while a divider is under the pointer.
- **Side is adopted**: a rail that changes edge was moved by the user, so `agent_nav.side` follows it
  and the other tabs are re-opened on that edge. `toggle_side` records the current width first.
- **Toggle**: `toggle` closes every rail and sets `agent_nav.enabled = false`; toggling back opens a
  rail in every tab. Closing a rail by hand while its tab stays open does the same, after 500 ms.
- **Reset Width**: `reset_width` removes the stored share and fits every tab, the shown one first.

## How to get to it (user POV)

`Ctrl+Alt+N` or palette `Agent Nav: Toggle`; palette `Agent Nav: Toggle left / right`; palette
`Agent Nav: Reset Width`. Only these three commands exist.

## Driving it with the harness

```sh
.agents/skills/verify-tern-agent-nav/helpers/verify.sh toggle
# equivalent:
tern ctl 'palette "Agent Nav"'; tern ctl key enter    # run selected command (first: Toggle)
tern ls --json                                        # one canvas leaf per tab
cat /tmp/tern-sandbox/config/plugin-data/agent-nav/kv.json
```

Rail share from `tern ls --json`: `ratio` when the canvas is split node `a` (left side),
`1 - ratio` when node `b` (right side). Compare with kv `agent_nav.share` before/after.

## Gotchas

- `tern ctl` world commands must be ONE argv item; multi-argv silently no-ops (SKILL.md Drive).
- Window timers and kv writes complete asynchronously. Advance native frames with `ctl wait`
  and poll the persisted value; a wall-clock sleep and one file read do not establish completion.
- `plugins run` acks `{"ok":true}` for unknown actions; trust observed state changes only.
- Rails appear two per pass, so a window with many tabs needs several passes: poll until every tab
  reports its canvas leaf instead of reading once after a fixed wait.
- For cell comparisons, read the visible window's `ctl state` `panes` entries, keyed by `id`.
  `tern ls` and `inspect` can retain initial 80x24 grids with zero pixel dimensions for new panes,
  even while the renderer reports their actual split sizes. Require the expected pane IDs in
  window state with positive rows and columns before using a half-cell tolerance.
- Native resize accepts fractional cells. The half-cell limit below is an acceptance threshold.
  Minimum pane sizes can make a saved ratio unreachable in a narrow window: prove the bound
  by trying resize toward the target and away from it. Run the eight-pane accuracy fixture in
  a sufficiently large viewport (1780×940 was exercised); retain the same precision threshold.

## Regression checkpoints

1. With several tabs holding one, four and eight content blocks, every tab must show exactly one
   `Agent Navigations` canvas leaf, and switching tabs must not move or resize anything.
2. Each tab's rail must sit within 0.01 of the remembered share; the content ratios inside every
   tab must be untouched by the rail's arrival; `agent_nav.share` must stay unchanged by placement.
   A missing key stays missing (default width), rather than becoming 0.5.
3. Drag one rail's divider, wait for it to settle, then visit the other tabs: each must be fitted to
   the new share, and `agent_nav.share` must hold exactly that value.
4. Move a rail to the other edge by hand and confirm `agent_nav.side` follows and the other tabs
   re-open on that edge. Exercise `Toggle left / right` and `Reset Width` afterwards.
5. Toggle off must close every rail and leave `agent_nav.enabled: false`; toggle on must put a rail
   back in every tab that has content.
6. Close a rail with the builtin **Close block** palette action (not bare `ctl close`, which has
   closed the whole window) while its tab keeps other panes: the feature must switch off. Closing a
   whole tab must only close that tab's rail. `test_manual_close_disables` covers the close path.

## Proof (2026-11-09 pass)

- Nested rail: one tab's rail sat in `Row(0.640, Row(0.315, rail, pane), other)`. A
  `cx.layout:resize` on it stored `agent_nav.share = 0.20163` — the product 0.640 × 0.315 — and all
  nine tabs then read 0.2011–0.2025 from `tern inspect --json` (spread 0.0014, under one cell).
  Before the fix the same rail reported no share at all, so nothing was stored and nothing was fitted.
- A fit is retried whenever a tab is more than 0.005 off the remembered share (the same tolerance the
  fit itself aims for), so no tab is left a few cells wide of the others.

- Live size sync: a temporary command called `cx.layout:resize(rail, dir, 12)` on the shown tab's
  rail. `agent_nav.share` moved to 0.1749 and every other tab's rail reported 0.1741 within one
  pass; a second run moved the shown tab to 0.2389 with the others at 0.2402/0.2406 (cell
  rounding). The share was restored to 0.1959 afterwards and all tabs followed.

- Nine tabs of one session each held exactly one `Agent Navigations` leaf after reload
  (`tern inspect --json`), the shown tab's rail first, and a rail opened in a background tab did not
  steal focus.
- A 4-tab-then-9-tab window opened all rails within a few passes; no `Agent Nav` warning appeared in
  `tern.log` after the reload.
