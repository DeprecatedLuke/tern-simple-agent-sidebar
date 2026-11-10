--!strict
-- Agent Navigations: one agent list per window, shown as a rail on the left or
-- right edge of every tab, at a remembered share of the tab.
--
-- Every tab keeps its own rail canvas and all of them draw the same view, so a
-- tab switch moves and resizes nothing. A single rail moved into the shown tab
-- could only follow the `focus` event, which arrives after the switch painted,
-- so the rail always landed a few frames late. Rails are opened beside the
-- content leaf on the configured edge; dragging one rail's divider sets the
-- remembered share, and tabs that are not shown are fitted to it.

local ui = tern.ui

local TITLE = "Agent Navigations"
local ABOUT = "Agents across Tern sessions. Click a row to switch to its session and focus it; shift-click a row, then click another to move it above."
local TICK_MS = 750
-- Rails still to open, move, fit or redraw continue on this shorter cadence
-- instead of waiting for the next tick; one follow-up is outstanding at a time.
local FAST_TICK_MS = 60
local DEFAULT_SHARE = 0.2
local MIN_SHARE, MAX_SHARE = 0.08, 0.6

local KV_ENABLED = "agent_nav.enabled"
local KV_SIDE = "agent_nav.side"
local KV_SHARE = "agent_nav.share"

-- Panes already listed as agent rows; see listedAgents.
local KV_SEEN = "agent_nav.seen"
-- Clean up settings from obsolete layouts: the rebuild journal's keys, the removed
-- harness launch menu, rail workspaces and the display settings menu.
for _, key in {
	"agent_nav.width", "agent_nav.auto_tabs", "agent_nav.omp_debug", "agent_nav.panes_dump",
	"agent_nav.test_ping", "agent_nav.launch_ui", "agent_nav.open_in_tab",
	"agent_nav.workspaces", "agent_nav.assign", "agent_nav.group_tabs", "agent_nav.minimap",
	"agent_nav.dbg",
} do
	if tern.kv.get(key) ~= nil then
		tern.kv.set(key, nil)
	end
end

-- Names match as whole words (`harness_icon`), so every variant a CLI ships as
-- gets its own entry: `cursor-agent` is the Cursor CLI's binary name.
local HARNESS_ICONS: { [string]: string } = {
	omp = "app-omp",
	hermes = "app-hermes",
	claude = "mi-claude",
	["claude-code"] = "mi-claude",
	["claude-code-acp"] = "mi-claude",
	codex = "provider-openai",
	["codex-acp"] = "provider-openai",
	copilot = "mi-copilot",
	["copilot-acp"] = "mi-copilot",
	gemini = "mi-gemini-ai",
	["gemini-cli"] = "mi-gemini-ai",
	cursor = "mi-cursor",
	["cursor-agent"] = "mi-cursor",
	opencode = "mi-code",
	kimi = "sparkle",
	kilo = "sparkle",
	carly = "sparkle",
}

-- A harness name counts only as a whole token of the text it is found in: a plain
-- substring scan reads "components", "prompt" and "compile" as omp, so a `pnpm run`
-- block became an agent row wearing omp's logo. Tokens are runs of letters, digits
-- and hyphens, which keeps `claude-code` and `codex-acp` whole and splits paths and
-- prose into their own words.
local function harness_icon(text: string): (string?, string?)
	for token in string.gmatch(string.lower(text), "[%w%-]+") do
		local icon = HARNESS_ICONS[token]
		if icon then
			return token, icon
		end
	end
	return nil, nil
end

type Side = "left" | "right"

type AgentRow = {
	pane: number,
	session: number,
	tab: number?,
	title: string,
	cwd: string?,
	subagents: { { name: string, doing: string, started: number?, pct: number?, job: boolean? } },
	-- What the agent is doing now, when it is running.
	doing: string?,
	status: string,
	is_current: boolean,
	-- Native position: session order, tab position, then pane order.
	rank: number,
}

--------------------------------------------------------------------------------
-- Settings & State
--------------------------------------------------------------------------------

-- Read on every pass: tern.kv is shared by every window, so switching the rails
-- off or on in one window does so in all of them.
local function enabled(): boolean
	return tern.kv.get(KV_ENABLED) == true
end

local function setEnabled(want: boolean)
	tern.kv.set(KV_ENABLED, want)
end

local function side(): Side
	return if tern.kv.get(KV_SIDE) == "right" then "right" else "left"
end

local function clampShare(v: number): number
	return math.clamp(v, MIN_SHARE, MAX_SHARE)
end

local function storedShare(): number
	local v = tonumber(tern.kv.get(KV_SHARE))
	return if v then clampShare(v) else DEFAULT_SHARE
end

--------------------------------------------------------------------------------
-- Arrangement Model
--------------------------------------------------------------------------------
-- cx.session:layout(tab).root is a TabTree whose children are numeric [1]/[2]
-- keys. The layout map reads content through one shape: a `pane` leaf, or a
-- split with named `axis`, `ratio`, `first` and `second`.

type Axis = "right" | "down"

local MAX_TREE_DEPTH = 32

--------------------------------------------------------------------------------
-- Rail State
--------------------------------------------------------------------------------
-- Rebuilt from cx.canvas:list() on every placement pass: a rail is a canvas this
-- plugin owns under TITLE, and each tab with content holds exactly one.

local railOf: { [number]: number } = {} -- tab -> its rail
local railTab: { [number]: number } = {} -- rail -> its tab
-- The tab shown at the last placement pass.
local lastShown: number? = nil
local warnedIds = false

local function valid_id(value: any): boolean
	return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

-- Persistent state tracking across ticks/events:
local wasRunning: { [number]: boolean } = {}
local unreadPanes: { [number]: boolean } = {}
type SampledPane = {
	is_running: boolean,
	ag_state: string?,
}
local sampledPanes: { [number]: SampledPane } = {}
-- Authoritative agent blocks from cx.agents:list(): the state drives progress, and
-- the command the block was opened with is the only harness name a fresh native
-- agent has before it writes a session title. Kept across ticks: a failed or
-- oversized list response (daemon frame limit) must degrade to the last known
-- values, not drop every native agent onto screen heuristics.
local agentInfo: { [number]: { state: string, command: string } } = {}
-- Panes whose agent block reported a turn (working or waiting for input). Tern
-- opens every command block as an agent block, so this is the only evidence that
-- separates a real agent from a launched command such as `pnpm run`.
local everActive: { [number]: boolean } = {}
-- Panes once listed as agent rows, with the harness and title they were last
-- shown with. A finished agent that is still open can stop naming its harness
-- in its command line, foreground program and title alike; the latch keeps its
-- row, and that label, until pane_closed. It outlives a Tern restart, because a
-- restored pane keeps its title before its agent is back in the foreground, so
-- a known agent is listed from the first draw.
local SEEN_TTL_MS = 7 * 24 * 60 * 60 * 1000
-- A listed pane's entry is re-stamped this often, so a live entry never ages out.
local SEEN_TOUCH_MS = 60 * 60 * 1000
-- An entry this window cannot see goes only once it is this old: another
-- window's panes are not in this window's list either.
local SEEN_PRUNE_MS = 24 * 60 * 60 * 1000
type SeenAgent = { harness: string, icon: string, title: string, at: number }
local listedAgents: { [number]: SeenAgent } = {}
local seenDirty = false

do
	local stored = tern.kv.get(KV_SEEN)
	if type(stored) == "table" then
		local now = tern.now()
		for key, entry in stored do
			local pane = tonumber(key)
			if pane and valid_id(pane) and type(entry) == "table"
				and type(entry.harness) == "string" and type(entry.title) == "string"
				and type(entry.at) == "number" and now - entry.at < SEEN_TTL_MS then
				listedAgents[pane] = {
					harness = entry.harness,
					icon = if type(entry.icon) == "string" then entry.icon else "",
					title = entry.title,
					at = entry.at,
				}
			end
		end
	end
end

local function save_seen()
	if not seenDirty then
		return
	end
	local out: { [string]: SeenAgent } = {}
	for pane, entry in listedAgents do
		out[tostring(pane)] = entry
	end
	tern.kv.set(KV_SEEN, out)
	seenDirty = false
end

-- Cached screen-state probes. Reading every navigable pane every tick overran
-- Tern's 50 ms plugin hook budget, pausing the hook with backoff and leaving
-- stale panel state. Reads are cached per pane, refreshed
-- immediately when a cheap signal (title, busy, prompt, alert) changes, and
-- otherwise staggered: at most SCREEN_READS_PER_TICK fresh reads per render,
-- with each entry re-read at latest after SCREEN_TTL_TICKS.
local screenCache: { [number]: { sig: string, state: ("ask" | "working")?, tick: number } } = {}
local SCREEN_TTL_TICKS = 8
local SCREEN_READS_PER_TICK = 2
local tickCounter = 0
local screenBudget = 0

local function shownTab(cx: WindowCx): number?
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local refresh: (WindowCx?) -> ()

-- A pane's foreground program, from `tern process`, when window metadata no
-- longer identifies the harness (including programs started before installation).
-- One lookup per pane and title: every CLI call is a daemon connection, so they
-- are cached rather than repeated on each render. A lookup that named no harness
-- expires, because the program behind an unchanged title can still change: a
-- restored tab keeps its title while a shell starts an agent inside it. Each
-- further miss waits longer, so a pane that never names a harness is not probed
-- forever; a new title probes at once.
local FOREGROUND_RETRY_MS = 5000
local FOREGROUND_RETRY_MAX_MS = 120000
local foreground: { [number]: { title: string, argv: string, at: number, misses: number } } = {}
local probing: { [number]: boolean } = {}
local probeRefreshPending = false
local probeWarned = false

-- The window half is started by the desktop, whose PATH need not hold the CLI,
-- and a spawn without the binary raises: resolve it once from PATH and the usual
-- install locations.
local ternExe: string? = nil
local ternExeTried = false

local function tern_cli(): string
	if ternExeTried and ternExe then
		return ternExe
	end
	ternExeTried = true
	local candidates: { string } = {}
	local path = tern.getenv("PATH")
	if type(path) == "string" then
		for dir in string.gmatch(path .. ":", "([^:]*):") do
			if dir ~= "" then
				table.insert(candidates, dir .. "/tern")
			end
		end
	end
	local home = tern.getenv("HOME")
	if type(home) == "string" and home ~= "" then
		table.insert(candidates, home .. "/.local/bin/tern")
		table.insert(candidates, home .. "/.cargo/bin/tern")
	end
	table.insert(candidates, "/usr/local/bin/tern")
	table.insert(candidates, "/usr/bin/tern")
	for _, candidate in candidates do
		local ok, exists = pcall(tern.fs.exists, candidate)
		if ok and exists == true then
			ternExe = candidate
			return candidate
		end
	end
	ternExe = "tern"
	return "tern"
end

-- The text a pane's foreground argv contributes to harness detection. A sandbox
-- wrapper's argv carries every bind mount it makes, which can name another agent
-- (`~/.opencode`), so only the command after the last `--` counts.
local function argv_text(argv: { string }): string
	local first = argv[1]
	if type(first) == "string" and string.match(string.lower(first), "([^/\\]+)$") == "bwrap" then
		for index = #argv, 2, -1 do
			if argv[index] == "--" then
				return string.lower(table.concat(argv, " ", index + 1))
			end
		end
	end
	return string.lower(table.concat(argv, " "))
end

local function probeForeground(pane_info: any)
	local pane, title = pane_info.pane, pane_info.title or ""
	local known = foreground[pane]
	if probing[pane] or tern.runtime.os == "ios" then
		return
	end
	if known and known.title == title then
		-- A lookup that found a harness holds while the title holds.
		local _, icon = harness_icon(known.argv)
		local wait = math.min(FOREGROUND_RETRY_MS * 2 ^ known.misses, FOREGROUND_RETRY_MAX_MS)
		if icon or tern.now() - known.at < wait then
			return
		end
	end
	probing[pane] = true
	local ok, err = pcall(function()
		tern.process.run({ tern_cli(), "process", tostring(pane), "--json" }, { timeout_ms = 3000 }, function(r, _cx)
			probing[pane] = nil
			local argv = ""
			if r.status == 0 then
				local okJ, doc = pcall(tern.json.decode, r.stdout)
				local fg = okJ and type(doc) == "table" and doc.foreground
				if type(fg) == "table" and type(fg.argv) == "table" then
					argv = argv_text(fg.argv)
				end
			end
			local _, found = harness_icon(argv)
			foreground[pane] = {
				title = title,
				argv = argv,
				at = tern.now(),
				misses = if found then 0 else (if known then known.misses + 1 else 1),
			}
			local before = if known then known.argv else ""
			if argv ~= before and not probeRefreshPending then
				probeRefreshPending = true
				-- Reconcile queued close/focus events before touching a canvas again.
				tern.timer(0, function(cx)
					probeRefreshPending = false
					refresh(cx)
				end)
			end
		end)
	end)
	if not ok then
		probing[pane] = nil
		-- One warning per session of failures: the lookup only refines labels.
		if not probeWarned then
			probeWarned = true
			tern.log.warn("Agent Nav: cannot read a pane's foreground process: " .. tostring(err))
		end
	end
end

-- Terminal agents that never report `busy` (Codex) mark a working turn with a
-- braille spinner frame (U+2800..U+28FF) at the start of their title.
local function spinnerTitle(title: string?): (boolean, string?)
	if type(title) ~= "string" then
		return false, title
	end
	local first = utf8.codepoint(title, 1, 1)
	if first and first >= 0x2800 and first <= 0x28FF then
		local rest = string.match(string.sub(title, utf8.offset(title, 2) or (#title + 1)), "^%s*(.-)$")
		return true, rest
	end
	return false, title
end
-- Codex appends a braille spinner frame to its title while a turn runs
-- ("task · dir · ⠼") instead of a leading frame.
local function spinnerTitleSuffix(title: string?): boolean
	if type(title) ~= "string" or title == "" then
		return false
	end
	-- The last character can be multi-byte; codepoint at a continuation byte errors.
	local ok, last = pcall(utf8.codepoint, title, #title)
	return ok and last ~= nil and last >= 0x2800 and last <= 0x28FF
end

-- Terminal agents that report nothing to Tern while they work or wait on the
-- user still draw it on screen: a question picker ends in a key-hint line, a
-- working turn shows a status line. These are the lines seen on real screens.
local ASK_HINTS = {
	"enter accept · tab next · ctrl+d decline", -- GitHub Copilot ask_user
	"enter continue · esc skip", -- Codex update/confirm picker
	"esc to cancel · tab to amend", -- Claude Code tool permission / confirmation
	"do you want to proceed?", -- Claude Code confirmation
}
local WORKING_HINTS = {
	-- GitHub Copilot status line while a turn runs: "◉ Working esc esc edit prompt"
	-- before output streams, "● Working · 95 B esc esc interrupt" after.
	"working esc esc edit prompt",
	"esc esc interrupt",
	"esc to interrupt", -- Claude Code footer while a turn runs
}

local function screenHas(lines: { string }, hints: { string }): boolean
	for _, line in lines do
		local lower = string.lower(line)
		for _, hint in hints do
			if string.find(lower, hint, 1, true) then
				return true
			end
		end
	end
	return false
end

-- What a terminal pane's last screen rows show: "ask" for a question or
-- approval picker, "working" for a running turn, nil otherwise. Reads only
-- the visible screen (no scrollback).
local function screenState(cx: WindowCx, pane: number): ("ask" | "working")?
	local ok, read = pcall(function()
		return cx.session:read(pane, { lines = 8, scrollback = false })
	end)
	if not ok or type(read) ~= "table" or type((read :: any).lines) ~= "table" then
		return nil
	end
	local lines = (read :: any).lines
	if screenHas(lines, ASK_HINTS) then
		return "ask"
	end
	if screenHas(lines, WORKING_HINTS) then
		return "working"
	end
	return nil
end
-- Staggered cache wrapper around screenState: at most SCREEN_READS_PER_TICK
-- fresh reads per render, an immediate refresh when a cheap pane signal
-- changes (title spinner start/stop, busy, prompt, alert), else a re-read at
-- latest after SCREEN_TTL_TICKS. Panes over budget keep their previous state.
local function screenStateCached(cx: WindowCx, p: any): ("ask" | "working")?
	local sig = string.format("%s\1%s\1%s\1%s", tostring(p.title), tostring(p.busy), tostring(p.at_prompt), tostring(p.alert))
	local hit = screenCache[p.pane]
	if hit and hit.sig == sig and tickCounter - hit.tick < SCREEN_TTL_TICKS then
		return hit.state
	end
	if screenBudget <= 0 then
		return if hit then hit.state else nil
	end
	screenBudget -= 1
	local state = screenState(cx, p.pane)
	screenCache[p.pane] = { sig = sig, state = state, tick = tickCounter }
	return state
end

--------------------------------------------------------------------------------
-- Harness names
--------------------------------------------------------------------------------

local function goto_key(session: number, pane: number): string
	return "goto:" .. tostring(session) .. ":" .. tostring(pane)
end


local function detect_harness(pane_info: any): (string, string)
	if pane_info.kind == "carly" then
		return "carly", "sparkle"
	end
	-- The foreground command names the harness most reliably: `program` can report
	-- the shell, and titles (Codex: "<task> | <dir>") need not mention the agent. A
	-- native agent block also knows the command it was opened with, which is the only
	-- harness name it has before its first session title, so that comes first.
	local running = pane_info.running
	local line = string.lower(if running and type(running.line) == "string" then running.line else "")
	local command = string.match(line, "^%s*([^%s]+)") or ""
	command = string.match(command, "([^/\\]+)$") or command
	local fg = foreground[pane_info.pane]
	local probed = if fg then fg.argv else ""
	local prog = string.lower(pane_info.program or "")
	local title = string.lower(pane_info.title or "")
	local info = agentInfo[pane_info.pane]
	local opened = if info then info.command else ""
	for _, source in { opened, command, probed, prog, title } do
		local key, icon = harness_icon(source)
		if key and icon then
			return key, icon
		end
	end
	if pane_info.kind == "agent" then
		-- An agent block with no harness name yet is still an agent, but nothing
		-- proves which one: an empty icon becomes a first-letter avatar, never omp's.
		return "agent", ""
	end
	return "terminal", "terminal"
end

local function is_navigable_pane(pane_info: any): boolean
	if pane_info.block == "tern.canvas" then
		return false
	end
	-- A pane once shown as an agent row stays listed until it closes. A finished
	-- agent can stop naming its harness everywhere the detection looks (its
	-- command line, foreground program and title), and its row must not vanish
	-- while its block is still open. Detection still runs for a listed pane, so a
	-- label the foreground lookup can now name replaces the remembered one.
	local listed = listedAgents[pane_info.pane] ~= nil
	if pane_info.kind == "carly" then
		return true
	end
	if pane_info.kind == "agent" then
		-- Tern opens every command block as an agent block, so kind alone proves
		-- nothing: a launched `pnpm run` sits in cx.agents:list() as an idle agent
		-- forever. Keep the row when its harness is named, when its program
		-- reported a turn (latched in everActive), or when it was listed before.
		local harness, _ = detect_harness(pane_info)
		if harness == "agent" then
			-- Nothing names the harness yet; the foreground lookup may still.
			probeForeground(pane_info)
		end
		return harness ~= "agent" or everActive[pane_info.pane] == true or listed
	end
	if pane_info.kind == "terminal" then
		local harness, _ = detect_harness(pane_info)
		if harness == "terminal" then
			probeForeground(pane_info)
		end
		return harness ~= "terminal" or listed
	end
	return listed
end

local function sample_status(cx: WindowCx)
	tickCounter += 1
	screenBudget = SCREEN_READS_PER_TICK

	-- Query native agent blocks for authoritative first-class state and the command
	-- each was opened with; on failure (for example a response too large for the
	-- daemon frame) keep the previous snapshot.
	local ok_ag, ag_list = pcall(function() return cx.agents:list() end)
	if ok_ag and type(ag_list) == "table" then
		local fresh: { [number]: { state: string, command: string } } = {}
		for _, a in ag_list do
			if a.pane and a.state then
				fresh[a.pane] = {
					state = a.state,
					command = string.lower(if type(a.command) == "string" then a.command else ""),
				}
			end
		end
		agentInfo = fresh
		-- Keep turn evidence until pane_closed, even when a later list omits the
		-- pane. A snapshot is not the lifetime of an already identified agent.
		for pane, info in fresh do
			if info.state == "working" or info.state == "waiting_input" then
				everActive[pane] = true
			end
		end
	end

	local freshSampled: { [number]: SampledPane } = {}
	for _, p in cx.session:panes() do
		if is_navigable_pane(p) then
			local is_focused = p.focused == true
			local is_running = false
			local agent = agentInfo[p.pane]
			local ag_state: string? = if agent then agent.state else nil
			local spinning = spinnerTitle(p.title) or spinnerTitleSuffix(p.title)
			local busyWorking = p.busy == true and not p.at_prompt
			if ag_state == "working" or ag_state == "waiting_input" then
				is_running = ag_state == "working"
			else
				is_running = spinning or busyWorking
				local screen = screenStateCached(cx, p)
				if screen == "ask" then
					ag_state = "waiting_input"
					is_running = false
				elseif screen == "working" then
					is_running = true
				end
			end

			-- Check transition from running -> finished
			if wasRunning[p.pane] == true and not is_running then
				-- Just completed! If user is not currently focused on this pane, mark unread.
				if not is_focused then
					unreadPanes[p.pane] = true
				end
			end
			wasRunning[p.pane] = is_running

			-- Also honor terminal alert bell on inactive panes as unread
			if p.alert and not is_focused and not is_running and ag_state ~= "waiting_input" then
				unreadPanes[p.pane] = true
			end

			-- If the user is currently focused on this pane, clear unread immediately.
			if is_focused then
				unreadPanes[p.pane] = nil
			end

			freshSampled[p.pane] = {
				is_running = is_running,
				ag_state = ag_state,
			}
		end
	end
	sampledPanes = freshSampled
end

-- omp prefixes pane titles with an icon glyph (private-use area, nerd font): drop any
-- leading ones so rows read as plain text.
local function strip_leading_glyphs(title: string?): string?
	if type(title) ~= "string" then
		return title
	end
	local s = title
	while true do
		local rest = string.match(s, "^[\238\239][\128-\191][\128-\191]%s*(.*)$")
			or string.match(s, "^\243[\176-\191][\128-\191][\128-\191]%s*(.*)$")
			or string.match(s, "^\226\150[\128-\191]%s*(.*)$")
		if not rest then
			break
		end
		s = rest
	end
	return s
end

-- Subagents and background jobs: omp writes a session file per agent, and a
-- parent's async subagents keep theirs beside it as <Name>.jsonl. A running
-- subagent's file ends with something other than `session_exit`, and the newest
-- intent stated near its end is what it is doing now. The transcript's task/wait
-- cards miss async spawns (their cards finish at once), so the session files are
-- the source of truth for agents. Bash/eval jobs live only in the parent
-- transcript: an `"async":{"state":"running"}` record opens one, a `"jobs":[…]`
-- record with a settled status closes it, and the command comes from the async
-- tool call that precedes it. The parent's newest stated intent and the task it
-- marked in progress come from the same tail. All of it is read off the UI path:
-- one `tern inspect` and one shell pass per session directory, every SUB_POLL_MS,
-- single-flight, and the draw only reads the cache.
local SUB_POLL_MS = 4000
local SUB_MAX = 20
local SUB_TEXT_MAX = 80
-- Jobs listed under one subagent.
local SUB_JOBS_PER_AGENT = 3
-- A subagent's file must have been written this recently.
local SUB_FRESH_MIN = 30
-- How far back in the file to look for the newest intent: a busy agent can write
-- hundreds of kilobytes between its last stated intent and its current line.
local SUB_INTENT_BYTES = 300000
type Sub = { name: string, title: string?, doing: string, started: number?, pct: number?, job: boolean?, state: string?, role: string?, jobs: { Sub }? }
type Scan = { items: { Sub }, main: string?, changed: boolean }

-- pane -> its subagents, and pane -> the directory holding its session files.
local subItems: { [number]: { Sub } } = {}
local subDirs: { [number]: string } = {}
-- pane -> what its agent is doing now, from the parent transcript.
local mainDoing: { [number]: string? } = {}
local subInspecting = false
local subScanning: { [string]: boolean } = {}

local function clip(s: string, max: number): string
	s = string.match(s, "^%s*(.-)%s*$") or s
	local n = utf8.len(s)
	if n and n > max then
		return string.sub(s, 1, (utf8.offset(s, max) :: number) - 1) .. "…"
	end
	return s
end

local function subagents_of(pane: number): { Sub }
	return subItems[pane] or {}
end

-- Per directory: every fresh, non-`__` session file that has not exited, with the
-- newest intent found near its end; then the parent transcript's main-agent line
-- and its running bash/eval jobs. The directory arrives as `$1`, the byte offset
-- already read from the parent transcript as `$2`, and the byte length of its
-- first line as `$3` (a rewrite changes that length, and the offset with it).
--
-- The parent transcript is read incrementally: the first pass takes the whole
-- file, later passes only the bytes appended since the last one. Its job records
-- are a stream of events - a spawn, a settled status, and the wait tool's
-- "## Still Running" snapshot, which lists exactly what is running at that point
-- and is therefore authoritative - applied in file order to a cached job state.
-- Nothing but compact event lines leaves the shell.
local SUB_SCAN = [[d=$1
spec=${4:-}
# One transcript, read from the byte already seen (a full pass when there is no
# usable offset). Events go to stdout tagged with the file they came from: `J`
# names the file, then its F/L1/R/D/K/E/Z/O lines follow.
jobscan() {
  f=$1; off=$2; l1c=$3; tag=$4
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  l1=$(head -n 1 "$f" | wc -c | tr -d ' ')
  start=$(( ${off:-0} + 1 ))
  full=0
  if [ "${off:-0}" -le 0 ] || [ "${size:-0}" -lt "${off:-0}" ] || [ "$l1" != "$l1c" ]; then
    start=1; full=1
  elif [ -n "$(tail -c +${off} "$f" | head -c 1)" ]; then
    # The cached offset has to sit just past a newline; anything else is a rewrite.
    start=1; full=1
  fi
  printf 'J\t%s\n' "$tag"
  [ "$full" = 1 ] && printf 'F\n'
  printf 'L1\t%s\n' "$l1"
  endsnl=1
  [ -n "$(tail -c 1 "$f")" ] && endsnl=0
  tail -c +$start "$f" | LC_ALL=C awk -v base=$((start - 1)) -v endsnl=$endsnl '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# The raw body of a JSON string value that starts after `key`, stopping at its
# closing unescaped quote, so a command with quotes, newlines or a heredoc stays
# whole instead of ending at the first escape.
function jbody(l, key,   p, i, n, c, esc, out) {
  p = index(l, key)
  if (p == 0) return ""
  p += length(key)
  n = length(l); out = ""; esc = 0
  for (i = p; i <= n; i++) {
    c = substr(l, i, 1)
    if (esc == 1) { out = out "\\" c; esc = 0; continue }
    if (c == "\\") { esc = 1; continue }
    if (c == "\"") break
    out = out c
  }
  return out
}
# JSON escapes to one line of plain text: a newline or tab becomes a space and
# other escapes their character.
function unjson(s,   out, i, n, c, d) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) {
      d = substr(s, i + 1, 1)
      if (d == "n" || d == "t" || d == "r") { out = out " "; i += 2 }
      else if (d == "u") { out = out "?"; i += 6 }
      else { out = out d; i += 2 }
    } else { out = out c; i += 1 }
  }
  return out
}
function collapse(s,   out) {
  out = s
  gsub(/[ \t\r\n]+/, " ", out)
  sub(/^ /, "", out); sub(/ $/, "", out)
  return out
}
function lastidx(s, pat,   p, q, at) {
  p = 1; at = 0
  while ((q = index(substr(s, p), pat)) > 0) { at = p + q - 1; p = at + length(pat) }
  return at
}
function jobdone(id, st) {
  # Every settled record is reported: a chunk can hold the completion of a job
  # whose spawn was read in an earlier pass.
  if (id != "" && st != "running") printf "D\t%s\t%s\n", id, st
}
function sections(t,   n, L, i, l, rest, j, id, typ, st, k, it, lb, inrun) {
  n = split(t, L, "\n")
  inrun = 0
  for (i = 1; i <= n; i++) {
    l = L[i]
    # The first section of a tool result shares its line with the JSON before
    # the text value, so the headers are found anywhere on the line.
    if (index(l, "## Still Running") > 0) { printf "K\n"; inrun = 1; continue }
    if (substr(l, 1, 3) == "## " || index(l, "\"text\":\"## ") > 0) { inrun = 0; continue }
    if (substr(l, 1, 4) == "### ") {
      rest = substr(l, 5); j = index(rest, " ")
      if (j == 0) continue
      id = substr(rest, 1, j - 1); rest = substr(rest, j + 1)
      st = ""
      if (match(rest, /— [a-z]+$/)) st = substr(rest, RSTART + 4)
      jobdone(id, st)
      continue
    }
    if (inrun == 1 && substr(l, 1, 3) == "- `") {
      rest = substr(l, 4); j = index(rest, "`")
      if (j == 0) continue
      id = substr(rest, 1, j - 1); rest = substr(rest, j + 1)
      typ = ""
      if (match(rest, /^ \[[a-z]*\]/)) { typ = substr(rest, RSTART + 2, RLENGTH - 3); rest = substr(rest, RSTART + RLENGTH) }
      sub(/^ — /, "", rest)
      k = index(rest, " — ")
      it = rest; lb = ""
      if (k > 0) { it = substr(rest, 1, k - 1); lb = substr(rest, k + 5) }
      if (typ != "" && typ != "task" && id != "") { alive[id] = 1; printf "E\t%s\t%s\t%s\t%s\n", id, typ, trim(it), lb }
    }
  }
}
function flush(l,   t, rest, seg, jid, typ, st, tcid, cmd, it, ts, lim, id) {
  if (l == "") return
  if (index(l, "\"type\":\"toolCall\"") > 0) {
    id = ""
    if (match(l, /"type":"toolCall","id":"[^"]*"/)) { seg = substr(l, RSTART, RLENGTH); if (match(seg, /"id":"[^"]*"/)) id = substr(seg, RSTART + 6, RLENGTH - 7) }
    if (id != "") {
      cmd = collapse(unjson(jbody(l, "\"command\":\"")))
      it = collapse(unjson(jbody(l, "\"intent\":\"")))
      if (it == "") it = collapse(unjson(jbody(l, "\"i\":\"")))
      callcmd[id] = cmd; callint[id] = it
      # An async call is remembered for its result, which a later pass may read.
      if (index(l, "\"async\":true") > 0) printf "C\t%s\t%s\t%s\n", id, it, cmd
    }
    return
  }
  # Only a record whose own details open with the async object is a spawn; the
  # same text quoted in a tool result (a transcript read, a JSON view) is not.
  if (index(l, "\"details\":{\"async\":{\"state\":\"running\"") > 0) {
    jid = ""; typ = ""; tcid = ""; cmd = ""; it = ""; ts = ""; lim = ""
    if (match(l, /"jobId":"[^"]*"/)) jid = substr(l, RSTART + 9, RLENGTH - 10)
    if (match(l, /"jobId":"[^"]*","type":"[^"]*"/)) { seg = substr(l, RSTART, RLENGTH); if (match(seg, /"type":"[^"]*"/)) typ = substr(seg, RSTART + 8, RLENGTH - 9) }
    if (match(l, /"toolCallId":"[^"]*"/)) tcid = substr(l, RSTART + 14, RLENGTH - 15)
    if (tcid != "" && (tcid in callcmd)) cmd = callcmd[tcid]
    if (tcid != "" && (tcid in callint)) it = callint[tcid]
    if (match(l, /"timestamp":"[^"]*"/)) ts = substr(l, RSTART + 13, RLENGTH - 14)
    if (match(l, /"timeoutSeconds":[0-9]+/)) lim = substr(l, RSTART + 17, RLENGTH - 17)
    if (typ != "task" && jid != "") { alive[jid] = 1; printf "R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", jid, typ, ts, lim, it, cmd, tcid }
    return
  }
  if (index(l, "\"type\":\"session\"") > 0 || index(l, "\"type\":\"session_exit\"") > 0) { printf "Z\n"; split("", alive); return }
  # A job report is a record detail, not a copy of one inside tool output: the
  # async-result delivery (`details.jobs`/`details.meta`), a `wait` result
  # (`details.op = "wait"`) and a `proc://…/kill` cancel (`details.proc.op = "cancel"`).
  if (index(l, "\"jobs\":[") > 0 && (index(l, "\"details\":{\"meta\"") > 0 || index(l, "\"details\":{\"jobs\"") > 0 || index(l, "\"details\":{\"op\":\"wait\"") > 0 || index(l, "\"details\":{\"proc\":{\"op\":\"cancel\"") > 0)) {
    rest = l
    while (match(rest, /"(jobId|id)":"[^"]*"[^}]*"status":"[^"]*"/)) {
      # match() resets RSTART/RLENGTH, so keep the extent of this match first.
      ms = RSTART; ml = RLENGTH
      seg = substr(rest, ms, ml); jid = ""; st = ""
      if (match(seg, /"jobId":"[^"]*"/)) jid = substr(seg, RSTART + 9, RLENGTH - 10)
      else if (match(seg, /"id":"[^"]*"/)) jid = substr(seg, RSTART + 6, RLENGTH - 7)
      if (match(seg, /"status":"[^"]*"/)) st = substr(seg, RSTART + 10, RLENGTH - 11)
      jobdone(jid, st)
      rest = substr(rest, ms + ml)
    }
  }
  # A snapshot comes from the wait tool result itself, not from the same text
  # quoted in another tool output (a transcript read, a note about a past wait).
  if ((index(l, "## Still Running") > 0 || index(l, "## Completed") > 0) && index(l, "\"toolName\":\"wait\"") > 0) {
    t = l; gsub(/\\n/, "\n", t); sections(t)
  }
}
{ if (have) { flush(prev); consumed += length(prev) + 1 } prev = $0; have = 1 }
END {
  if (have && endsnl == 1) { flush(prev); consumed += length(prev) + 1 }
  printf "O\t%d\n", base + consumed

}'
}
find "$d" -maxdepth 1 -name '*.jsonl' ! -name '__*' -mmin -]] .. tostring(SUB_FRESH_MIN) .. [[ | while IFS= read -r f; do
  t=$(tail -n 1 "$f")
  # omp keeps an agent live from its spawn until it parks (idle TTL) or is killed:
  # parking disposes the session and writes `session_exit`, a kill drops a
  # `<transcript>.tombstone` beside it. Anything else is an agent omp still shows.
  case "$t" in *session_exit*) continue ;; esac
  [ -f "$f.tombstone" ] && continue
  # A cancelled task ends on an assistant record with `stopReason:"aborted"`. omp
  # keeps the agent resumable, but it is not working; a resume appends new
  # records and brings it back.
  case "$t" in *'"role":"assistant"'*'"stopReason":"aborted"'*|*'"stopReason":"aborted"'*'"role":"assistant"'*) continue ;; esac
  # A final assistant reply with no tool call pending is an idle agent: its turn
  # ended, the agent is alive until the idle TTL parks it.
  st=running
  case "$t" in *'"role":"assistant"'*'"stopReason":"stop"'*|*'"stopReason":"stop"'*'"role":"assistant"'*) st=idle ;; esac
  n=$(basename "$f" .jsonl)
  i=$(tail -c ]] .. tostring(SUB_INTENT_BYTES) .. [[ "$f" | grep -o '"i":"[^"]*"' | tail -n 1)
  i=${i#\"i\":\"}
  i=${i%\"}
  s=$(head -n 5 "$f" | grep '"type":"session"' | grep -o '"timestamp":"[^"]*"' | head -n 1 | cut -d'"' -f4)
  # The agent role omp spawned it as (`task`, `scout`, `reviewer`, ...) is in its
  # own session_init record, right after the session head.
  r=$(head -n 8 "$f" | grep -o '"agent":"[^"]*","resolvedModel"' | head -n 1 | cut -d'"' -f4)
  [ -z "$r" ] && r=$(head -n 8 "$f" | grep '"type":"session_init"' | grep -o '"agent":"[^"]*"' | head -n 1 | cut -d'"' -f4)
  e=$(date -d "$s" +%s 2>/dev/null)
  # Percent done from the newest todo state: completed of all tasks not abandoned.
  p=
  l=$(tail -c ]] .. tostring(SUB_INTENT_BYTES) .. [[ "$f" | grep '"details":{"op"' | grep '"phases":\[' | tail -n 1)
  if [ -n "$l" ]; then
    l=${l#*\"details\":\{\"op\"}
    l=${l%%\"storage\"*}
    all=$(printf '%s' "$l" | grep -o '"status":"[a-z_]*"' | grep -vc abandoned)
    c=$(printf '%s' "$l" | grep -o '"status":"completed"' | grep -c .)
    [ "${all:-0}" -gt 0 ] && p=$((c * 100 / all))
  fi
  printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$e" "$p" "$st" "$r" "$i"
  # A running subagent's own transcript carries its async jobs; the offset for it
  # arrives in the spec from the last pass.
  ent=$(printf '%s\n' "$spec" | while IFS='|' read -r sp so sl; do [ "$sp" = "$f" ] && { printf '%s|%s' "$so" "$sl"; break; }; done)
  jobscan "$f" "${ent%%|*}" "${ent#*|}" "$n"
done
p="$d.jsonl"
[ -f "$p" ] || exit 0
# The main agent: the task it marked in progress, else the newest intent it stated.
t=$(tail -c 300000 "$p")
ti=$(printf '%s' "$t" | grep '"phases":\[' | tail -n 1 | grep -o '"content":"[^"]*","status":"in_progress"' | head -n 1 | cut -d'"' -f4)
[ -n "$ti" ] && printf 'T\t%s\n' "$ti"
mi=$(printf '%s' "$t" | grep -o '"i":"[^"]*"' | tail -n 1 | cut -d'"' -f4)
[ -n "$mi" ] && printf 'M\t%s\n' "$mi"
jobscan "$p" "${2:-0}" "${3:-}" ""]]

-- "5h10m", "3m20s", "45s": the two largest units.
local function elapsed(secs: number): string
	secs = math.max(0, math.floor(secs))
	local h, m, s = secs // 3600, (secs % 3600) // 60, secs % 60
	if h > 0 then
		return string.format("%dh%dm", h, m)
	elseif m > 0 then
		return string.format("%dm%ds", m, s)
	end
	return string.format("%ds", s)
end

-- "2026-11-10T17:23:08.012Z" -> epoch seconds. omp writes UTC, and os.time reads a
-- broken-down table as local time, so the civil-date arithmetic is done here.
local function epoch_of(iso: string?): number?
	if type(iso) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
	if not y then
		return nil
	end
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	local yy = if month <= 2 then year - 1 else year
	local era = math.floor(yy / 400)
	local yoe = yy - era * 400
	local doy = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)
end

-- Incremental job state per parent transcript: the byte offset already read, the byte length
-- of line 1 (omp rewrites the title record in place and keeps its length stable
-- with a pad field, so the length is the identity that survives retitles), and
-- the jobs the events have built up. Cached in kv so a reload does not rescan a
-- 47 MB transcript.
type Job = { label: string, intent: string, started: number?, limit: number?, type: string? }
type JobCache = {
	off: number,
	l1: number?,
	order: { string },
	alive: { [string]: boolean },
	jobs: { [string]: Job },
	-- Async tool calls seen before their result, so a result read in a later pass
	-- still knows the command and intent it belongs to.
	pending: { [string]: { label: string, intent: string } },
	pending_order: { string },
}
local KV_JOBS = "agent_nav.jobs"
local JOBS_VERSION = 5
local jobCache: { [string]: JobCache } = {}
local jobsLoaded = false
local lastJobSave = 0
local jobsDirty = false

local function load_jobs()
	if jobsLoaded then
		return
	end
	jobsLoaded = true
	local stored = tern.kv.get(KV_JOBS)
	if type(stored) ~= "table" or stored.v ~= JOBS_VERSION or type(stored.files) ~= "table" then
		return
	end
	for path, c in stored.files do
		if type(path) == "string" and type(c) == "table" and type(c.jobs) == "table" and type(c.order) == "table" then
			jobCache[path] = {
				off = tonumber(c.off) or 0,
				l1 = tonumber(c.l1),
				order = c.order,
				alive = if type(c.alive) == "table" then c.alive else {},
				jobs = c.jobs,
				pending = if type(c.pending) == "table" then c.pending else {},
				pending_order = if type(c.pending_order) == "table" then c.pending_order else {},
			}
		end
	end
end

local function job_state(path: string): JobCache
	load_jobs()
	local c = jobCache[path]
	if not c then
		c = { off = 0, l1 = nil, order = {}, alive = {}, jobs = {}, pending = {}, pending_order = {} }
		jobCache[path] = c
	end
	return c
end

-- A job with no settled record and its own deadline long past went down with the
-- process that ran it: omp ends a job at its deadline, and the transcript then
-- only ever says "running".
local function job_dead(job: Job, now: number): boolean
	local started = job.started
	if not started then
		return false
	end
	local limit = job.limit or 0
	return now - started > (if limit > 0 then limit else 21600) + 120
end

-- The jobs a cached transcript is running, as row lines.
local function alive_jobs(path: string?, now: number): { Sub }
	local out: { Sub } = {}
	if not path then
		return out
	end
	local c = jobCache[path]
	if not c then
		return out
	end
	for _, jid in c.order do
		local job = c.jobs[jid]
		if job and c.alive[jid] and not job_dead(job, now) then
			-- The command is the label; the intent, when omp recorded one, is the
			-- line under it.
			local full = clip(job.label or "", 200)
			table.insert(out, {
				name = if full ~= "" then full else jid,
				title = if full ~= "" then full else nil,
				doing = clip(job.intent or "", SUB_TEXT_MAX),
				started = job.started,
				job = true,
			})
		end
	end
	return out
end

local function parse_scan(stdout: string, parent: string): Scan
	local items: { Sub } = {}
	local main_intent: string? = nil
	local main_todo: string? = nil
	local changed = false
	local dir = string.sub(parent, 1, #parent - 6)
	-- `J` names the transcript the events below came from: the parent itself, or a
	-- running subagent's own file, whose jobs nest under that subagent.
	local cur = parent
	local sub_path: { [string]: string } = {}
	local function cache_of(): JobCache
		return job_state(cur)
	end
	for line in string.gmatch(stdout .. "\n", "([^\n]*)\n") do
		-- Event names are one letter or two (L1), never a word.
		local kind, rest = string.match(line, "^(%a%d?)\t?(.*)$")
		if kind == "J" then
			if rest == "" then
				cur = parent
			else
				cur = dir .. "/" .. rest .. ".jsonl"
				sub_path[rest] = cur
			end
		elseif kind == "S" then
			local name, started, pct, state, role, doing = string.match(rest, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
			if name and name ~= "" then
				table.insert(items, {
					name = clip(name, 40),
					doing = clip(doing, SUB_TEXT_MAX),
					started = tonumber(started),
					pct = tonumber(pct),
					state = state,
					role = if role ~= "" then clip(role, 20) else nil,
				})
			end
		elseif kind == "F" then
			-- The file was rewritten under the cache: start over.
			local c = cache_of()
			c.order, c.alive, c.jobs, c.off = {}, {}, {}, 0
			c.pending, c.pending_order = {}, {}
			changed = true
		elseif kind == "L1" then
			local c = cache_of()
			local l1 = tonumber(rest)
			if l1 ~= c.l1 then
				c.l1 = l1
				changed = true
			end
		elseif kind == "O" then
			local c = cache_of()
			local off = tonumber(rest)
			if off and off ~= c.off then
				c.off = off
				changed = true
			end
		elseif kind == "C" then
			local tcid, intent, label = string.match(rest, "^([^\t]*)\t([^\t]*)\t(.*)$")
			if tcid and tcid ~= "" then
				local c = cache_of()
				if not c.pending[tcid] then
					table.insert(c.pending_order, tcid)
				end
				c.pending[tcid] = { label = label or "", intent = intent or "" }
				while #c.pending_order > 200 do
					local old = table.remove(c.pending_order, 1) :: string
					c.pending[old] = nil
				end
				changed = true
			end
		elseif kind == "R" then
			local jid, jtype, ts, limit, intent, label, tcid = string.match(rest, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
			-- Agent jobs are the session files themselves; only programs land here.
			if jid and jid ~= "" and jtype ~= "task" then
				local c = cache_of()
				local job = c.jobs[jid]
				if not job then
					job = { label = "", intent = "", type = jtype }
					c.jobs[jid] = job
					table.insert(c.order, jid)
				end
				-- The call and its result can land in different passes.
				local called = if tcid then c.pending[tcid] else nil
				job.type = jtype
				job.started = epoch_of(ts) or job.started
				job.limit = tonumber(limit) or job.limit
				if label and label ~= "" then
					job.label = label
				elseif called and called.label ~= "" then
					job.label = called.label
				end
				if intent and intent ~= "" then
					job.intent = intent
				elseif called and called.intent ~= "" then
					job.intent = called.intent
				end
				c.alive[jid] = true
				changed = true
			end
		elseif kind == "D" then
			local c = cache_of()
			local jid = string.match(rest, "^([^\t]*)")
			if jid and c.alive[jid] then
				c.alive[jid] = false
				changed = true
			end
		elseif kind == "K" then
			-- The wait tool's snapshot: what it lists is what is running.
			cache_of().alive = {}
			changed = true
		elseif kind == "E" then
			local jid, jtype, intent, label = string.match(rest, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
			if jid and jid ~= "" and jtype ~= "task" then
				local c = cache_of()
				local job = c.jobs[jid]
				if not job then
					job = { label = "", intent = "", type = jtype }
					c.jobs[jid] = job
					table.insert(c.order, jid)
				end
				if label and label ~= "" then
					job.label = label
				end
				if intent and intent ~= "" then
					job.intent = intent
				end
				c.alive[jid] = true
				changed = true
			end
		elseif kind == "Z" then
			cache_of().alive = {}
			changed = true
		elseif kind == "M" then
			main_intent = rest
		elseif kind == "T" then
			main_todo = rest
		end
	end
	-- Keep each cache bounded: the oldest settled ids fall off first.
	local now = os.time()
	for _, c in jobCache do
		if #c.order > 400 then
			while #c.order > 400 do
				local jid = table.remove(c.order, 1) :: string
				c.jobs[jid] = nil
				c.alive[jid] = nil
			end
			changed = true
		end
	end
	-- A running subagent carries its own async jobs, one indent deeper.
	local running: { [string]: boolean } = {}
	for _, item in items do
		local path = sub_path[item.name]
		if path then
			running[path] = true
			local jobs = alive_jobs(path, now)
			if #jobs > 0 then
				item.jobs = jobs
			end
		end
	end
	-- A subagent that is no longer running keeps no job cache.
	for path in jobCache do
		if path ~= parent and string.sub(path, 1, #dir + 1) == dir .. "/" and not running[path] then
			jobCache[path] = nil
			changed = true
		end
	end
	for _, job in alive_jobs(parent, now) do
		if #items < SUB_MAX then
			table.insert(items, job)
		end
	end
	while #items > SUB_MAX do
		table.remove(items)
	end
	local main: string? = nil
	local text = main_todo or main_intent
	if text and text ~= "" then
		main = clip(text, 100)
	end
	return { items = items, main = main, changed = changed }
end

-- One shell pass for one session directory; the panes that share it get its list.
local function scan_subagents(dir: string, panes: { number })
	if subScanning[dir] then
		return
	end
	subScanning[dir] = true
	local parent = dir .. ".jsonl"
	local cache = job_state(parent)
	local line1 = if cache.l1 then tostring(cache.l1) else ""
	-- The byte already read from every transcript this pass will touch: the parent
	-- and the subagent files, which share the one shell pass.
	local spec: { string } = {}
	for path, c in jobCache do
		if string.sub(path, 1, #dir + 1) == dir .. "/" then
			table.insert(spec, path .. "|" .. tostring(c.off) .. "|" .. (if c.l1 then tostring(c.l1) else ""))
		end
	end
	local args = { "sh", "-c", SUB_SCAN, "sh", dir, tostring(cache.off), line1, table.concat(spec, "\n") }
	local ok = pcall(function()
		tern.process.run(args, { timeout_ms = 20000 }, function(r, cx)
			subScanning[dir] = nil
			if r.status ~= 0 then
				return
			end
			local scan = parse_scan(if type(r.stdout) == "string" then r.stdout else "", parent)
			local items = scan.items
			if scan.changed then
				jobsDirty = true
			end
			-- Saved within a few seconds of a change, not on every pass.
			if jobsDirty and os.time() - lastJobSave > 10 then
				lastJobSave = os.time()
				jobsDirty = false
				tern.kv.set(KV_JOBS, { v = JOBS_VERSION, files = jobCache })
			end
			local changed = false
			for _, pane in panes do
				if subDirs[pane] == dir then
					local before = subItems[pane]
					if not before or #before ~= #items or mainDoing[pane] ~= scan.main then
						changed = true
					else
						for index, item in items do
							local was = before[index]
							if was.name ~= item.name or was.doing ~= item.doing or was.state ~= item.state then
								changed = true
							end
							local old_jobs = was.jobs or {}
							local new_jobs = item.jobs or {}
							if #old_jobs ~= #new_jobs then
								changed = true
							else
								for j = 1, #new_jobs do
									if old_jobs[j].name ~= new_jobs[j].name or old_jobs[j].doing ~= new_jobs[j].doing then
										changed = true
									end
								end
							end
						end
					end
					subItems[pane] = items
					mainDoing[pane] = scan.main
				end
			end
			if changed and cx then
				refresh(cx)
			end
		end)
	end)
	if not ok then
		subScanning[dir] = nil
	end
end

-- Every SUB_POLL_MS: which panes run omp, and where their session directories are.
local function poll_subagents(cx: WindowCx?)
	tern.timer(SUB_POLL_MS, poll_subagents)
	if not cx or not enabled() or subInspecting or next(railTab) == nil then
		return
	end
	subInspecting = true
	local ok = pcall(function()
		tern.process.run({ tern_cli(), "inspect", "--json" }, { timeout_ms = 8000 }, function(r, _cx)
			subInspecting = false
			if r.status ~= 0 or type(r.stdout) ~= "string" then
				return
			end
			local okj, doc = pcall(tern.json.decode, r.stdout)
			if not okj or type(doc) ~= "table" or type(doc.panes) ~= "table" then
				return
			end
			local fresh: { [number]: string } = {}
			local by_dir: { [string]: { number } } = {}
			local dirs: { string } = {}
			for _, pane in doc.panes do
				local file = pane.omp_session_file
				if type(file) == "string" and file ~= "" then
					local dir = string.match(file, "^(.*)%.jsonl$")
					if dir and type(pane.pane) == "number" then
						if not by_dir[dir] then
							by_dir[dir] = {}
							table.insert(dirs, dir)
						end
						table.insert(by_dir[dir], pane.pane)
						fresh[pane.pane] = dir
					end
				end
			end
			-- A pane that no longer runs omp keeps no subagent list.
			for pane in subDirs do
				if not fresh[pane] then
					subItems[pane] = nil
					mainDoing[pane] = nil
				end
			end
			subDirs = fresh
			for _, dir in dirs do
				scan_subagents(dir, by_dir[dir])
			end
		end)
	end)
	if not ok then
		subInspecting = false
	end
end

--------------------------------------------------------------------------------
-- Manual order
--------------------------------------------------------------------------------
-- The canvas delivers clicks only, so a row is moved by click: shift-click picks
-- one up, clicking another row drops it directly above that row, and the picked
-- row or a plain click on it cancels. The order is a list of pane ids; panes it
-- does not list follow in their native order.

local KV_ORDER = "agent_nav.order"

-- The pane picked up with shift-click, drawn highlighted until it is dropped.
local carry: number? = nil
-- The pane order of the last draw, which a drop rearranges.
local shownOrder: { number } = {}

local function manual_order(): { number }
	local stored = tern.kv.get(KV_ORDER)
	local out: { number } = {}
	if type(stored) == "table" then
		for _, pane in stored do
			if valid_id(pane) then
				table.insert(out, pane)
			end
		end
	end
	return out
end

-- Move `pane` directly above `target` in the order the rail shows, keeping panes
-- the last draw did not show where they were.
local function move_above(pane: number, target: number)
	if pane == target then
		return
	end
	local list: { number } = {}
	local placed = false
	for _, id in shownOrder do
		if id == pane then
			-- Inserted below, above the target.
		elseif id == target then
			if not placed then
				table.insert(list, pane)
				placed = true
			end
			table.insert(list, target)
		else
			table.insert(list, id)
		end
	end
	if not placed then
		table.insert(list, pane)
	end
	local listed: { [number]: boolean } = {}
	for _, id in list do
		listed[id] = true
	end
	for _, id in manual_order() do
		if not listed[id] then
			table.insert(list, id)
			listed[id] = true
		end
	end
	tern.kv.set(KV_ORDER, list)
end

-- A closed pane leaves the order.
local function forget_order(pane: number)
	local list = manual_order()
	local out: { number } = {}
	for _, id in list do
		if id ~= pane then
			table.insert(out, id)
		end
	end
	if #out ~= #list then
		tern.kv.set(KV_ORDER, out)
	end
end

-- A pane-keyed class name, so a row can be addressed by the pane it shows.
local function pane_class(kind: string, pane: number): string
	return "agent-nav-" .. kind .. "-" .. tostring(pane)
end

-- A row's directory as the group label shows it: HOME shortened, and a pane whose
-- directory the OS could not read still gets a label.
local function display_cwd(cwd: string?): string
	local home = tern.getenv("HOME")
	if type(cwd) ~= "string" or cwd == "" then
		return "(unknown)"
	end
	if type(home) == "string" and home ~= "" and string.sub(cwd, 1, #home) == home then
		return "~" .. string.sub(cwd, #home + 1)
	end
	return cwd
end

local function norm_line(s: string): string
	return string.lower(string.match(s, "^%s*(.-)%s*$") or s)
end

-- Two lines of one row saying the same thing: equal, or one a leading slice of the
-- other, so a job's second line repeating its label, or a doing line repeating the
-- title, is dropped instead of printed twice.
local function same_line(a: string, b: string): boolean
	local x, y = norm_line(a), norm_line(b)
	if x == "" or y == "" then
		return false
	end
	if x == y then
		return true
	end
	local short, long = x, y
	if #short > #long then
		short, long = long, short
	end
	-- A near-duplicate, not two lines that merely open with the same words.
	return #short >= 6 and #long - #short <= 12 and string.sub(long, 1, #short) == short
end

-- A job's command as a row label: a leading cd, env assignment or timeout says
-- nothing about the job, and the rest is clipped to a cell or two.
local function short_command(cmd: string): string
	local s = string.match(cmd, "^%s*(.-)%s*$") or cmd
	for _ = 1, 8 do
		local rest = string.match(s, "^cd%s+[^%s;&|]+%s*&&%s*(.+)$")
			or string.match(s, "^cd%s+[^%s;&|]+%s*;%s*(.+)$")
			or string.match(s, "^cd%s+\"[^\"]*\"%s*&&%s*(.+)$")
			or string.match(s, "^cd%s+\"[^\"]*\"%s*;%s*(.+)$")
			or string.match(s, "^[%a_][%w_]*=[^%s;&|]+%s+(.+)$")
			or string.match(s, "^timeout%s+%-?[%d%.]+[a-z]*%s+(.+)$")
		if not rest then
			break
		end
		s = rest
	end
	s = string.match(s, "^%s*(.-)%s*$") or s
	local n = utf8.len(s)
	if n and n > 32 then
		s = string.sub(s, 1, (utf8.offset(s, 32) :: number) - 1) .. "…"
	end
	return s
end

local function agent_row_node(ag: AgentRow): Node
	local action_key = goto_key(ag.session, ag.pane)
	local kept: { string } = { ag.title }
	local text_nodes: { Node } = { ui.el("span", { class = "agent-nav-title", text = ag.title }) }
	-- A line already said by this row is not printed again.
	local function fresh(text: string?): boolean
		if type(text) ~= "string" or text == "" then
			return false
		end
		for _, other in kept do
			if same_line(text, other) then
				return false
			end
		end
		table.insert(kept, text)
		return true
	end
	-- The agent's own line: its in-progress task, else the intent it last stated.
	if fresh(ag.doing) then
		table.insert(text_nodes, ui.el("span", { class = "agent-nav-doing", text = ag.doing }))
	end
	-- A subagent line, and one indent deeper a job it runs.
	local function sub_node(sub: Sub, nested: boolean): Node
		local label = if sub.job then short_command(sub.name) else sub.name
		-- An idle agent's clock is not ticking: it waits for the idle TTL or a
		-- message, so it shows neither elapsed nor percent.
		local idle = sub.state == "idle"
		local meta: { string } = {}
		if sub.started and not idle then
			table.insert(meta, elapsed(os.time() - sub.started))
		end
		-- A program job has no percent: its share of a todo list is not its progress.
		if sub.pct and not sub.job and not idle then
			table.insert(meta, tostring(sub.pct) .. "%")
		end
		-- One row: name, the agent role it was spawned as, then the clock.
		local head: { Node } = { ui.el("span", { class = "agent-nav-sub-name", text = label }) }
		if sub.role and sub.role ~= "" then
			table.insert(head, ui.el("span", { class = "agent-nav-sub-role", text = sub.role }))
		end
		if #meta > 0 then
			table.insert(head, ui.el("span", { class = "agent-nav-sub-meta", text = "(" .. table.concat(meta, ", ") .. ")" }))
		end
		local children: { Node } = { ui.el("span", { class = "agent-nav-sub-head" }, head) }
		table.insert(kept, label)
		table.insert(kept, sub.name)
		if fresh(sub.doing) then
			table.insert(children, ui.el("span", { class = "agent-nav-sub-doing", text = sub.doing }))
		end
		return ui.el("span", {
			class = if nested then "agent-nav-sub is-job" elseif idle then "agent-nav-sub is-idle" else "agent-nav-sub",
			-- The full command stays reachable on hover.
			attrs = if sub.title then { title = sub.title } else nil,
		}, children)
	end
	for _, sub in ag.subagents do
		-- An idle agent with nothing running is done for the user, even though
		-- omp keeps it messageable until its TTL parks it. One still waiting on
		-- its own background jobs will be woken by them, so it stays listed.
		if sub.state == "idle" and next(sub.jobs or {}) == nil then
			continue
		end
		-- One block per subagent: its line, what it is doing, and its jobs.
		local block: { Node } = { sub_node(sub, false) }
		local shown = 0
		for _, job in sub.jobs or {} do
			shown += 1
			if shown > SUB_JOBS_PER_AGENT then
				break
			end
			table.insert(block, sub_node(job, true))
		end
		table.insert(text_nodes, ui.el("div", { class = "agent-nav-block" }, block))
	end
	return ui.el("button", {
		key = action_key,
		actions = { click = action_key },
		class = "agent-nav-agent status-" .. ag.status
			.. (if ag.is_current then " is-current" else "")
			.. (if carry == ag.pane then " is-carried" else "")
			.. " " .. pane_class("row", ag.pane),
		attrs = { title = ag.title .. " · " .. ag.status, ["data-pane"] = tostring(ag.pane) },
	}, {
		ui.el("span", { class = "agent-nav-text" }, text_nodes),
	})
end

local function build_view(cx: WindowCx): Node
	if next(sampledPanes) == nil then
		sample_status(cx)
	end

	-- Native order: session order, then tab position, then the window's own pane
	-- order. The manual order overrides it for the panes it lists.
	local session_rank: { [number]: number } = {}
	local tab_rank: { [number]: number } = {}
	local tab_session: { [number]: number } = {}
	local index = 0
	for _, s in cx.session:sessions() do
		index += 1
		session_rank[s.id] = index
		local position = 0
		for _, id in s.tabs do
			position += 1
			tab_rank[id] = position
			tab_session[id] = s.id
		end
	end
	local position_of: { [number]: number } = {}
	for position, pane in manual_order() do
		position_of[pane] = position
	end

	local rows: { AgentRow } = {}
	local row_index = 0
	for _, p in cx.session:panes() do
		local sid = p.tab and tab_session[p.tab]
		if sid and is_navigable_pane(p) then
			row_index += 1
			local harness, icon = detect_harness(p)
			-- A listed agent whose harness is no longer named anywhere keeps the
			-- harness it was last shown with.
			local listed = listedAgents[p.pane]
			if listed and (harness == "terminal" or harness == "agent") then
				harness, icon = listed.harness, listed.icon
			end
			-- The window's own focus flag, not a pane-id comparison: the id
			-- from cx.session:focused() can be truncated (stencil-hq/tern-sdk#30).
			local is_focused = p.focused == true

			local sampled = sampledPanes[p.pane]
			local is_running = if sampled then sampled.is_running else false
			local ag_state = if sampled then sampled.ag_state else nil

			-- Status precedence:
			-- 1. Attention (waiting for user input / approval): purple
			-- 2. Running: amber/yellow with text shimmer
			-- 3. Error: red (nonzero native exited or error outranks unread)
			-- 4. Done unread: emerald green
			-- 5. Done read / idle: muted secondary text
			local status = "done-read"
			if ag_state == "waiting_input" then
				status = "attention"
			elseif is_running then
				status = "running"
			elseif p.error or (p.exited and p.exited ~= 0) then
				status = "error"
			elseif not is_focused and (unreadPanes[p.pane] or p.alert) then
				status = "done-unread"
			else
				status = "done-read"
			end

			-- omp writes its session title into the pane title once it has one; an
			-- untitled omp session keeps the program name.
			local _, title = spinnerTitle(p.title)
			title = strip_leading_glyphs(title)
			-- An agent that stopped titling its pane keeps the title it last had.
			if (not title or title == "") and listed then
				title = listed.title
			end
			if not title or title == "" then
				title = if harness == "omp" then "omp" else (p.cwd and string.match(p.cwd, "([^/\\]+)$") or ("Pane " .. tostring(p.pane)))
			end

			table.insert(rows, {
				pane = p.pane,
				session = sid,
				tab = p.tab,
				title = title,
				cwd = p.cwd,
				doing = if is_running then mainDoing[p.pane] else nil,
				subagents = subagents_of(p.pane),
				status = status,
				is_current = is_focused,
				rank = (session_rank[sid] or 0) * 1000000 + (tab_rank[p.tab] or 0) * 1000 + row_index,
			})
			-- Remember the row, so a pane whose harness stops being named keeps its
			-- row and label here and after a Tern restart. The timestamp is
			-- refreshed hourly so a live pane's entry never ages out.
			if not listed or listed.harness ~= harness or listed.icon ~= icon
				or listed.title ~= title or tern.now() - listed.at > SEEN_TOUCH_MS then
				listedAgents[p.pane] = { harness = harness, icon = icon, title = title, at = tern.now() }
				seenDirty = true
			end
		end
	end

	-- A manual position wins; unlisted rows keep their native order after it.
	table.sort(rows, function(a: AgentRow, b: AgentRow): boolean
		local pa, pb = position_of[a.pane], position_of[b.pane]
		if pa and pb then
			return pa < pb
		end
		if pa or pb then
			return pa ~= nil
		end
		return if a.rank ~= b.rank then a.rank < b.rank else a.pane < b.pane
	end)

	-- Rows that share a directory form one group: the directory prints once, as a
	-- label, and its rows follow with titles only. The flat row order decides both
	-- the group order (by each group's first row) and the order inside a group.
	shownOrder = {}
	local groups: { { cwd: string, rows: { AgentRow } } } = {}
	local group_of: { [string]: number } = {}
	for _, ag in rows do
		table.insert(shownOrder, ag.pane)
		local cwd = display_cwd(ag.cwd)
		local at = group_of[cwd]
		if not at then
			table.insert(groups, { cwd = cwd, rows = {} })
			at = #groups
			group_of[cwd] = at
		end
		table.insert(groups[at].rows, ag)
	end
	local list: { Node } = {}
	for _, group in groups do
		table.insert(list, ui.el("div", {
			class = "agent-nav-cwd-group",
			attrs = { title = group.cwd },
			text = group.cwd,
		}))
		for _, ag in group.rows do
			table.insert(list, agent_row_node(ag))
		end
	end
	if #list == 0 then
		table.insert(list, ui.el("div", { class = "agent-nav-empty", text = "No agent sessions active" }))
	end
	return ui.el("div", { class = "agent-nav-root" }, list)
end

--------------------------------------------------------------------------------
-- Draw
--------------------------------------------------------------------------------

-- Rail pane -> the encoded view it shows, so an unchanged rail is not set again.
local renderedKey: { [number]: string } = {}
-- Set when a pass leaves rails to open, move, fit or redraw: a follow-up pass
-- runs after FAST_TICK_MS instead of waiting for the next tick.
local moreWork = false
-- Wall time one draw may spend setting background rails; the rest follow.
local DRAW_BUDGET_MS = 40

local function set_view(cx: WindowCx, pane: number, view: Node, key: string)
	-- A rail closed since the last placement pass fails here; that pass forgets it.
	local ok = pcall(function()
		cx.canvas:set(pane, { view = view })
	end)
	renderedKey[pane] = if ok then key else nil
end

-- Status sampling runs on every draw. Every rail shows the same view; only the
-- rails whose view changed are set, the shown tab's first.
local function draw(cx: WindowCx)
	sample_status(cx)
	if next(railTab) == nil then
		return
	end
	local view = build_view(cx)
	local key = tern.json.encode(view)
	local shownRail = if lastShown then railOf[lastShown] else nil
	if shownRail and renderedKey[shownRail] ~= key then
		set_view(cx, shownRail, view, key)
	end
	local start = tern.now()
	for pane in railTab do
		if renderedKey[pane] ~= key then
			if tern.now() - start > DRAW_BUDGET_MS then
				moreWork = true
				return
			end
			set_view(cx, pane, view, key)
		end
	end
end

--------------------------------------------------------------------------------
-- Rails
--------------------------------------------------------------------------------
-- A rail opens beside the content leaf on the configured edge at the remembered
-- share, so a tab that held one pane gets a full-height rail and later splits
-- happen inside its content side. A tab that already held several panes gets its
-- rail beside the edge one, and that rail's width is left alone.

-- Canvas opens per pass: many tabs at once must not hold one callback past
-- Tern's wall-time cap.
local MAX_OPENS = 2
-- Tabs fitted to the remembered share per pass.
local MAX_FITS = 3
-- A rail share change at most this large is cell rounding, not a drag; a tab
-- whose rail is further off the remembered share is fitted again. One value for
-- both, so a tab is never left visibly off because the trigger was coarser than
-- the fit can reach.
local SHARE_TOL = 0.005
-- How long a dragged share must hold still before it is remembered.
local SETTLE_MS = 400
-- How long a rail must stay missing from an open tab to count as closed by the user.
local VANISH_MS = 500

-- Tabs where cx.canvas:open failed (an unavailable host); retried only after the
-- rails are switched on again or the tab is gone.
local openFailed: { [number]: boolean } = {}
-- Rail -> the edge it was last seen on. A rail that changes edge was moved by the
-- user; one that never did predates a side switch.
local railSide: { [number]: Side } = {}
-- Tab -> the rail share last seen or set there; a later difference is a drag.
local seenShare: { [number]: number } = {}
-- Tab -> the remembered share its last fit aimed at, so a tab held by native
-- minimum pane sizes is not pushed again until the share changes.
local fitFor: { [number]: number } = {}
-- Rails missing from a tab that is still open, with that tab and when they went.
local vanished: { [number]: { tab: number, at: number } } = {}
-- A shown-tab share that differs from seenShare, until it holds still.
local pendingDrag: { tab: number, share: number, at: number }? = nil
-- Set by Reset Width: the next pass fits the shown tab too.
local fitShownNext = false
local placing = false
local kickPending = false

local function own_rail(c: CanvasInfo): boolean
	return c.owner == tern.plugin.id and c.title == TITLE
end

local function close_all(cx: WindowCx)
	for _, c in cx.canvas:list() do
		if own_rail(c) then
			cx.layout:close(c.pane)
		end
	end
	railOf, railTab, vanished = {}, {}, {}
	pendingDrag = nil
end

-- The tiled leaf on the tab's `s` edge, rails skipped; of two stacked panes the
-- taller one.
local function edge_leaf(node: any, s: Side, rails: { [number]: boolean }, depth: number?): number?
	local d = depth or 0
	if type(node) ~= "table" or d > MAX_TREE_DEPTH + 1 then
		return nil
	end
	local pane = node.pane
	if pane ~= nil then
		return if rails[pane] then nil else pane
	end
	local a, b = node[1], node[2]
	local outer = if node.split == "right" then s == "left" else (node.ratio or 0.5) >= 0.5
	if not outer then
		a, b = b, a
	end
	return edge_leaf(a, s, rails, d + 1) or edge_leaf(b, s, rails, d + 1)
end

-- True when `pane` is a leaf of `node`.
local function contains(node: any, pane: number, depth: number?): boolean
	local d = depth or 0
	if type(node) ~= "table" or d > MAX_TREE_DEPTH + 1 then
		return false
	end
	if node.pane ~= nil then
		return node.pane == pane
	end
	return contains(node[1], pane, d + 1) or contains(node[2], pane, d + 1)
end

-- A rail's edge, its share of the whole tab width, and whether it is the first
-- child of the horizontal split that sets that width. A rail beside the edge pane
-- of a multi-pane tab sits deep in the tree, so its own split ratio is not its
-- width: the share is the product of the horizontal split ratios along the path
-- from the root, which is what `agent_nav.share` means everywhere else.
local function rail_geometry(root: any, rail: number): (Side?, number?, boolean?)
	local node = root
	local width = 1
	local first: boolean? = nil
	local depth = 0
	while type(node) == "table" and depth <= MAX_TREE_DEPTH + 1 do
		depth += 1
		if node.pane ~= nil then
			if node.pane ~= rail then
				return nil, nil, nil
			end
			break
		end
		local split = node.split
		if split ~= "right" and split ~= "down" then
			return nil, nil, nil
		end
		local ratio = if type(node.ratio) == "number" and node.ratio > 0 and node.ratio < 1 then node.ratio else 0.5
		local a, b = node[1], node[2]
		local inA = contains(a, rail)
		if not inA and not contains(b, rail) then
			return nil, nil, nil
		end
		if split == "right" then
			-- Only a horizontal split changes the rail's width.
			width *= if inA then ratio else 1 - ratio
			first = inA
		end
		node = if inA then a else b
	end
	if first == nil then
		return nil, nil, nil
	end
	local s: Side = if first then "left" else "right"
	return s, width, first
end

local function current_share(cx: WindowCx, tab: number, rail: number): (Side?, number?, boolean?)
	local layout = cx.session:layout(tab)
	if not layout then
		return nil, nil, nil
	end
	return rail_geometry(layout.root, rail)
end

-- Grow or shrink a rail toward `want`, its share of the tab width: a one-cell
-- push measures what a cell is worth there, then one push covers the rest. Works
-- the same for a rail that is a child of the root and for one nested beside the
-- edge pane of a multi-pane tab. Returns the share reached.
local function fit_rail(cx: WindowCx, tab: number, rail: number, want: number): number?
	local s, share, first = current_share(cx, tab, rail)
	if not s or not share or first == nil then
		return nil
	end
	local cur = share
	local dir: Dir = if first then "right" else "left"
	local cells = if want > cur then 1 else -1
	for _ = 1, 4 do
		if math.abs(want - cur) <= SHARE_TOL then
			break
		end
		local before = cur
		local moved = cx.layout:resize(rail, dir, cells)
		local afterSide, after = current_share(cx, tab, rail)
		if afterSide ~= s or not after then
			return nil
		end
		cur = after
		if not moved or math.abs(cur - before) < 1e-9 then
			break -- a native minimum pane size holds it here
		end
		cells = math.round((want - cur) / math.abs((cur - before) / cells))
		if cells == 0 then
			break
		end
	end
	return cur
end

-- A share the user dragged in `tab` becomes the remembered share once it holds
-- still for SETTLE_MS, or at once when `settled` (the tab was left).
local function note_drag(cx: WindowCx, tab: number, settled: boolean)
	local rail = railOf[tab]
	local seen = seenShare[tab]
	if not rail or not seen then
		return
	end
	local _, cur = current_share(cx, tab, rail)
	if not cur or math.abs(cur - seen) <= SHARE_TOL then
		pendingDrag = nil
		return
	end
	if not settled then
		local pending = pendingDrag
		if not pending or pending.tab ~= tab or math.abs(pending.share - cur) > SHARE_TOL then
			pendingDrag = { tab = tab, share = cur, at = tern.now() }
			return
		end
		if tern.now() - pending.at < SETTLE_MS then
			return
		end
	end
	pendingDrag = nil
	seenShare[tab] = cur
	tern.kv.set(KV_SHARE, clampShare(cur))
end

-- Warn if pane ID exceeds 44 bits (Tern upstream issue stencil-hq/tern-sdk#30).
local function idsResolve(cx: WindowCx): boolean
	local focused = cx.session:focused()
	if not focused or cx.session:pane(focused) then
		return true
	end
	if not warnedIds then
		warnedIds = true
		tern.log.warn("Agent Nav: window API cannot resolve focused pane ID " .. tostring(focused))
		cx:toast("error", "Agent Nav: Cannot position panel",
			"Local pane ID exceeds 44 bits. Tern window API truncates it so lookups return nil (cx.session:pane returns nil). Move/resize operations are disabled by upstream Tern bug #30.")
	end
	return false
end

type Open = { tab: number, target: number, old: number? }

-- One placement pass: every tab with content ends up with exactly one rail on the
-- configured edge, a rail left alone in its tab closes, and tabs are fitted to
-- the remembered share. The shown tab is fitted only when `fitShown`, so a
-- divider under the user's hand is never pulled back.
local function ensure_rails(cx: WindowCx, shown: number?, fitShown: boolean)
	local rails: { [number]: boolean } = {}
	local byTab: { [number]: { number } } = {}
	for _, c in cx.canvas:list() do
		if own_rail(c) then
			rails[c.pane] = true
			local tab = cx.session:tab_of(c.pane)
			if not tab then
				-- Parked: it belongs to no tab.
				cx.layout:close(c.pane)
			elseif byTab[tab] then
				table.insert(byTab[tab], c.pane)
			else
				byTab[tab] = { c.pane }
			end
		end
	end

	local tabs = cx.session:tabs()
	local exists: { [number]: boolean } = {}
	for _, info in tabs do
		exists[info.id] = true
	end
	-- A rail that stays missing from a tab that is still open was closed by the
	-- user, which switches the rails off as Toggle does. Closing a whole tab
	-- takes the tab with it, so that never counts.
	local now = tern.now()
	for pane, tab in railTab do
		if not rails[pane] and not vanished[pane] then
			vanished[pane] = { tab = tab, at = now }
		end
	end
	local waiting: { [number]: boolean } = {}
	for pane, gone in vanished do
		if rails[pane] or not exists[gone.tab] or byTab[gone.tab] then
			vanished[pane] = nil
		elseif now - gone.at >= VANISH_MS then
			setEnabled(false)
			close_all(cx)
			return
		else
			waiting[gone.tab] = true
		end
	end

	local s = side()
	local want = storedShare()
	local newOf: { [number]: number } = {}
	local newTab: { [number]: number } = {}
	local opens: { Open } = {}
	local fits = 0
	for _, info in tabs do
		local tab = info.id
		local found = byTab[tab] or {}
		local keep: number? = nil
		for _, pane in found do
			if pane == railOf[tab] then
				keep = pane
			end
		end
		keep = keep or found[1]
		for _, pane in found do
			if pane ~= keep then
				cx.layout:close(pane)
			end
		end
		local layout = cx.session:layout(tab)
		local target = if layout then edge_leaf(layout.root, s, rails) else nil
		if keep and layout and not target and #layout.floats == 0 then
			-- Only the rail is left: closing it closes the tab.
			cx.layout:close(keep)
			keep = nil
		end
		if keep and layout then
			newOf[tab], newTab[keep] = keep, tab
			local at, cur = rail_geometry(layout.root, keep)
			local before = railSide[keep]
			if at then
				railSide[keep] = at
			end
			if at and at ~= s then
				if before and before ~= at then
					-- The user moved this rail to the other edge: every tab follows.
					tern.kv.set(KV_SIDE, at)
					moreWork = true
				elseif target then
					table.insert(opens, { tab = tab, target = target, old = keep })
				end
			elseif cur then
				seenShare[tab] = seenShare[tab] or cur
				local off = math.abs(cur - want) > SHARE_TOL and fitFor[tab] ~= want
				if off and tab == shown and fitShown then
					-- The tab being shown is fitted before the draw, so a switch never
					-- paints a width another tab's drag has already replaced.
					fitFor[tab] = want
					seenShare[tab] = fit_rail(cx, tab, keep, want) or cur
				elseif off and fits < MAX_FITS then
					fits += 1
					fitFor[tab] = want
					seenShare[tab] = fit_rail(cx, tab, keep, want) or cur
				elseif off then
					moreWork = true
				end
			end
		elseif target and not waiting[tab] and not openFailed[tab] then
			table.insert(opens, { tab = tab, target = target })
		end
	end
	railOf, railTab = newOf, newTab
	if #opens == 0 then
		return
	end

	table.sort(opens, function(a: Open, b: Open): boolean
		return a.tab == shown and b.tab ~= shown
	end)
	local view = build_view(cx)
	local key = tern.json.encode(view)
	for index, op in opens do
		if index > MAX_OPENS then
			moreWork = true
			break
		end
		local old = op.old
		if old then
			-- A side adopted earlier in this pass already put it right.
			if railSide[old] == side() then
				continue
			end
			cx.layout:close(old)
			railOf[op.tab], railTab[old] = nil, nil
		end
		local pane, err = cx.canvas:open({
			title = TITLE,
			about = ABOUT,
			view = view,
			how = "beside",
			target = op.target,
			dir = side(),
			ratio = storedShare(),
			focus = false,
		})
		if pane then
			railOf[op.tab], railTab[pane] = pane, op.tab
			railSide[pane] = side()
			renderedKey[pane] = key
			seenShare[op.tab], fitFor[op.tab] = nil, nil
		else
			openFailed[op.tab] = true
			tern.log.warn("Agent Nav: cannot open a rail in tab " .. tostring(op.tab) .. ": " .. tostring(err))
		end
	end
end

local function place(cx: WindowCx)
	if placing then
		return
	end
	placing = true
	local ok, err = pcall(function()
		if not enabled() then
			close_all(cx)
			return
		end
		if not idsResolve(cx) then
			return
		end
		-- Drop remembered panes this window no longer has, once they are old
		-- enough that another window's live pane is not the reason.
		local present: { [number]: boolean } = {}
		for _, p in cx.session:panes() do
			present[p.pane] = true
		end
		local now = tern.now()
		for pane, entry in listedAgents do
			if not present[pane] and now - entry.at > SEEN_PRUNE_MS then
				listedAgents[pane] = nil
				seenDirty = true
			end
		end
		local shown = shownTab(cx)
		if shown ~= lastShown then
			-- A divider dragged in the tab just left has settled.
			if lastShown then
				note_drag(cx, lastShown, true)
			end
		elseif shown then
			note_drag(cx, shown, false)
		end
		local fitShown = fitShownNext or shown ~= lastShown
		fitShownNext = false
		lastShown = shown
		ensure_rails(cx, shown, fitShown)
	end)
	placing = false
	if not ok then
		tern.log.warn("Agent Nav rails: " .. tostring(err))
	end
end

refresh = function(cx: WindowCx?)
	if not cx then
		return
	end
	moreWork = false
	place(cx)
	local ok, err = pcall(draw, cx)
	if not ok then
		tern.log.warn("Agent Nav draw: " .. tostring(err))
	end
	save_seen()
	if moreWork and not kickPending then
		kickPending = true
		tern.timer(FAST_TICK_MS, function(next_cx: WindowCx?)
			kickPending = false
			refresh(next_cx)
		end)
	end
end

--------------------------------------------------------------------------------
-- Commands & Events
--------------------------------------------------------------------------------

tern.command({
	id = "toggle",
	title = "Agent Nav: Toggle",
	keys = { "ctrl+alt+n" },
	run = function(cx)
		if enabled() then
			setEnabled(false)
			carry = nil
		else
			setEnabled(true)
			warnedIds = false
			openFailed = {}
		end
		refresh(cx)
	end,
})

tern.command({
	id = "toggle_side",
	title = "Agent Nav: Toggle left / right",
	run = function(cx)
		-- A divider just dragged keeps its width on the new side.
		if lastShown then
			note_drag(cx, lastShown, true)
		end
		tern.kv.set(KV_SIDE, if side() == "left" then "right" else "left")
		refresh(cx)
	end,
})

tern.command({
	id = "reset_width",
	title = "Agent Nav: Reset Width",
	run = function(cx)
		tern.kv.set(KV_SHARE, nil)
		pendingDrag = nil
		fitFor = {}
		fitShownNext = true
		refresh(cx)
	end,
})

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if not railTab[ev.pane] then
		local c = cx.canvas:get(ev.pane)
		if not c or not own_rail(c) then
			return false
		end
	end
	local target = tonumber(string.match(ev.act, "^goto:%d+:(%d+)$"))
	if not target then
		return false
	end
	if carry == target then
		-- Shift-click the picked row again, or a plain click on it, puts it down.
		carry = nil
		draw(cx)
		return true
	end
	if carry then
		-- Any row click places the picked row directly above it.
		move_above(carry, target)
		carry = nil
		draw(cx)
		return true
	end
	if ev.mods and table.find(ev.mods, "shift") then
		carry = target
		cx:toast("info", "Agent Nav: picked up", "Click another agent to place it above")
		draw(cx)
		return true
	end
	local session = tonumber(string.match(ev.act, "^goto:(%d+):"))
	if not session then
		return false
	end
	cx.sessions:switch(session)
	cx.layout:focus(target)
	draw(cx)
	return true
end)

tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	refresh(cx)
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	wasRunning[ev.pane] = nil
	everActive[ev.pane] = nil
	listedAgents[ev.pane] = nil
	subItems[ev.pane] = nil
	subDirs[ev.pane] = nil
	seenDirty = true
	unreadPanes[ev.pane] = nil
	sampledPanes[ev.pane] = nil
	renderedKey[ev.pane] = nil
	railSide[ev.pane] = nil
	forget_order(ev.pane)
	if carry == ev.pane then
		carry = nil
	end
	refresh(cx)
end)

tern.on("tab_closed", function(ev: TabEvent, cx: WindowCx)
	seenShare[ev.tab] = nil
	fitFor[ev.tab] = nil
	openFailed[ev.tab] = nil
	refresh(cx)
end)

tern.on("session_ended", function(_ev: SessionEndedEvent, cx: WindowCx)
	refresh(cx)
end)

-- State changes only repaint; they do not open, close or resize rails.
tern.on("agent_state", function(_ev: AgentStateEvent, cx: WindowCx)
	draw(cx)
end)

-- New tabs and panes need rails; titles and finished turns change rows.
for _, name in { "tab_created", "pane_created", "title", "agent_finished" } do
	tern.on(name, function(_ev: any, cx: WindowCx)
		refresh(cx)
	end)
end

-- A window that starts gets a rail in every tab that has content.
tern.on("window_start", function(cx: WindowCx)
	refresh(cx)
end)

local function tick(cx: WindowCx?)
	-- Renew first so a failed sampling hook cannot discard the next refresh.
	tern.timer(TICK_MS, tick)
	refresh(cx)
end
tern.timer(TICK_MS, tick)
-- Subagent session files are polled off the UI path.
tern.timer(SUB_POLL_MS, poll_subagents)
