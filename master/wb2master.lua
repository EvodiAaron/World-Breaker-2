--[[ ============================================================
  World Breaker 2 — master computer console
  ---------------------------------------------------------------
  Live dashboard for every wb2 turtle in wireless range.
  Requires a wireless (or ender) modem on any side.
  Turtles announce themselves automatically — no enrolment step.

  Keys:
    up/down     select a turtle
    q  start a quarry        s  start a strip mine
    g  go to coordinates     r  return home & unload
    e  resume paused task    x  stop (pause) in place
    a  abort task            t  toggle torch placement
    u  cycle unload mode     i  full info for selection
    p  ping selection        m  tiled quarry (split across idle turtles)
    c  config menu: every optional feature of the selection
    Shift+C  fleet config menu: same, applied to ALL turtles
    l  lock/unlock selection to this master
    v  push /wb2.lua to all turtles (over-the-air update)
    Shift+X / Shift+R / Shift+E   stop / recall / resume ALL turtles

  On an ADVANCED (gold) computer this is auto-detected and the
  screen is touch-enabled: click a row to select a turtle, click
  the buttons along the bottom, scroll to change selection.

  Optional peripherals, auto-detected:
    speaker  - chimes when a turtle reports an ore find, low bass
               when one needs attention (waiting/blocked/error)
    monitor  - mirrors the fleet list on a wall display (tap a row
               on an advanced monitor to select that turtle)
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

-- render a row of clickable [buttons], recording their hitboxes
local function drawButtons(y, defs)
  local x = 1
  for _, def in ipairs(defs) do
    local label = "[" .. def.label .. "]"
    term.setCursorPos(x, y)
    write(label)
    table.insert(buttons, { y = y, x1 = x, x2 = x + #label - 1, ch = def.ch })
    x = x + #label + 1
  end
end

-- wall-monitor mirror of the fleet: every turtle gets a row plus a
-- progress bar; read-only except tap-to-select on advanced monitors
local monRowMap = {} -- monitor row -> turtle list index
local function drawMonitor()
  if not monitor then return end
  local prev = term.redirect(monitor)
  pcall(function()
    local w, h = term.getSize()
    monRowMap = {}
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
      if row > h - 4 then break end
      local t = turtles[id]
      local st = t.status
      local offline = (os.clock() - t.last) > STALE_AFTER
      term.setCursorPos(1, row)
      if offline then setColor(colors.red)
      elseif i == selected then setColor(colors.white)
      else setColor(colors.lightGray) end
      local state = offline and "offline?" or (st.state or "?")
      if st.task and st.task.paused then state = state .. "*" end
      local pct = taskPct(st.task)
      local pctStr = pct and ("%3d%%"):format(math.floor(pct * 100)) or "    "
      write(((i == selected and "> " or "  ") ..
        ("#%-4d %-10s %-12s %s F:%-5s %s"):format(id, (st.label or "?"):sub(1, 10),
          state:sub(1, 12), pctStr, fmtFuel(st.fuel), fmtPos(st))):sub(1, w))
      monRowMap[row] = i
      row = row + 1
      local pct = taskPct(st.task)
      if pct and row <= h - 4 then
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
    term.setCursorPos(1, h - 3)
    write(string.rep("-", w))
    setColor(colors.lightGray)
    for i = 1, 3 do
      term.setCursorPos(1, h - 3 + i)
      if notes[i] then write(notes[i]:sub(1, w)) end
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
  local count = "turtles: " .. #order
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
    elseif i == selected then
      setColor(colors.white)
    else
      setColor(colors.lightGray)
    end
    local state = offline and "offline?" or (st.state or "?")
    if st.task and st.task.paused then state = state .. "*" end
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
  setColor(colors.yellow)
  if compact then
    drawButtons(h - 2, {
      { label = "Q", ch = "q" }, { label = "S", ch = "s" }, { label = "G", ch = "g" },
      { label = "R", ch = "r" }, { label = "E", ch = "e" }, { label = "M", ch = "m" },
    })
    drawButtons(h - 1, {
      { label = "X", ch = "x" }, { label = "A", ch = "a" }, { label = "C", ch = "c" },
      { label = "I", ch = "i" }, { label = "P", ch = "p" },
    })
  else
    drawButtons(h - 2, {
      { label = "Quarry", ch = "q" }, { label = "Strip", ch = "s" },
      { label = "Goto", ch = "g" }, { label = "Return", ch = "r" },
      { label = "Resume", ch = "e" }, { label = "Multi", ch = "m" },
    })
    drawButtons(h - 1, {
      { label = "Stop", ch = "x" }, { label = "Abort", ch = "a" },
      { label = "Config", ch = "c" }, { label = "Info", ch = "i" },
      { label = "Ping", ch = "p" },
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

local function infoScreen()
  local id = selectedId()
  if not id then return end
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
  print("Press any key (or tap) to go back")
  while true do
    local e = os.pullEvent()
    if e == "key" or e == "mouse_click" then break end
  end
end

-- split one big quarry across every idle turtle: the width is divided
-- into side-by-side tiles and each turtle quarries its own tile where
-- it stands. The turtles must be lined up in a row first (same facing,
-- each at the left edge of its tile) — the plan screen spells it out.
local function multiQuarry()
  local idle = {}
  for _, tid in ipairs(order) do
    local t = turtles[tid]
    local busy = t.status.task and not t.status.task.paused
    if (os.clock() - t.last) <= STALE_AFTER and not busy then
      table.insert(idle, tid)
    end
  end
  if #idle == 0 then
    pushNote("No idle turtles to tile across.")
    return
  end
  local input = prompt(("tiled quarry, %d idle turtle(s) - <length> <width> [depth]: "):format(#idle))
  local l, w, d = input:match("^(%d+)%s+(%d+)%s*(%d*)$")
  if not l then
    pushNote("Format: <length> <width> [depth], e.g. 32 32")
    return
  end
  l, w, d = tonumber(l), tonumber(w), tonumber(d)
  local n = math.min(#idle, w) -- never hand out a tile narrower than 1
  local base = math.floor(w / n)
  local extra = w % n

  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  setColor(colors.yellow)
  print(("Tiled quarry %dx%d%s across %d turtles"):format(
    l, w, d and (" depth " .. d) or " (to bedrock)", n))
  print("")
  setColor(colors.white)
  local plan = {}
  local off = 0
  for i = 1, n do
    local tw = base + (i <= extra and 1 or 0)
    plan[i] = { id = idle[i], w = tw, off = off }
    local st = turtles[idle[i]].status
    print(("  #%-4d %-10s tile %d: %d wide (columns %d-%d)"):format(
      idle[i], (st.label or ""):sub(1, 10), i, tw, off, off + tw - 1))
    off = off + tw
  end
  setColor(colors.lightGray)
  print("")
  print("Line the turtles up FIRST, in id order as listed:")
  print("- all on one row, all facing the same direction")
  print("- each standing at the LEFT column of its tile")
  print(("  (turtle 2 stands %d blocks right of turtle 1, etc.)"):format(plan[1].w))
  print("- each tile becomes that turtle's home: chest behind")
  print("  it or chests aboard, as usual")
  print("")
  setColor(colors.white)
  write("Start now? (y/n): ")
  local go = read()
  if go:lower():sub(1, 1) == "y" then
    for _, p in ipairs(plan) do
      rednet.send(p.id, { cmd = "start", mode = "quarry", l = l, w = p.w, depth = d }, PROTO_CMD)
    end
    pushNote(("Tiled quarry %dx%d started on %d turtles"):format(l, w, n))
  else
    pushNote("Tiled quarry cancelled")
  end
end

-- absorb an incoming status/note message into the turtle table (used by
-- both the main loop and the config menu, which has its own event loop)
local function ingest(sender, msg, proto)
  if proto ~= PROTO_STATUS or type(msg) ~= "table" then return false end
  if msg.kind == "note" then
    pushNote(("#%d %s: %s"):format(msg.id or sender, msg.label or "", msg.text or ""))
  else
    local prev = turtles[sender]
    local prevNote = prev and prev.shownNote
    local prevState = prev and prev.status.state
    turtles[sender] = { status = msg, last = os.clock(), shownNote = prevNote }
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

-- every optional feature, editable from one screen; the list-valued
-- config keys (JUNK, FUEL_ITEMS, ...) are edited on the turtle itself
local MENU_KEYS = {
  { key = "PLACE_TORCHES",  kind = "bool", desc = "torch strip tunnels" },
  { key = "TORCH_INTERVAL", kind = "num",  desc = "blocks between torches" },
  { key = "STRIP_VEIN",     kind = "bool", desc = "chase ore veins (strip)" },
  { key = "VEIN_DEPTH",     kind = "num",  desc = "how far to chase a vein" },
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
    for i, e in ipairs(MENU_KEYS) do
      local row = i + 2
      if row <= h - 1 then
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
    local input = prompt("quarry <length> <width> [depth]: ")
    local l, w, d = input:match("^(%d+)%s+(%d+)%s*(%d*)$")
    if l then
      send({ cmd = "start", mode = "quarry", l = tonumber(l), w = tonumber(w), depth = tonumber(d) })
      pushNote(("#%d: quarry %sx%s requested"):format(id or -1, l, w))
    else
      pushNote("Format: <length> <width> [depth], e.g. 16 16")
    end
  elseif ch == "s" then
    local input = prompt("strip <length> [snakes]: ")
    local len, snakes = input:match("^(%d+)%s*(%d*)$")
    if len then
      send({ cmd = "start", mode = "strip", len = tonumber(len), snakes = tonumber(snakes) or 0 })
      pushNote(("#%d: strip %s requested"):format(id or -1, len))
    else
      pushNote("Format: <length> [snakes], e.g. 64 4")
    end
  elseif ch == "g" then
    local input = prompt("goto x y z (world coords; prefix 'r' for relative): ")
    local rel, x, y, z = input:match("^(r?)%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)$")
    if x then
      send({ cmd = "goto", x = tonumber(x), y = tonumber(y), z = tonumber(z), world = (rel ~= "r") })
      pushNote(("#%d: goto %s,%s,%s"):format(id or -1, x, y, z))
    else
      pushNote("Format: x y z  (or: r x y z)")
    end
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
    multiQuarry()
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
    -- push /wb2.lua from this computer to every turtle (over-the-air update)
    local f = fs.open("/wb2.lua", "r")
    if not f then
      pushNote("No /wb2.lua here - copy it to this computer to push updates")
    else
      local code = f.readAll()
      f.close()
      rednet.broadcast({ cmd = "update", code = code }, PROTO_CMD)
      pushNote("Update pushed to ALL turtles (they reboot and resume)")
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
  elseif ev[1] == "monitor_touch" then -- advanced monitors: tap a row to select
    local my = ev[4]
    if monRowMap[my] then
      selected = monRowMap[my]
      draw()
    end
  end
end
