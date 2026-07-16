--[[ ============================================================
  World Breaker 2 — master computer console
  ---------------------------------------------------------------
  Live dashboard for every wb2 turtle in wireless range.
  Requires a wireless (or ender) modem on any side.
  Turtles announce themselves automatically — no enrolment step.

  Keys (the highlighted letter on each button is its hotkey):
    up/down     select a turtle
    m  modes menu: quarry / strip / multi-quarry / goto
    q  start a quarry        s  start a strip mine
    g  go to coordinates     r  return home & unload
    e  resume paused task    x  stop (pause) in place
    a  abort task            t  toggle torch placement
    u  cycle unload mode     i  full info for selection (updates live)
    p  ping selection
    c  config menu: every optional feature of the selection
    Shift+C  fleet config menu: same, applied to ALL turtles
    l  lock/unlock selection to this master
    v  push /wb2.lua to all turtles (over-the-air update)
    Shift+X / Shift+R / Shift+E   stop / recall / resume ALL turtles

  The header shows this modem's estimated wireless range; a turtle
  within 15% of that limit is drawn in orange as a warning.

  Row markers: * after the state = task paused, ! = the turtle is
  running code with no version stamp (outdated - push with v). The
  v push reports a tally: updated / refused / silent. REFUSED almost
  always means the turtle is locked to a different master id - clear
  it AT the turtle with 'wb2 set MASTER_ID 0' (a lock cannot be
  removed remotely by a master it doesn't trust).

  Multi-quarry tiles one big quarry across several turtles: pick a
  leader, and with GPS the followers walk to their tiles themselves
  (digging through whatever is in the way). Without GPS, place the
  turtles in a line - each directly beside the previous, facing the
  same way - and they shift themselves apart. Nobody mines until
  every turtle has reported "in position".

  On an ADVANCED (gold) computer this is auto-detected and the
  screen is touch-enabled: click a row to select a turtle, click
  the buttons along the bottom, scroll to change selection.

  Optional peripherals, auto-detected:
    speaker  - chimes when a turtle reports an ore find, low bass
               when one needs attention (waiting/blocked/error)
    monitor  - mirrors the fleet list on a wall display. On an advanced
               monitor, tap a row to select a turtle and tap the
               Return/Resume/Stop/Abort/Ping buttons to command it;
               actions that need typing stay on the master's screen
============================================================ ]]--

local PROTO_STATUS = "wb2status"
local PROTO_CMD    = "wb2cmd"
local STALE_AFTER  = 16 -- seconds without a status -> flagged offline

-- ================= setup =================

local opened = false
for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
  if peripheral.getType(side) == "modem" then
    rednet.open(side)
    opened = true
  end
end
if not opened then
  print("No modem found. Attach a wireless modem and try again.")
  return
end

-- optional peripherals (see header)
local speaker = peripheral.find("speaker")
local monitor = peripheral.find("monitor")
if monitor then pcall(function() monitor.setTextScale(0.5) end) end

-- estimated wireless range of this computer's modem: 64 blocks at ground
-- level, growing linearly above y=96 up to 384 at the build limit. Both
-- ends of a link count, so treat it as a rough guide (storms shrink it,
-- ender modems ignore it entirely).
local rangeEst = 64
do
  local ok, _, y = pcall(gps.locate, 1)
  if ok and type(y) == "number" and y > 96 then
    rangeEst = math.min(384, math.floor(64 + (y - 96) * 2))
  end
end

-- world-heading unit vectors (E=0, S=1, W=2, N=3), same frame as turtles
local HDX = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local HDZ = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

-- audible cues: bright pling for finds, low bass for a turtle in trouble
local function chime(kind)
  if not speaker then return end
  pcall(function()
    if kind == "alert" then
      speaker.playNote("pling", 3, 18)
    else
      speaker.playNote("bass", 3, 4)
    end
  end)
end

local turtles = {}  -- [id] = { status = <last status table>, last = os.clock() }
local order = {}    -- sorted ids for display
local selected = 1
local notes = {}    -- recent messages from turtles
local isColor = term.isColor and term.isColor() -- advanced computer: colors + touch
local rowMap = {}   -- screen row -> turtle list index (for touch selection)
local buttons = {}  -- clickable footer button hitboxes

local function refreshOrder()
  order = {}
  for id in pairs(turtles) do table.insert(order, id) end
  table.sort(order)
  if selected > #order then selected = math.max(#order, 1) end
end

local function selectedId()
  return order[selected]
end

local function pushNote(text)
  table.insert(notes, 1, text)
  while #notes > 3 do table.remove(notes) end
end

-- rednet rides on modem messages, which carry the sender's distance;
-- remember it so the fleet list can flag turtles near the edge of range
local function recordDistance(ev)
  local reply, dist = ev[4], ev[6]
  if type(reply) == "number" and type(dist) == "number" and turtles[reply] then
    turtles[reply].dist = dist
  end
end

local function nearRangeEdge(t)
  return t.dist ~= nil and t.dist >= rangeEst * 0.85
end

-- absorb an incoming status/note message into the turtle table (used by
-- the main loop and by every screen that runs its own event loop)
local function ingest(sender, msg, proto)
  if proto ~= PROTO_STATUS or type(msg) ~= "table" then return false end
  if msg.kind == "note" then
    pushNote(("#%d %s: %s"):format(msg.id or sender, msg.label or "", msg.text or ""))
  elseif msg.kind == "ready" then
    -- a mustering turtle reached its multi-quarry tile
    pushNote(("#%d %s: in position"):format(msg.id or sender, msg.label or ""))
  else
    local prev = turtles[sender]
    local prevNote = prev and prev.shownNote
    local prevState = prev and prev.status.state
    local prevDist = prev and prev.dist
    turtles[sender] = { status = msg, last = os.clock(), shownNote = prevNote, dist = prevDist }
    refreshOrder()
    -- surface fresh turtle notes (ore alerts, crafting reports, ...)
    if msg.note and msg.note ~= "" and msg.note ~= prevNote then
      turtles[sender].shownNote = msg.note
      pushNote(("#%d: %s"):format(sender, msg.note))
      if msg.note:find("found") then chime("alert") end
    end
    -- a turtle just got stuck or ran dry: make it audible
    if msg.state ~= prevState
       and (msg.state == "waiting" or msg.state == "blocked" or msg.state == "error") then
      pushNote(("#%d needs attention: %s %s"):format(sender, msg.state, msg.detail or ""))
      chime("warn")
    end
  end
  return true
end

-- ================= drawing =================

-- checked live (not cached) so it is also correct while term is
-- redirected to an attached monitor, which may differ from the computer
local function setColor(c)
  if term.isColor() then term.setTextColor(c) end
end

local function fmtPos(st)
  if st.world then
    return ("%d,%d,%d"):format(st.world.x, st.world.y, st.world.z)
  elseif st.pos then
    return ("~%d,%d,%d"):format(st.pos.x, st.pos.y, st.pos.z)
  end
  return "?"
end

local function fmtFuel(f)
  if type(f) ~= "number" then return "inf" end
  if f >= 10000 then return math.floor(f / 1000) .. "k" end
  return tostring(f)
end

-- 0..1 completion of the current task, or nil when unknowable
-- (a quarry with no depth digs to bedrock, so its total is unknown)
local function taskPct(t)
  if not t then return nil end
  if t.kind == "quarry" and t.l and t.w and t.depth then
    local cells = t.l * t.w
    local layers = math.ceil(t.depth / 3)
    return math.min(1, ((t.layer or 0) * cells + (t.cell or 0)) / (cells * layers))
  elseif t.kind == "strip" and (t.total or t.len) then
    return math.min(1, (t.cell or 0) / (t.total or t.len))
  end
  return nil
end

local function bar(pct, width)
  local filled = math.floor(pct * width + 0.5)
  return "[" .. string.rep("=", filled) .. string.rep(" ", width - filled)
         .. ("] %2d%%"):format(math.floor(pct * 100))
end

-- render a row of clickable [buttons], recording their hitboxes. Each
-- button's hotkey letter is capitalised and highlighted (CC has no
-- underline); a label that doesn't contain its key gets a "x:" prefix.
local function drawButtons(y, defs, registry)
  registry = registry or buttons
  local x = 1
  for _, def in ipairs(defs) do
    local label = def.label
    local p = label:lower():find(def.ch:lower(), 1, true)
    if not p then
      label = def.ch .. ":" .. label
      p = 1
    end
    label = label:sub(1, p - 1) .. label:sub(p, p):upper() .. label:sub(p + 1)
    term.setCursorPos(x, y)
    setColor(colors.yellow)
    write("[" .. label:sub(1, p - 1))
    setColor(colors.white)
    write(label:sub(p, p))
    setColor(colors.yellow)
    write(label:sub(p + 1) .. "]")
    table.insert(registry, { y = y, x1 = x, x2 = x + #label + 1, ch = def.ch })
    x = x + #label + 3
  end
end

-- wall-monitor mirror of the fleet: every turtle gets a row plus a
-- progress bar. On an advanced monitor, tap a row to select and tap the
-- command buttons; anything that needs TYPING (modes, config, sizes)
-- stays on the master's own screen, because monitors have no keyboard.
local monRowMap = {}  -- monitor row -> turtle list index
local monButtons = {} -- monitor button hitboxes
local function drawMonitor()
  if not monitor then return end
  local prev = term.redirect(monitor)
  pcall(function()
    local w, h = term.getSize()
    monRowMap = {}
    monButtons = {}
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    setColor(colors.yellow)
    write("World Breaker 2 - fleet")
    local count = #order .. " turtle" .. (#order == 1 and "" or "s")
    term.setCursorPos(math.max(1, w - #count + 1), 1)
    write(count)
    setColor(colors.gray)
    term.setCursorPos(1, 2)
    write(string.rep("-", w))
    local row = 3
    for i, id in ipairs(order) do
      if row > h - 5 then break end
      local t = turtles[id]
      local st = t.status
      local offline = (os.clock() - t.last) > STALE_AFTER
      term.setCursorPos(1, row)
      if offline then setColor(colors.red)
      elseif nearRangeEdge(t) then setColor(colors.orange)
      elseif i == selected then setColor(colors.white)
      else setColor(colors.lightGray) end
      local state = offline and "offline?" or (st.state or "?")
      if st.task and st.task.paused then state = state .. "*" end
      if not offline and not st.version then state = state .. "!" end -- outdated code
      local pct = taskPct(st.task)
      local pctStr = pct and ("%3d%%"):format(math.floor(pct * 100)) or "    "
      write(((i == selected and "> " or "  ") ..
        ("#%-4d %-10s %-12s %s F:%-5s %s"):format(id, (st.label or "?"):sub(1, 10),
          state:sub(1, 12), pctStr, fmtFuel(st.fuel), fmtPos(st))):sub(1, w))
      monRowMap[row] = i
      row = row + 1
      local pct = taskPct(st.task)
      if pct and row <= h - 5 then
        term.setCursorPos(3, row)
        setColor(colors.lime)
        write(bar(pct, math.min(w - 12, 30)))
        monRowMap[row] = i
        row = row + 1
      end
    end
    if #order == 0 then
      term.setCursorPos(2, 4)
      setColor(colors.lightGray)
      write("Waiting for turtle broadcasts...")
    end
    setColor(colors.gray)
    term.setCursorPos(1, h - 4)
    write(string.rep("-", w))
    setColor(colors.lightGray)
    for i = 1, 3 do
      term.setCursorPos(1, h - 4 + i)
      if notes[i] then write(notes[i]:sub(1, w)) end
    end
    -- command buttons for the selected turtle (tap on advanced monitors);
    -- prompt-driven actions are terminal-only, so they are not offered
    if w >= 44 then
      drawButtons(h, {
        { label = "Return", ch = "r" }, { label = "Resume", ch = "e" },
        { label = "Stop", ch = "x" }, { label = "Abort", ch = "a" },
        { label = "Ping", ch = "p" },
      }, monButtons)
    else
      drawButtons(h, {
        { label = "R", ch = "r" }, { label = "E", ch = "e" },
        { label = "X", ch = "x" }, { label = "A", ch = "a" },
        { label = "P", ch = "p" },
      }, monButtons)
    end
  end)
  term.redirect(prev)
end

local function draw()
  local w, h = term.getSize()
  local compact = w < 40 -- pocket computers (26 wide) get a condensed layout
  term.setBackgroundColor(colors.black)
  term.clear()
  rowMap = {}
  buttons = {}

  term.setCursorPos(1, 1)
  setColor(colors.yellow)
  if compact then
    write("WB2 Master")
  else
    write(isColor and "World Breaker 2 - Master (touch)" or "World Breaker 2 - Master")
  end
  local count = compact and ("t:" .. #order .. " ~" .. rangeEst)
             or ("turtles: " .. #order .. "  range ~" .. rangeEst .. "m")
  term.setCursorPos(w - #count + 1, 1)
  write(count)
  setColor(colors.gray)
  term.setCursorPos(1, 2)
  write(string.rep("-", w))

  local row = 3
  for i, id in ipairs(order) do
    if row > h - 6 then break end
    local t = turtles[id]
    local st = t.status
    local offline = (os.clock() - t.last) > STALE_AFTER
    term.setCursorPos(1, row)
    if i == selected then
      setColor(colors.white)
      write("> ")
    else
      setColor(colors.lightGray)
      write("  ")
    end
    if offline then
      setColor(colors.red)
    elseif nearRangeEdge(t) then
      setColor(colors.orange) -- close to the edge of wireless range
    elseif i == selected then
      setColor(colors.white)
    else
      setColor(colors.lightGray)
    end
    local state = offline and "offline?" or (st.state or "?")
    if st.task and st.task.paused then state = state .. "*" end
    if not offline and not st.version then state = state .. "!" end -- outdated code
    -- approximate task completion, shown against every turtle
    -- (blank for bedrock quarries, whose total depth is unknown)
    local pct = taskPct(st.task)
    local pctStr = pct and ("%3d%%"):format(math.floor(pct * 100)) or "    "
    local line
    if compact then
      line = ("#%-3d %-9s %s F:%s"):format(id, state:sub(1, 9), pctStr, fmtFuel(st.fuel))
    else
      line = ("#%-4d %-10s %-12s %s F:%-5s %s"):format(
        id, (st.label or "?"):sub(1, 10), state:sub(1, 12), pctStr, fmtFuel(st.fuel), fmtPos(st))
    end
    write(line:sub(1, w - 2))
    rowMap[row] = i
    row = row + 1
    -- compact mode: position gets its own line for the selected turtle
    if compact and i == selected and row <= h - 6 then
      term.setCursorPos(3, row)
      setColor(colors.lightGray)
      write(fmtPos(st):sub(1, w - 3))
      row = row + 1
    end
    -- extra lines for the selected turtle: task detail + progress bar
    if i == selected and st.detail and st.detail ~= "" and row <= h - 6 then
      term.setCursorPos(3, row)
      setColor(colors.cyan)
      write(("%s"):format(st.detail):sub(1, w - 3))
      row = row + 1
    end
    if i == selected and row <= h - 6 then
      local pct = taskPct(st.task)
      if pct then
        term.setCursorPos(3, row)
        setColor(colors.lime)
        write(bar(pct, math.min(24, w - 12)))
        row = row + 1
      end
    end
  end
  if #order == 0 then
    term.setCursorPos(3, 4)
    setColor(colors.lightGray)
    write("Waiting for turtle status broadcasts...")
    term.setCursorPos(3, 5)
    write("(turtles need a wireless modem + 'wb2 listen')")
  end

  setColor(colors.gray)
  term.setCursorPos(1, h - 5)
  write(string.rep("-", w))
  setColor(colors.lightGray)
  for i = 1, 2 do
    term.setCursorPos(1, h - 5 + i)
    if notes[i] then write(notes[i]:sub(1, w)) end
  end
  if compact then
    drawButtons(h - 2, {
      { label = "M", ch = "m" }, { label = "R", ch = "r" }, { label = "E", ch = "e" },
      { label = "I", ch = "i" }, { label = "P", ch = "p" },
    })
    drawButtons(h - 1, {
      { label = "X", ch = "x" }, { label = "A", ch = "a" }, { label = "C", ch = "c" },
    })
  else
    drawButtons(h - 2, {
      { label = "Modes", ch = "m" }, { label = "Return", ch = "r" },
      { label = "Resume", ch = "e" }, { label = "Info", ch = "i" },
      { label = "Ping", ch = "p" },
    })
    drawButtons(h - 1, {
      { label = "Stop", ch = "x" }, { label = "Abort", ch = "a" },
      { label = "Config", ch = "c" },
    })
  end
  setColor(colors.white)
  term.setCursorPos(1, h)
  drawMonitor()
end

local function prompt(label)
  local w, h = term.getSize()
  term.setCursorPos(1, h)
  term.clearLine()
  setColor(colors.white)
  write(label)
  return read()
end

-- ================= commands =================

local function send(cmd)
  local id = selectedId()
  if not id then
    pushNote("No turtle selected.")
    return
  end
  rednet.send(id, cmd, PROTO_CMD)
end

-- plan view of the current quarry layer: '#' mined, '@' turtle's current
-- cell, '.' still to dig. Columns run forward (length), rows run to the
-- turtle's right (width). Large quarries are downsampled to fit.
local function drawQuarryMap(t)
  local w, _ = term.getSize()
  local l, wd = t.l, t.w
  local cells = l * wd
  local reverse = ((t.layer or 0) % 2 == 1)
  local grid = {}
  for seq = 0, cells - 1 do
    local i = reverse and (cells - 1 - seq) or seq
    local r = math.floor(i / l)
    local c = i % l
    local x = (r % 2 == 0) and c or (l - 1 - c)
    local mark = "."
    if seq < (t.cell or 0) then mark = "#" elseif seq == (t.cell or 0) then mark = "@" end
    grid[r] = grid[r] or {}
    grid[r][x] = mark
  end
  local sx = math.max(1, math.ceil(l / (w - 4)))
  local sz = math.max(1, math.ceil(wd / 10))
  for z = 0, wd - 1, sz do
    local chars, fg = {}, {}
    for x = 0, l - 1, sx do
      local m = (grid[z] and grid[z][x]) or "."
      table.insert(chars, m)
      table.insert(fg, m == "#" and "5" or (m == "@" and "4" or "8"))
    end
    term.setCursorPos(3, select(2, term.getCursorPos()))
    if isColor then
      local s = table.concat(chars)
      term.blit(s, table.concat(fg), string.rep("f", #s))
      print("")
    else
      print(table.concat(chars))
    end
  end
end

-- full detail for the selected turtle; keeps redrawing as fresh status
-- broadcasts arrive, so the numbers update live while you watch
local function infoScreen()
  local id = selectedId()
  if not id then return end
  while true do
  local st = turtles[id].status
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  setColor(colors.yellow)
  print(("Turtle #%d  %s"):format(id, st.label or ""))
  setColor(colors.white)
  print(("state: %s  %s"):format(st.state or "?", st.detail or ""))
  print(("fuel: %s   pos: %s   free slots: %s"):format(
    fmtFuel(st.fuel), fmtPos(st), tostring(st.freeSlots or "?")))
  local dist = turtles[id].dist
  if dist then
    setColor(dist >= rangeEst * 0.85 and colors.orange or colors.lightGray)
    print(("distance from master: %dm (my range ~%dm)"):format(dist, rangeEst))
  end
  if st.version then
    setColor(colors.lightGray)
    print("code v" .. st.version)
  else
    setColor(colors.red)
    print("code OUTDATED - press v to push the update")
  end
  if st.cfg then
    setColor(colors.lightGray)
    print(("torches:%s veins:%s unload:%s craft:%s/%s"):format(
      tostring(st.cfg.PLACE_TORCHES), tostring(st.cfg.STRIP_VEIN),
      tostring(st.cfg.UNLOAD_MODE), tostring(st.cfg.CRAFT_TORCHES),
      tostring(st.cfg.CRAFT_CHESTS)))
    if (st.cfg.MASTER_ID or 0) ~= 0 then
      print("locked to master #" .. st.cfg.MASTER_ID)
    end
  end
  if st.haul and st.haul.total and st.haul.total > 0 then
    setColor(colors.white)
    print(("dug %d blocks this task"):format(st.haul.total))
    if st.haul.ores then
      setColor(colors.lime)
      for name, n in pairs(st.haul.ores) do
        print(("  %4d x %s"):format(n, name))
      end
    end
  end
  local t = st.task
  if t then
    setColor(colors.white)
    print("")
    if t.kind == "quarry" then
      print(("quarry %dx%d%s - layer %d, cell %d/%d%s"):format(
        t.l, t.w, t.depth and (" depth " .. t.depth) or " (to bedrock)",
        (t.layer or 0) + 1, (t.cell or 0), t.l * t.w,
        t.paused and " [paused]" or ""))
      local pct = taskPct(t)
      if pct then
        setColor(colors.lime)
        print(bar(pct, 30))
      end
      setColor(colors.white)
      print("current layer (-> forward, v right):")
      drawQuarryMap(t)
    elseif t.kind == "strip" then
      print(("strip %d%s - block %d/%d%s"):format(t.len,
        (t.snakes or 0) > 0 and (", " .. t.snakes .. " snakes") or "",
        t.cell or 0, t.total or t.len,
        t.paused and " [paused]" or ""))
      setColor(colors.lime)
      print(bar(taskPct(t) or 0, 30))
    elseif t.kind == "goto" then
      print("travelling")
    end
  else
    print("")
    print("no active task")
  end
  if st.note and st.note ~= "" then
    setColor(colors.lightGray)
    print("last note: " .. st.note)
  end
  setColor(colors.lightGray)
  print("")
  print("Updates live - press any key (or tap) to go back")
  local timer = os.startTimer(2)
  local redraw = false
  while not redraw do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      if ingest(ev[2], ev[3], ev[4]) then redraw = true end
    elseif ev[1] == "modem_message" then
      recordDistance(ev)
    elseif ev[1] == "timer" and ev[2] == timer then
      redraw = true -- periodic refresh (staleness, distance)
    elseif ev[1] == "key" or ev[1] == "mouse_click" or ev[1] == "monitor_touch" then
      return
    end
  end
  end -- while true (redraw)
end

-- split one big quarry across several turtles as side-by-side tiles.
-- A LEADER anchors the quarry at its own position. With GPS the master
-- computes every tile corner from the leader's fix and the followers
-- walk there themselves (digging through whatever is in the way);
-- without GPS the turtles must be placed in a line - each directly
-- beside the previous, same facing - and shift themselves apart by
-- counting. Nobody mines until every follower reports "in position".
local function multiQuarry()
  local avail = {}
  for _, tid in ipairs(order) do
    local t = turtles[tid]
    local busy = t.status.task and not t.status.task.paused
    if (os.clock() - t.last) <= STALE_AFTER and not busy then
      table.insert(avail, tid)
    end
  end
  if #avail == 0 then
    pushNote("No idle turtles to tile across.")
    return
  end

  -- pick the leader; the rest follow in id order
  local defLeader = selectedId()
  local isAvail = false
  for _, tid in ipairs(avail) do if tid == defLeader then isAvail = true end end
  if not isAvail then defLeader = avail[1] end
  local leader = tonumber(prompt(("leader turtle id [%d]: "):format(defLeader))) or defLeader
  local ordered, found = { leader }, false
  for _, tid in ipairs(avail) do
    if tid == leader then found = true else table.insert(ordered, tid) end
  end
  if not found then
    pushNote(("#%d is not an idle, online turtle."):format(leader))
    return
  end

  local input = prompt(("tiled quarry, %d turtle(s) - <length> <width> [depth]: "):format(#ordered))
  local l, w, d = input:match("^(%d+)%s+(%d+)%s*(%d*)$")
  if not l then
    pushNote("Format: <length> <width> [depth], e.g. 32 32")
    return
  end
  l, w, d = tonumber(l), tonumber(w), tonumber(d)
  local dir = prompt("width to the leader's right or left? (r/l) [r]: ")
                :lower():sub(1, 1) == "l" and "left" or "right"
  local vert = prompt("dig down or up? (d/u) [d]: ")
                 :lower():sub(1, 1) == "u" and "up" or "down"
  local side = (dir == "left") and -1 or 1

  local n = math.min(#ordered, w) -- never hand out a tile narrower than 1
  local base = math.floor(w / n)
  local extra = w % n
  local plan = {}
  local off = 0
  for i = 1, n do
    local tw = base + (i <= extra and 1 or 0)
    plan[i] = { id = ordered[i], w = tw, off = off }
    off = off + tw
  end

  -- ask the leader for a GPS fix + facing; no answer -> line mode
  rednet.send(leader, { cmd = "pose" }, PROTO_CMD)
  local pose = nil
  local timer = os.startTimer(8)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      ingest(ev[2], ev[3], ev[4])
      local msg = ev[3]
      if ev[2] == leader and type(msg) == "table" and msg.world and msg.worldHeading then
        pose = msg
        break
      end
    elseif ev[1] == "modem_message" then
      recordDistance(ev)
    elseif ev[1] == "timer" and ev[2] == timer then
      break
    end
  end

  -- the plan, and what the player must do before saying yes
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  setColor(colors.yellow)
  print(("Tiled quarry %dx%d%s%s across %d turtles"):format(
    l, w, d and (" depth " .. d) or " (to bedrock/sky)",
    vert == "up" and " upward" or "", n))
  setColor(pose and colors.lime or colors.orange)
  print(pose and "GPS mode: followers walk to their tiles themselves"
             or "No GPS fix from the leader - LINE MODE")
  print("")
  setColor(colors.white)
  for i, p in ipairs(plan) do
    local st = turtles[p.id].status
    print(("  #%-4d %-10s %s tile %d: %d wide (cols %d-%d)"):format(
      p.id, (st.label or ""):sub(1, 10), i == 1 and "LEAD" or "    ",
      i, p.w, p.off, p.off + p.w - 1))
  end
  setColor(colors.lightGray)
  print("")
  if pose then
    print("Followers dig straight to their tile corners and")
    print("wait there. Nothing is mined until every one has")
    print("reported in position.")
  else
    print("Place the turtles FIRST, in the order listed:")
    print(("- one row, each directly %s of the previous"):format(
      dir == "left" and "LEFT" or "RIGHT"))
    print("- all facing the same way as the leader")
    print("- they then shift themselves to their tiles and")
    print("  wait; mining starts when all are in position")
  end
  print("- each tile corner becomes that turtle's home:")
  print("  chest behind it or chests aboard, as usual")
  print("")
  setColor(colors.white)
  write("Start now? (y/n): ")
  if read():lower():sub(1, 1) ~= "y" then
    pushNote("Tiled quarry cancelled")
    return
  end

  -- send the followers to their tiles and wait for every "ready"
  local waiting, nWaiting = {}, 0
  for i = 2, n do
    local p = plan[i]
    local m
    if pose then
      local rh = (pose.worldHeading + (dir == "left" and 3 or 1)) % 4
      m = { cmd = "muster",
            x = pose.world.x + HDX[rh] * p.off,
            y = pose.world.y,
            z = pose.world.z + HDZ[rh] * p.off,
            face = pose.worldHeading }
    else
      -- placed i-1 blocks beside the leader; its tile is off blocks out
      m = { cmd = "muster", right = side * (p.off - (i - 1)) }
    end
    rednet.send(p.id, m, PROTO_CMD)
    waiting[p.id] = true
    nWaiting = nWaiting + 1
  end
  while nWaiting > 0 do
    local _, hh = term.getSize()
    term.setCursorPos(1, hh)
    term.clearLine()
    setColor(colors.orange)
    write(("waiting for %d turtle(s) to reach position... (q aborts)"):format(nWaiting))
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local sender, msg = ev[2], ev[3]
      ingest(sender, msg, ev[4])
      if type(msg) == "table" and msg.kind == "ready" and waiting[sender] then
        waiting[sender] = nil
        nWaiting = nWaiting - 1
      end
    elseif ev[1] == "modem_message" then
      recordDistance(ev)
    elseif ev[1] == "char" and ev[2] == "q" then
      for tid in pairs(waiting) do rednet.send(tid, { cmd = "abort" }, PROTO_CMD) end
      pushNote("Tiled quarry cancelled while mustering")
      return
    end
  end

  -- everyone is in position: fire the actual quarries
  for _, p in ipairs(plan) do
    rednet.send(p.id, { cmd = "start", mode = "quarry", l = l, w = p.w,
                        depth = d, dir = dir, vert = vert }, PROTO_CMD)
  end
  pushNote(("Tiled quarry %dx%d started on %d turtles"):format(l, w, n))
end

-- prompt-and-send flows shared by the hotkeys and the modes menu
local function startQuarryPrompt()
  local id = selectedId()
  local input = prompt("quarry <length> <width> [depth] [left] [up]: ")
  local nums, dir, vert = {}, nil, nil
  for word in input:gmatch("%S+") do
    local num = tonumber(word)
    if num then table.insert(nums, num)
    elseif word == "left" or word == "right" then dir = word
    elseif word == "up" or word == "down" then vert = word end
  end
  if nums[1] and nums[2] then
    send({ cmd = "start", mode = "quarry", l = nums[1], w = nums[2],
           depth = nums[3], dir = dir, vert = vert })
    pushNote(("#%d: quarry %dx%d requested"):format(id or -1, nums[1], nums[2]))
  else
    pushNote("Format: <length> <width> [depth] [left|right] [up|down]")
  end
end

local function startStripPrompt()
  local id = selectedId()
  local input = prompt("strip <length> [snakes] [left]: ")
  local nums, dir = {}, nil
  for word in input:gmatch("%S+") do
    local num = tonumber(word)
    if num then table.insert(nums, num)
    elseif word == "left" or word == "right" then dir = word end
  end
  if nums[1] then
    send({ cmd = "start", mode = "strip", len = nums[1],
           snakes = nums[2] or 0, dir = dir })
    pushNote(("#%d: strip %d requested"):format(id or -1, nums[1]))
  else
    pushNote("Format: <length> [snakes] [left|right]")
  end
end

local function gotoPrompt()
  local id = selectedId()
  local input = prompt("goto x y z (world coords; prefix 'r' for relative): ")
  local rel, x, y, z = input:match("^(r?)%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)$")
  if x then
    send({ cmd = "goto", x = tonumber(x), y = tonumber(y), z = tonumber(z), world = (rel ~= "r") })
    pushNote(("#%d: goto %s,%s,%s"):format(id or -1, x, y, z))
  else
    pushNote("Format: x y z  (or: r x y z)")
  end
end

-- one submenu for the ways to put turtles to work; the direct hotkeys
-- (q/s/g) keep working from the dashboard too
local MODES = {
  { ch = "q", name = "Quarry",       desc = "dig out an area (selected turtle)" },
  { ch = "s", name = "Strip",        desc = "strip tunnel, optionally snaking" },
  { ch = "m", name = "Multi-quarry", desc = "one quarry tiled across turtles" },
  { ch = "g", name = "Goto",         desc = "send the selection to coordinates" },
}

local function modesMenu()
  local sel = 1
  local function run(i)
    local m = MODES[i]
    if m.ch == "q" then startQuarryPrompt()
    elseif m.ch == "s" then startStripPrompt()
    elseif m.ch == "m" then multiQuarry()
    elseif m.ch == "g" then gotoPrompt() end
  end
  while true do
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    setColor(colors.yellow)
    write("Modes of operation")
    local menuRows = {}
    for i, m in ipairs(MODES) do
      local row = i + 2
      term.setCursorPos(1, row)
      setColor(i == sel and colors.white or colors.lightGray)
      write(((i == sel and "> " or "  ") .. m.ch .. "  " ..
        ("%-12s"):format(m.name) .. " " .. m.desc):sub(1, w))
      menuRows[row] = i
    end
    term.setCursorPos(1, h)
    setColor(colors.lightGray)
    write(("enter/tap to choose, or the key - backspace to go back"):sub(1, w))

    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      ingest(ev[2], ev[3], ev[4])
    elseif ev[1] == "modem_message" then
      recordDistance(ev)
    elseif ev[1] == "key" then
      local k = ev[2]
      if k == keys.up then sel = math.max(1, sel - 1)
      elseif k == keys.down then sel = math.min(#MODES, sel + 1)
      elseif k == keys.enter or k == keys.space then run(sel) return
      elseif k == keys.backspace then return end
    elseif ev[1] == "char" then
      for i, m in ipairs(MODES) do
        if ev[2] == m.ch then run(i) return end
      end
    elseif ev[1] == "mouse_click" then
      local my = ev[4]
      if menuRows[my] then run(menuRows[my]) return
      else return end -- tap outside the list = back
    elseif ev[1] == "mouse_scroll" then
      sel = math.max(1, math.min(#MODES, sel + ev[2]))
    end
  end
end

-- every optional feature, editable from one screen; the list-valued
-- config keys (JUNK, FUEL_ITEMS, ...) are edited on the turtle itself
local MENU_KEYS = {
  { key = "PLACE_TORCHES",  kind = "bool", desc = "torch strip tunnels" },
  { key = "TORCH_INTERVAL", kind = "num",  desc = "blocks between torches" },
  { key = "STRIP_VEIN",     kind = "bool", desc = "chase ore veins (strip)" },
  { key = "VEIN_DEPTH",     kind = "num",  desc = "how far to chase a vein" },
  { key = "ORE_SCAN",       kind = "bool", desc = "scanner ore homing (strip)" },
  { key = "SCAN_INTERVAL",  kind = "num",  desc = "blocks between scans" },
  { key = "DROP_JUNK",      kind = "bool", desc = "discard cobble/dirt" },
  { key = "UNLOAD_MODE",    kind = "mode", desc = "home / chest / ender" },
  { key = "CRAFT_TORCHES",  kind = "bool", desc = "craft torches at home" },
  { key = "CRAFT_CHESTS",   kind = "bool", desc = "craft chests at home" },
  { key = "TORCH_MIN",      kind = "num",  desc = "restock torches up to" },
  { key = "CHEST_MIN",      kind = "num",  desc = "restock chests up to" },
  { key = "AUTO_REFUEL",    kind = "bool", desc = "eat mined coal when low" },
  { key = "AUTO_RETURN",    kind = "bool", desc = "retreat home on low fuel" },
  { key = "LAVA_REFUEL",    kind = "bool", desc = "scoop lava with a bucket" },
  { key = "FUEL_RESERVE",   kind = "num",  desc = "safety fuel margin" },
  { key = "REFUEL_TARGET",  kind = "num",  desc = "refuel up to this level" },
}

local function menuApply(entry, cur, fleet, id)
  local value
  if entry.kind == "mode" then
    local cycle = { home = "chest", chest = "ender", ender = "home" }
    value = cycle[cur] or "home"
  elseif entry.kind == "bool" then
    value = not (cur == true)
  else
    local input = prompt(("%s (now %s), new value: "):format(entry.key, tostring(cur)))
    value = tonumber(input)
    if value == nil then return end
  end
  local msg = { cmd = "set", key = entry.key, value = value }
  if fleet then
    rednet.broadcast(msg, PROTO_CMD)
    pushNote(("ALL turtles: %s = %s"):format(entry.key, tostring(value)))
  else
    rednet.send(id, msg, PROTO_CMD)
  end
end

-- one screen to view/change every optional feature of the selected
-- turtle; with fleet=true, every change is broadcast to ALL turtles
local function configMenu(fleet)
  local id = selectedId()
  if not id then
    pushNote("No turtles online yet.")
    return
  end
  local sel = 1
  while true do
    local st = turtles[id] and turtles[id].status
    local c = (st and st.cfg) or {}
    local w, h = term.getSize()
    local compact = w < 40
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    setColor(colors.yellow)
    if fleet then
      write(compact and "Fleet config (ALL)" or "Fleet config - changes apply to ALL turtles")
    else
      write(("Config - turtle #%d %s"):format(id, (st and st.label or ""):sub(1, 12)))
    end
    term.setCursorPos(1, 2)
    setColor(colors.gray)
    if fleet then
      write(("values shown are #%d's"):format(id))
    else
      write(string.rep("-", w))
    end
    local menuRows = {}
    -- window the list so every key stays reachable on short screens
    local visible = h - 3
    local top = math.max(0, sel - visible)
    for i, e in ipairs(MENU_KEYS) do
      local row = i + 2 - top
      if row >= 3 and row <= h - 1 then
        term.setCursorPos(1, row)
        setColor(i == sel and colors.white or colors.lightGray)
        local v = c[e.key]
        local vs = v == nil and "?" or tostring(v)
        local line
        if compact then
          line = ("%-16s %s"):format(e.key:sub(1, 16), vs)
        else
          line = ("%-15s %-6s %s"):format(e.key, vs:sub(1, 6), e.desc)
        end
        write(((i == sel and "> " or "  ") .. line):sub(1, w))
        menuRows[row] = i
      end
    end
    term.setCursorPos(1, h)
    setColor(colors.lightGray)
    write((compact and "enter:change q:done" or
      "up/down + enter (or tap) to change - q to go back"):sub(1, w))

    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      ingest(ev[2], ev[3], ev[4]) -- keep the shown values live
    elseif ev[1] == "modem_message" then
      recordDistance(ev)
    elseif ev[1] == "key" then
      local k = ev[2]
      if k == keys.up then sel = math.max(1, sel - 1)
      elseif k == keys.down then sel = math.min(#MENU_KEYS, sel + 1)
      elseif k == keys.enter or k == keys.space then
        menuApply(MENU_KEYS[sel], c[MENU_KEYS[sel].key], fleet, id)
      end
    elseif ev[1] == "char" then
      if ev[2] == "q" then return end
    elseif ev[1] == "mouse_click" then
      local my = ev[4]
      if menuRows[my] then
        if menuRows[my] == sel then
          menuApply(MENU_KEYS[sel], c[MENU_KEYS[sel].key], fleet, id)
        else
          sel = menuRows[my]
        end
      else
        return -- tap outside the list = done
      end
    elseif ev[1] == "mouse_scroll" then
      sel = math.max(1, math.min(#MENU_KEYS, sel + ev[2]))
    end
  end
end

local function handleChar(ch)
  local id = selectedId()
  local st = id and turtles[id].status or nil

  if ch == "q" then
    startQuarryPrompt()
  elseif ch == "s" then
    startStripPrompt()
  elseif ch == "g" then
    gotoPrompt()
  elseif ch == "r" then
    send({ cmd = "return" })
    pushNote(("#%d: return home requested"):format(id or -1))
  elseif ch == "e" then
    send({ cmd = "resume" })
  elseif ch == "x" then
    send({ cmd = "stop" })
    pushNote(("#%d: stop requested"):format(id or -1))
  elseif ch == "a" then
    send({ cmd = "abort" })
    pushNote(("#%d: abort requested"):format(id or -1))
  elseif ch == "t" then
    if st and st.cfg then
      send({ cmd = "set", key = "PLACE_TORCHES", value = not st.cfg.PLACE_TORCHES })
    end
  elseif ch == "u" then
    if st and st.cfg then
      local cycle = { home = "chest", chest = "ender", ender = "home" }
      send({ cmd = "set", key = "UNLOAD_MODE", value = cycle[st.cfg.UNLOAD_MODE] or "home" })
    end
  elseif ch == "i" then
    infoScreen()
  elseif ch == "p" then
    send({ cmd = "ping" })
  elseif ch == "m" then
    modesMenu()
  elseif ch == "c" then
    configMenu(false) -- all optional features of the selected turtle
  elseif ch == "C" then
    configMenu(true)  -- same menu, but changes broadcast to ALL turtles

  -- fleet-wide broadcasts (Shift + key = ALL turtles)
  elseif ch == "X" then
    rednet.broadcast({ cmd = "stop" }, PROTO_CMD)
    pushNote("ALL turtles: stop requested")
  elseif ch == "R" then
    rednet.broadcast({ cmd = "return" }, PROTO_CMD)
    pushNote("ALL turtles: recall requested")
  elseif ch == "E" then
    rednet.broadcast({ cmd = "resume" }, PROTO_CMD)
    pushNote("ALL turtles: resume requested")

  elseif ch == "l" then
    -- lock/unlock the selected turtle to THIS master computer
    if st and st.cfg then
      local me = os.getComputerID()
      local value = (st.cfg.MASTER_ID == me) and 0 or me
      send({ cmd = "set", key = "MASTER_ID", value = value })
      pushNote(("#%d: %s"):format(id or -1, value == 0 and "unlocking" or "locking to me"))
    end
  elseif ch == "v" then
    -- push /wb2.lua from this computer to every turtle (over-the-air
    -- update). NOTE: this sends the LOCAL copy - only 'install master'
    -- refreshes it from GitHub, so say which version is going out.
    local f = fs.open("/wb2.lua", "r")
    if not f then
      pushNote("No /wb2.lua here - run 'install master' to fetch it")
    else
      local code = f.readAll()
      f.close()
      local ver = code:match('VERSION%s*=%s*"([^"]+)"')
      if not ver then
        pushNote("Local wb2 has NO version stamp - run 'install master' first!")
        return
      end
      rednet.broadcast({ cmd = "update", code = code }, PROTO_CMD)
      -- collect the acks for a moment: individual replies scroll out of
      -- the 3-line notes area far too fast to audit a whole fleet, and
      -- a LOCKED turtle silently refusing updates looks like success
      local accepted, refused = 0, 0
      local timer = os.startTimer(4)
      while true do
        local ev = { os.pullEvent() }
        if ev[1] == "rednet_message" then
          local msg = ev[3]
          if type(msg) == "table" and msg.kind == "note" and type(msg.text) == "string" then
            if msg.text:find("updated") then
              accepted = accepted + 1
            elseif msg.text:find("locked") or msg.text:find("rejected") then
              refused = refused + 1
            end
          end
          ingest(ev[2], ev[3], ev[4])
        elseif ev[1] == "modem_message" then
          recordDistance(ev)
        elseif ev[1] == "timer" and ev[2] == timer then
          break
        end
      end
      local silent = math.max(0, #order - accepted - refused)
      pushNote(("wb2 v%s push: %d updated, %d REFUSED (locked?), %d silent"):format(
        ver, accepted, refused, silent))
    end
  end
end

-- ================= main loop =================

draw()
os.startTimer(2)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "rednet_message" then
    if ingest(ev[2], ev[3], ev[4]) then
      draw()
    end
  elseif ev[1] == "modem_message" then
    recordDistance(ev) -- the matching rednet_message triggers the redraw
  elseif ev[1] == "timer" then
    draw()
    os.startTimer(2)
  elseif ev[1] == "key" then
    local key = ev[2]
    if key == keys.up then
      selected = math.max(1, selected - 1)
      draw()
    elseif key == keys.down then
      selected = math.min(math.max(#order, 1), selected + 1)
      draw()
    end
  elseif ev[1] == "char" then
    handleChar(ev[2])
    draw()
  elseif ev[1] == "mouse_click" then -- advanced computers only
    local mx, my = ev[3], ev[4]
    if rowMap[my] then
      selected = rowMap[my]
      draw()
    else
      for _, b in ipairs(buttons) do
        if my == b.y and mx >= b.x1 and mx <= b.x2 then
          handleChar(b.ch)
          draw()
          break
        end
      end
    end
  elseif ev[1] == "mouse_scroll" then
    selected = math.max(1, math.min(math.max(#order, 1), selected + ev[2]))
    draw()
  elseif ev[1] == "monitor_touch" then -- advanced monitors: rows + buttons
    local mx, my = ev[3], ev[4]
    if monRowMap[my] then
      selected = monRowMap[my]
      draw()
    else
      for _, b in ipairs(monButtons) do
        if my == b.y and mx >= b.x1 and mx <= b.x2 then
          handleChar(b.ch)
          draw()
          break
        end
      end
    end
  end
end
