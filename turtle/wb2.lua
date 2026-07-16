--[[ ============================================================
  World Breaker 2 — turtle program
  ---------------------------------------------------------------
  Works completely standalone on a single mining turtle, and
  optionally cooperates with a master computer over rednet
  (in-game wireless modems — no external server required).

  Usage:
    wb2                          interactive setup wizard
    wb2 quarry <length> <width> [depth] [left|right] [up|down]
    wb2 strip <length> [snakes] [left|right]
    wb2 listen                   idle; wait for master commands
    wb2 resume                   resume task saved on disk
    wb2 set <KEY> <value>        change a config value
    wb2 config                   print current config
    wb2 reset                    clear saved task + config

  Orientation: "length" is forward from the turtle, "width" is to
  the turtle's RIGHT (or LEFT with the left option). The turtle sits
  INSIDE the top corner block of the quarry: its own layer counts as
  layer 1 of the requested depth. Its starting block is home; put a
  chest directly BEHIND it for unloading, and (optionally, for
  crafty turtles) a second chest to its LEFT as a crafting buffer.
============================================================ ]]--

if not turtle then
  print("wb2 must run on a (mining) turtle.")
  return
end

local VERSION = "1.5" -- shown on the master's info screen; bump on release

local PROTO_STATUS = "wb2status"
local PROTO_CMD    = "wb2cmd"
local STATE_DIR    = "/wb2data"
local CONFIG_FILE  = STATE_DIR .. "/config"
local STATE_FILE   = STATE_DIR .. "/state"

-- ================= utilities =================

local function listHas(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then return true end
  end
  return false
end

-- part of a block/item name after the mod id, e.g. "iron_ore"
local function pathOf(name)
  return name:match(":(.+)$") or name
end

local function fuelLevel()
  local f = turtle.getFuelLevel()
  if type(f) ~= "number" then return math.huge end -- fuel disabled on server
  return f
end

local function serialize(t) return textutils.serialize(t) end
local function unserialize(s) return textutils.unserialize(s) end

local function readFileTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local content = f.readAll()
  f.close()
  return unserialize(content)
end

local function writeFileTable(path, tbl)
  local f = fs.open(path, "w")
  f.write(serialize(tbl))
  f.close()
end

-- ================= configuration =================

local cfg = {
  PLACE_TORCHES   = false,   -- strip mode: place torches along the tunnel
  TORCH_INTERVAL  = 12,      -- blocks between torches
  CRAFT_TORCHES   = false,   -- craft torches at home (crafty turtle + buffer chest)
  CRAFT_CHESTS    = false,   -- craft chests at home (crafty turtle + buffer chest)
  TORCH_MIN       = 24,      -- craft torches when stock falls below this
  CHEST_MIN       = 2,       -- craft chests when stock falls below this
  UNLOAD_MODE     = "home",  -- "home" (chest behind start) | "chest" (place chests as it goes) | "ender" (place/empty/collect an ender chest)
  DROP_JUNK       = true,    -- throw away junk blocks instead of hauling them
  AUTO_REFUEL     = true,    -- consume mined fuel when running low
  AUTO_RETURN     = true,    -- retreat home when fuel is only just enough to get back
                             -- (false = stop in place and wait to be fed instead)
  LAVA_REFUEL     = true,    -- scoop lava met while digging into a carried empty bucket
  FUEL_RESERVE    = 60,      -- safety margin on top of the trip home
  REFUEL_TARGET   = 1000,    -- refuel to this level when waiting at home
  VEIN_DEPTH      = 12,      -- how far to chase an ore vein (strip mode)
  STRIP_VEIN      = true,    -- strip mode: chase ore veins off the tunnel
  ORE_SCAN        = false,   -- strip mode: home in on ores with a carried
                             -- Plethora block scanner (needs GPS to orient)
  SCAN_INTERVAL   = 8,       -- blocks between scans
  STATUS_INTERVAL = 5,       -- seconds between status broadcasts
  ENDER_CHEST     = "enderstorage:ender_storage",
  FUEL_ITEMS      = { "minecraft:coal", "minecraft:coal_block", "minecraft:lava_bucket" },
  JUNK            = { "minecraft:cobblestone", "minecraft:stone", "minecraft:dirt",
                      "minecraft:gravel", "minecraft:sand", "minecraft:sandstone",
                      "minecraft:netherrack", "minecraft:grass", "minecraft:flint" },
  -- decorative stones from any mod, matched by substring (chisel:marble,
  -- projectred-exploration:stone variants, ...); one junk category with
  -- JUNK, all governed by the single DROP_JUNK toggle
  JUNK_MATCH      = { "andesite", "diorite", "granite", "basalt", "marble",
                      "limestone", "tuff", "slate" },
  ORE_EXTRA       = { "ic2:resource" },  -- valuable blocks whose names don't contain "ore"
  ORE_IGNORE      = {},                  -- blocks matching "ore" that should NOT be chased
  EXTRA_LOGS      = {},                  -- crafting logs whose names don't contain "log"
  EXTRA_PLANKS    = {},                  -- crafting planks whose names don't contain "plank"
  ALERT_BLOCKS    = { "minecraft:diamond_ore", "minecraft:emerald_ore" }, -- announce these finds
  MASTER_ID       = 0,                   -- 0 = obey any master; set to a computer ID to lock
}

local function loadConfig()
  local saved = readFileTable(CONFIG_FILE)
  if saved then
    for k, v in pairs(saved) do cfg[k] = v end
  end
end

local function saveConfig()
  writeFileTable(CONFIG_FILE, cfg)
end

-- ================= state =================

local pos = { x = 0, y = 0, z = 0 } -- relative to home; x = initial forward, z = initial right, y = up
local heading = 0                   -- 0 = +x, 1 = +z, 2 = -x, 3 = -z (right turns increment)
local DX = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local DZ = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

local task = nil        -- active/paused task table, persisted for resume
local calib = nil       -- GPS calibration {offset, worldAt = {x,y,z}, relAt = {x,y,z}}
local haul = { total = 0, ores = {} } -- blocks dug this task, ores by name
local control = { request = nil }  -- interrupt requests set by comms: stop/return/abort
local recovering = false           -- true while handling a fuel/return interrupt
local hasModem = false
local statusText, statusDetail = "idle", ""
local lastNote = ""

local function saveState()
  writeFileTable(STATE_FILE, {
    pos = { x = pos.x, y = pos.y, z = pos.z },
    heading = heading,
    task = task,
    calib = calib,
    haul = haul,
  })
end

local function loadState()
  local s = readFileTable(STATE_FILE)
  if not s then return false end
  pos = s.pos or pos
  heading = s.heading or 0
  task = s.task
  calib = s.calib
  haul = s.haul or haul
  return true
end

-- ================= comms (guarded: everything works with no modem) =================

local function openModems()
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    if peripheral.getType(side) == "modem" then
      rednet.open(side)
      hasModem = true
    end
  end
end

local function rot(dx, dz, o)
  o = o % 4
  if o == 0 then return dx, dz
  elseif o == 1 then return -dz, dx
  elseif o == 2 then return -dx, -dz
  else return dz, -dx end
end

local function worldFromRel(p)
  if not calib then return nil end
  local dx, dz = rot(p.x - calib.relAt.x, p.z - calib.relAt.z, calib.offset)
  return { x = calib.worldAt.x + dx, y = calib.worldAt.y + (p.y - calib.relAt.y), z = calib.worldAt.z + dz }
end

local function relFromWorld(wp)
  if not calib then return nil end
  local dx, dz = rot(wp.x - calib.worldAt.x, wp.z - calib.worldAt.z, (4 - calib.offset) % 4)
  return { x = calib.relAt.x + dx, y = calib.relAt.y + (wp.y - calib.worldAt.y), z = calib.relAt.z + dz }
end

local function buildStatus()
  local freeSlots = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then freeSlots = freeSlots + 1 end
  end
  local t = nil
  if task then
    t = { kind = task.kind, paused = task.paused or false,
          l = task.l, w = task.w, depth = task.depth, len = task.len,
          snakes = task.snakes, total = task.total,
          layer = task.layer, cell = task.cell }
  end
  return {
    id = os.getComputerID(),
    version = VERSION,
    label = os.getComputerLabel(),
    fuel = turtle.getFuelLevel(),
    pos = { x = pos.x, y = pos.y, z = pos.z },
    world = worldFromRel(pos),
    heading = heading,
    -- absolute facing (E=0 S=1 W=2 N=3), known only with GPS calibration;
    -- the master uses it to lay out multi-turtle quarry tiles
    worldHeading = calib and ((calib.offset + heading) % 4) or nil,
    state = statusText,
    detail = statusDetail,
    note = lastNote,
    freeSlots = freeSlots,
    task = t,
    haul = { total = haul.total, ores = haul.ores },
    -- every scalar config value, so the master's config menu can show and
    -- edit all of them (the list-valued keys are edited on the turtle)
    cfg = (function()
      local c = {}
      for k, v in pairs(cfg) do
        if type(v) ~= "table" then c[k] = v end
      end
      return c
    end)(),
  }
end

local function broadcastStatus()
  if hasModem then
    rednet.broadcast(buildStatus(), PROTO_STATUS)
  end
end

-- advanced (gold) turtles get color-coded status lines; auto-detected
local function statusColor(state)
  if not (term and term.isColor and term.isColor()) then return nil end
  if state == "error" or state == "blocked" or state == "waiting" then
    return colors.red
  elseif state == "done" or state == "refuelled" then
    return colors.lime
  elseif state == "paused" or state == "returning" or state == "unloading"
      or state == "finishing" then
    return colors.orange
  elseif state == "idle" then
    return colors.lightGray
  end
  return colors.yellow
end

local function setStatus(state, detail)
  statusText = state
  statusDetail = detail or ""
  local c = statusColor(state)
  if c then term.setTextColor(c) end
  if detail and detail ~= "" then
    print("[" .. state .. "] " .. detail)
  else
    print("[" .. state .. "]")
  end
  if c then term.setTextColor(colors.white) end
  broadcastStatus()
end

local function note(text)
  lastNote = text
  print(text)
  broadcastStatus()
end

-- ================= interrupts =================

local function checkControl()
  if control.request then
    local r = control.request
    control.request = nil
    error({ wb = r }, 0)
  end
end

-- ================= inventory helpers =================

local function isTorch(name) return name == "minecraft:torch" end
local function isEnderChest(name) return name == cfg.ENDER_CHEST or name == "minecraft:ender_chest" end
-- any mod's placeable chest counts (Quark spruce chests, iron chests,
-- ...), but never armour ("chestplate") and never ender chests, which
-- have their own unload path
local function isPlainChest(name)
  if isEnderChest(name) then return false end
  local p = pathOf(name)
  if p:find("chestplate") then return false end
  return p:find("chest") ~= nil
end
local function isStick(name) return name == "minecraft:stick" end
local function isCraftingTable(name) return name == "minecraft:crafting_table" end
-- modded wood names vary wildly (log, log2, log_0, logs.0, plank_greatwood,
-- planks_0, ...) so match loosely and exclude the known "log" red herrings;
-- EXTRA_LOGS / EXTRA_PLANKS config catches any name these rules miss
local function isPlanks(name)
  if listHas(cfg.EXTRA_PLANKS, name) then return true end
  return pathOf(name):find("plank") ~= nil
end
local function isLog(name)
  if listHas(cfg.EXTRA_LOGS, name) then return true end
  local p = pathOf(name)
  if p:find("logic") or p:find("logistic") then return false end
  return p:find("log") ~= nil
end

local function isFuelItem(name)
  return listHas(cfg.FUEL_ITEMS, name)
end

local function isBucket(name)
  return name == "minecraft:bucket" or name == "minecraft:lava_bucket"
end

-- a Plethora block scanner module (1.12 module items all share one id)
local function isScanner(name)
  return name == "plethora:module" or pathOf(name):find("scanner") ~= nil
end

local function isContainer(name)
  local p = pathOf(name)
  return p:find("chest") ~= nil or p:find("ender_storage") ~= nil
         or p:find("barrel") ~= nil or p:find("crate") ~= nil
end

local function isKeepItem(name)
  if isTorch(name) or isPlainChest(name) or isEnderChest(name) or isFuelItem(name)
     or isCraftingTable(name) or isBucket(name) or isScanner(name) then
    return true
  end
  if (cfg.CRAFT_TORCHES or cfg.CRAFT_CHESTS) and (isStick(name) or isPlanks(name) or isLog(name)) then
    return true
  end
  return false
end

local function isValuable(name)
  if listHas(cfg.ORE_IGNORE, name) then return false end
  if listHas(cfg.ORE_EXTRA, name) then return true end
  return pathOf(name):find("ore") ~= nil
end

local function isJunk(name)
  if isValuable(name) then return false end -- never discard something ore-like
  if listHas(cfg.JUNK, name) then return true end
  local p = pathOf(name)
  for _, sub in ipairs(cfg.JUNK_MATCH) do
    if p:find(sub, 1, true) then return true end
  end
  return false
end

local function freeSlots()
  local n = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then n = n + 1 end
  end
  return n
end

local function findSlot(matcher)
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d and matcher(d.name) then return slot end
  end
  return nil
end

local function countItems(matcher)
  local n = 0
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d and matcher(d.name) then n = n + d.count end
  end
  return n
end

-- throw away junk blocks (tries down, then up, then forward)
local function dropJunk()
  if not cfg.DROP_JUNK then return end
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d and isJunk(d.name) then
      turtle.select(slot)
      if not turtle.dropDown() then
        if not turtle.dropUp() then turtle.drop() end
      end
    end
  end
  turtle.select(1)
end

-- ================= fuel =================

local function distHome()
  return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z)
end

local function refuelFromInventory(target)
  for slot = 1, 16 do
    if fuelLevel() >= target then return true end
    local d = turtle.getItemDetail(slot)
    if d and isFuelItem(d.name) then
      turtle.select(slot)
      while fuelLevel() < target and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
  return fuelLevel() >= target
end

local function ensureFuel()
  local f = fuelLevel()
  if f == math.huge then return end
  local needed = distHome() + cfg.FUEL_RESERVE
  if f > needed then return end
  if cfg.AUTO_REFUEL then
    refuelFromInventory(needed + 200)
  end
  if fuelLevel() <= distHome() + 10 and not recovering then
    -- barely enough fuel left to make it home: retreat now (or, with
    -- AUTO_RETURN off, hold position and wait to be fed)
    error({ wb = cfg.AUTO_RETURN and "fuel" or "fuelwait" }, 0)
  end
end

-- ================= haul accounting =================

-- called with the inspected name whenever a block is dug
local function recordDig(name)
  haul.total = haul.total + 1
  if isValuable(name) then
    haul.ores[name] = (haul.ores[name] or 0) + 1
  end
  if listHas(cfg.ALERT_BLOCKS, name) then
    note(("%s found at %d,%d,%d"):format(name, pos.x, pos.y, pos.z))
  end
end

-- ================= lava refueling =================

-- Fluids never register on turtle.detect(), so the dig helpers call this to
-- look for lava by inspection. A source block scooped with a carried empty
-- bucket is 1,000 fuel; scooping flowing (non-source) lava fails harmlessly.
local function scoopLava(dir)
  if not cfg.LAVA_REFUEL then return end
  if fuelLevel() == math.huge or fuelLevel() >= cfg.REFUEL_TARGET then return end
  local inspectFn = (dir == "up" and turtle.inspectUp)
                 or (dir == "down" and turtle.inspectDown) or turtle.inspect
  local ok, d = inspectFn()
  if not (ok and pathOf(d.name):find("lava")) then return end
  local slot = findSlot(function(n) return n == "minecraft:bucket" end)
  if not slot then return end
  turtle.select(slot)
  local placeFn = (dir == "up" and turtle.placeUp)
               or (dir == "down" and turtle.placeDown) or turtle.place
  if placeFn() then
    local full = findSlot(function(n) return n == "minecraft:lava_bucket" end)
    if full then
      turtle.select(full)
      if turtle.refuel() then
        note(("scooped lava - fuel %s"):format(tostring(turtle.getFuelLevel())))
      end
    end
  end
  turtle.select(1)
end

-- ================= movement primitives =================
-- All movement goes through these so position is always tracked & persisted.

local function turnRight()
  turtle.turnRight()
  heading = (heading + 1) % 4
  saveState()
end

local function turnLeft()
  turtle.turnLeft()
  heading = (heading + 3) % 4
  saveState()
end

local function face(h)
  h = h % 4
  local diff = (h - heading) % 4
  if diff == 1 then turnRight()
  elseif diff == 2 then turnRight() turnRight()
  elseif diff == 3 then turnLeft() end
end

-- another turtle looks like an ordinary block to dig; never do that -
-- breaking a turtle pops it off the world and spills its inventory
local function isTurtleBlock(name)
  return pathOf(name):find("turtle") ~= nil
end

-- give a fellow turtle time to move out of the way; true once the spot
-- is clear, false if it stayed put (treat like bedrock: route around)
local function waitForTurtle(inspectFn)
  for waited = 0, 15 do
    local ok, d = inspectFn()
    if not (ok and isTurtleBlock(d.name)) then return true end
    if waited == 0 then
      setStatus("waiting", "another turtle is in my way")
    end
    checkControl()
    sleep(1)
  end
  return false
end

-- dig forward, tolerating gravel/sand columns
local function digForwardSafe()
  scoopLava("forward")
  local tries = 0
  while turtle.detect() do
    checkControl()
    local ok, d = turtle.inspect()
    if ok and isTurtleBlock(d.name) then
      if not waitForTurtle(turtle.inspect) then return false end
    else
      local falling = ok and (pathOf(d.name):find("gravel") or pathOf(d.name):find("sand"))
      if not turtle.dig() then return false end -- bedrock / protected
      if ok then recordDig(d.name) end
      if falling then sleep(0.4) end            -- let the next block land
    end
    tries = tries + 1
    if tries > 64 then return false end
  end
  return true
end

local function digUpSafe()
  scoopLava("up")
  local tries = 0
  while turtle.detectUp() do
    checkControl()
    local ok, d = turtle.inspectUp()
    if ok and isTurtleBlock(d.name) then
      if not waitForTurtle(turtle.inspectUp) then return false end
    else
      local falling = ok and (pathOf(d.name):find("gravel") or pathOf(d.name):find("sand"))
      if not turtle.digUp() then return false end
      if ok then recordDig(d.name) end
      if falling then sleep(0.4) end
    end
    tries = tries + 1
    if tries > 64 then return false end
  end
  return true
end

local function digDownSafe()
  scoopLava("down")
  if turtle.detectDown() then
    local ok, d = turtle.inspectDown()
    if ok and isTurtleBlock(d.name) then
      return waitForTurtle(turtle.inspectDown)
    end
    if not turtle.digDown() then return false end
    if ok then recordDig(d.name) end
  end
  return true
end

local function tryForward()
  checkControl()
  ensureFuel()
  local tries = 0
  while not turtle.forward() do
    checkControl()
    if turtle.detect() then
      if not digForwardSafe() then return false end
    else
      turtle.attack() -- a mob is in the way
      sleep(0.2)
    end
    tries = tries + 1
    if tries > 60 then return false end
  end
  pos.x = pos.x + DX[heading]
  pos.z = pos.z + DZ[heading]
  saveState()
  return true
end

local function tryUp()
  checkControl()
  ensureFuel()
  local tries = 0
  while not turtle.up() do
    checkControl()
    if turtle.detectUp() then
      if not digUpSafe() then return false end
    else
      turtle.attackUp()
      sleep(0.2)
    end
    tries = tries + 1
    if tries > 60 then return false end
  end
  pos.y = pos.y + 1
  saveState()
  return true
end

local function tryDown()
  checkControl()
  ensureFuel()
  local tries = 0
  while not turtle.down() do
    checkControl()
    if turtle.detectDown() then
      local okI, d = turtle.inspectDown()
      if okI and isTurtleBlock(d.name) then
        if not waitForTurtle(turtle.inspectDown) then return false end
      else
        if not turtle.digDown() then return false end
        if okI then recordDig(d.name) end
      end
    else
      turtle.attackDown()
      sleep(0.2)
    end
    tries = tries + 1
    if tries > 60 then return false end
  end
  pos.y = pos.y - 1
  saveState()
  return true
end

local function tryBack()
  checkControl()
  ensureFuel()
  if turtle.back() then
    pos.x = pos.x - DX[heading]
    pos.z = pos.z - DZ[heading]
    saveState()
    return true
  end
  -- something fell into the cell behind us; turn around and dig through
  local h = heading
  face((h + 2) % 4)
  local ok = tryForward()
  face(h)
  return ok
end

-- navigate to a relative coordinate; digs through anything in the way.
-- The path is a straight x-then-z line; zFirst flips the axis order,
-- which is often enough to slip around a bedrock column.
local function goTo(t, zFirst)
  local function stepY()
    while pos.y < t.y do if not tryUp() then return false end end
    while pos.y > t.y do if not tryDown() then return false end end
    return true
  end
  local function stepX()
    if pos.x ~= t.x then
      face(pos.x < t.x and 0 or 2)
      while pos.x ~= t.x do if not tryForward() then return false end end
    end
    return true
  end
  local function stepZ()
    if pos.z ~= t.z then
      face(pos.z < t.z and 1 or 3)
      while pos.z ~= t.z do if not tryForward() then return false end end
    end
    return true
  end
  local first, second = stepX, stepZ
  if zFirst then first, second = stepZ, stepX end
  if t.y >= pos.y then
    return stepY() and first() and second() -- going up: rise first (e.g. out of the pit)
  else
    return first() and second() and stepY() -- going down: travel, then descend
  end
end

-- ================= GPS calibration (optional) =================

local function calibrate()
  if not hasModem then return end
  local x, y, z = gps.locate(1)
  if not x then return end
  local before = { x = pos.x, y = pos.y, z = pos.z }
  local h = heading
  if not tryForward() then return end
  local x2, y2, z2 = gps.locate(1)
  tryBack()
  if not x2 then return end
  local dx, dz = x2 - x, z2 - z
  local wh -- world heading index: E=0, S=1, W=2, N=3
  if dx == 1 then wh = 0
  elseif dz == 1 then wh = 1
  elseif dx == -1 then wh = 2
  elseif dz == -1 then wh = 3
  else return end
  calib = {
    offset = (wh - h) % 4,
    worldAt = { x = x, y = y, z = z },
    relAt = before,
  }
  saveState()
  note(("GPS calibrated: %d, %d, %d"):format(x, y, z))
end

-- re-anchor the relative frame at the current position/heading (new home)
local function rebase()
  if calib then
    local w = worldFromRel(pos)
    calib.worldAt = w
    calib.relAt = { x = 0, y = 0, z = 0 }
    calib.offset = (calib.offset + heading) % 4
  end
  pos = { x = 0, y = 0, z = 0 }
  heading = 0
  saveState()
end

-- ================= crafting (crafty turtle + buffer chest to the LEFT of home) =================

local GRID_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local PARK_SLOTS = { 4, 8, 12, 13, 14, 15, 16 }

-- assumes turtle is at home facing the buffer chest (heading 3)
local function dumpAllExcept(matcher)
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d and not matcher(d.name) then
      turtle.select(slot)
      turtle.drop()
    end
  end
  turtle.select(1)
end

local function suckAllBack()
  while turtle.suck() do end
end

-- move required item counts into grid slots, push everything else to the buffer
local function arrangeGrid(layout)
  -- clear the grid slots first, parking contents outside the grid where
  -- possible (they may be the very materials we are about to arrange)
  for _, gslot in ipairs(GRID_SLOTS) do
    if turtle.getItemCount(gslot) > 0 then
      turtle.select(gslot)
      for _, park in ipairs(PARK_SLOTS) do
        if turtle.getItemCount(park) == 0 then
          turtle.transferTo(park)
          break
        end
      end
      if turtle.getItemCount(gslot) > 0 then turtle.drop() end
    end
  end
  -- fill each layout slot from wherever the item currently is
  -- (never taking from another layout slot's allocation)
  for gslot, want in pairs(layout) do
    for slot = 1, 16 do
      local have = turtle.getItemCount(gslot)
      if slot ~= gslot and layout[slot] == nil and have < want.count then
        local d = turtle.getItemDetail(slot)
        if d and want.matcher(d.name) then
          turtle.select(slot)
          turtle.transferTo(gslot, want.count - have)
        end
      end
    end
    -- fewer items than hoped just means fewer crafts; empty means no recipe
    if turtle.getItemCount(gslot) == 0 then return false end
  end
  -- anything left outside the layout blocks crafting; push it to the buffer
  for slot = 1, 16 do
    if not layout[slot] and turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      turtle.drop()
    end
  end
  turtle.select(1)
  return true
end

-- one dump -> arrange -> craft -> suck-back cycle
local function craftPass(keepMatcher, layout)
  dumpAllExcept(keepMatcher)
  local ok = false
  if arrangeGrid(layout) then
    local safe, crafted = pcall(turtle.craft)
    ok = safe and crafted or false
  end
  suckAllBack()
  return ok
end

-- Turtles have only two equipment slots, so a mining turtle with a modem
-- cannot ALSO wear a workbench. If a plain crafting table is in the
-- inventory, temporarily swap it onto a non-modem side to craft with.
local function equipWorkbench()
  local slot = findSlot(isCraftingTable)
  if not slot then return false end
  local side
  for _, s in ipairs({ "right", "left" }) do
    if peripheral.getType(s) ~= "modem" then side = s break end
  end
  if not side then return false end
  turtle.select(slot)
  local ok
  if side == "right" then ok = turtle.equipRight() else ok = turtle.equipLeft() end
  turtle.select(1)
  return (ok and turtle.craft ~= nil), side
end

-- put the pickaxe back on and return the workbench to the inventory
local function restoreGear(side)
  local slot = findSlot(function(n) return pathOf(n):find("pickaxe") ~= nil end)
  if not slot then
    for i = 1, 16 do
      if turtle.getItemCount(i) == 0 then slot = i break end
    end
  end
  if not slot then return end -- inventory jammed; keep the workbench on for now
  turtle.select(slot)
  if side == "right" then turtle.equipRight() else turtle.equipLeft() end
  turtle.select(1)
end

local function craftSession()
  if not (cfg.CRAFT_TORCHES or cfg.CRAFT_CHESTS) then return end
  face(3)
  local ok, d = turtle.inspect()
  if not (ok and isContainer(d.name)) then
    -- no buffer chest yet: place one from our own inventory if we can
    ok = false
    local slot = findSlot(isPlainChest)
    if slot then
      -- the spot is often natural rock (we ARE in a mine): dig it out,
      -- but never break something that isn't junk to make room
      if d and isJunk(d.name) then
        digForwardSafe()
      end
      if not turtle.detect() then
        turtle.select(slot)
        ok = turtle.place()
        turtle.select(1)
        if ok then note("Placed my own crafting buffer chest to the LEFT of home") end
      end
    end
    if not ok then
      note("No crafting buffer chest to the LEFT of home; skipping crafting")
      face(0)
      return
    end
  end
  local swapSide = nil
  if not turtle.craft then
    local okSwap, side = equipWorkbench()
    if not okSwap then
      note("Cannot craft: need a crafty turtle or a crafting table in my inventory")
      face(0)
      return
    end
    swapSide = side
  end

  -- the most abundant single item variant matching `matcher` — recipes
  -- cannot mix wood types from different mods within one crafting grid
  local function dominantItem(matcher)
    local totals = {}
    for slot = 1, 16 do
      local d = turtle.getItemDetail(slot)
      if d and matcher(d.name) then
        totals[d.name] = (totals[d.name] or 0) + d.count
      end
    end
    local best, bestN = nil, 0
    for name, n in pairs(totals) do
      if n > bestN then best, bestN = name, n end
    end
    return best, bestN
  end

  local function exact(name)
    return function(n) return n == name end
  end

  -- have `target` planks of ONE type available, crafting from the most
  -- plentiful log type if short; returns the chosen plank name (or nil)
  local function ensurePlanks(target)
    local name, have = dominantItem(isPlanks)
    if have >= target then return name end
    local logName, logs = dominantItem(isLog)
    if logName then
      craftPass(isLog, { [1] = { matcher = exact(logName), count = math.min(logs, 64) } })
      name, have = dominantItem(isPlanks)
    end
    if have > 0 then return name end
    return nil
  end

  if cfg.CRAFT_CHESTS and countItems(isPlainChest) < cfg.CHEST_MIN then
    local want = cfg.CHEST_MIN - countItems(isPlainChest)
    local plankName = ensurePlanks(want * 8)
    if plankName then
      local _, have = dominantItem(exact(plankName))
      local per = math.min(want, math.floor(have / 8), 64)
      if per > 0 then
        local layout = {}
        for _, s in ipairs({ 1, 2, 3, 5, 7, 9, 10, 11 }) do
          layout[s] = { matcher = exact(plankName), count = per }
        end
        if craftPass(isPlanks, layout) then
          note("Crafted chests")
        end
      end
    end
  end

  if cfg.CRAFT_TORCHES and countItems(isTorch) < cfg.TORCH_MIN then
    local crafts = math.ceil((cfg.TORCH_MIN - countItems(isTorch)) / 4)
    -- make sticks first if we're short
    if countItems(isStick) < crafts then
      local sticksShort = crafts - countItems(isStick)
      local plankName = ensurePlanks(math.ceil(sticksShort / 2) * 2)
      if plankName then
        local _, have = dominantItem(exact(plankName))
        local per = math.min(math.floor(have / 2), 64)
        if per > 0 then
          craftPass(isPlanks, {
            [1] = { matcher = exact(plankName), count = per },
            [5] = { matcher = exact(plankName), count = per },
          })
        end
      end
    end
    local n = math.min(crafts, countItems(function(x) return x == "minecraft:coal" end), countItems(isStick), 64)
    if n > 0 then
      local okCraft = craftPass(
        function(x) return x == "minecraft:coal" or isStick(x) end,
        {
          [1] = { matcher = function(x) return x == "minecraft:coal" end, count = n },
          [5] = { matcher = isStick, count = n },
        })
      if okCraft then note("Crafted torches") end
    end
  end

  if swapSide then restoreGear(swapSide) end
  face(0)
end

-- ================= unloading =================

-- drop everything that isn't a keep-item using dropFn; false if the container filled up
local function unloadInto(dropFn)
  local full = false
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d and not isKeepItem(d.name) then
      turtle.select(slot)
      if not dropFn() then full = true end
    end
  end
  turtle.select(1)
  return not full
end

-- go home, empty into the chest behind the start position, craft if configured
local function goHomeAndUnload()
  setStatus("returning", ("from %d,%d,%d"):format(pos.x, pos.y, pos.z))
  if not goTo({ x = 0, y = 0, z = 0 }) then
    setStatus("blocked", "could not reach home")
    return false
  end
  face(2) -- chest is behind the start orientation
  local ok, d = turtle.inspect()
  if ok and isContainer(d.name) then
    ok = true
  else
    -- no chest at home yet: place one from our own inventory if we can
    ok = false
    local slot = findSlot(isPlainChest)
    if slot and not turtle.detect() then
      turtle.select(slot)
      ok = turtle.place()
      turtle.select(1)
    end
  end
  if ok then
    setStatus("unloading")
    while not unloadInto(turtle.drop) do
      setStatus("waiting", "home chest is full")
      sleep(3)
      checkControl()
    end
  else
    setStatus("waiting", "no chest behind home - place one (or empty me)")
    while freeSlots() < 14 do
      sleep(3)
      checkControl()
      local ok2, d2 = turtle.inspect()
      if ok2 and isContainer(d2.name) then
        unloadInto(turtle.drop)
        break
      end
    end
  end
  craftSession()
  face(0)
  return true
end

-- place an ender chest below, empty into it, then pick it back up
local function enderUnload()
  local slot = findSlot(isEnderChest)
  if not slot then return false end
  digDownSafe()
  turtle.select(slot)
  if not turtle.placeDown() then
    turtle.select(1)
    return false
  end
  setStatus("unloading", "ender chest")
  unloadInto(turtle.dropDown)
  turtle.digDown() -- take the ender chest back
  turtle.select(1)
  return true
end

-- strip mode: dig a niche to the left, place a chest in it, fill it, leave it
local function nicheChestUnload()
  local slot = findSlot(isPlainChest)
  if not slot then return false end
  local h = heading
  face((h + 3) % 4)
  if not digForwardSafe() then face(h) return false end
  turtle.select(slot)
  if not turtle.place() then
    turtle.select(1)
    face(h)
    return false
  end
  setStatus("unloading", "chest niche")
  unloadInto(turtle.drop)
  turtle.select(1)
  face(h)
  return true
end

-- called between cells; keeps the inventory workable
local function maintainInventory(returnTarget)
  dropJunk()
  if freeSlots() >= 2 then return end
  if cfg.UNLOAD_MODE == "ender" and enderUnload() then return end
  if cfg.UNLOAD_MODE == "chest" then
    if task and task.kind == "strip" and nicheChestUnload() then return end
    if enderUnload() then return end -- fall through if an ender chest happens to be aboard
  end
  -- default: haul it home and come back
  local came = { x = pos.x, y = pos.y, z = pos.z }
  goHomeAndUnload()
  setStatus(task and task.kind or "working", "returning to the face")
  goTo(returnTarget or came)
end

-- ================= vein mining =================

local function veinCheck(depth)
  if depth <= 0 then return end
  for _ = 1, 4 do
    local ok, d = turtle.inspect()
    if ok and isValuable(d.name) then
      if tryForward() then
        veinCheck(depth - 1)
        tryBack()
      end
    end
    turnRight()
  end
  local ok, d = turtle.inspectUp()
  if ok and isValuable(d.name) then
    if tryUp() then
      veinCheck(depth - 1)
      tryDown()
    end
  end
  ok, d = turtle.inspectDown()
  if ok and isValuable(d.name) then
    if tryDown() then
      veinCheck(depth - 1)
      tryUp()
    end
  end
end

-- ================= torches =================

-- strip mode: the turtle travels the UPPER level of the 1x2 tunnel, so
-- torches dropped onto the floor below are never in its way again
local function placeTorchDown()
  local slot = findSlot(isTorch)
  if not slot then return false end
  turtle.select(slot)
  local ok = turtle.placeDown()
  turtle.select(1)
  return ok
end

-- ================= ore scanning (Plethora block scanner) =================

-- Swap a carried block scanner onto the pickaxe side, scan, and put the
-- pickaxe straight back (never dig while the scanner is equipped).
-- Returns the scanned block list, or nil.
local function scanBlocks()
  local slot = findSlot(isScanner)
  if not slot then return nil end
  local side
  for _, s in ipairs({ "right", "left" }) do
    if peripheral.getType(s) ~= "modem" then side = s break end
  end
  if not side then return nil end
  turtle.select(slot)
  local okEq
  if side == "right" then okEq = turtle.equipRight() else okEq = turtle.equipLeft() end
  if not okEq then
    turtle.select(1)
    return nil
  end
  local blocks
  local p = peripheral.wrap(side)
  if p and p.scan then
    local okScan, res = pcall(p.scan)
    if okScan and type(res) == "table" then blocks = res end
  end
  restoreGear(side)
  turtle.select(1)
  return blocks
end

-- scan around the current position, chase every ore found, then return to
-- `back`. Scanner offsets are WORLD-axis-aligned, so GPS calibration is
-- required to rotate them into the turtle's own frame.
local function scanAndChase(back)
  if not calib then
    if task and not task.scanWarned then
      task.scanWarned = true
      note("ore scan needs GPS to orient - skipping scans this task")
    end
    return
  end
  local blocks = scanBlocks()
  if not blocks then
    if task and not task.scanWarned then
      task.scanWarned = true
      note("ore scan: no block scanner aboard - restock me")
    end
    return
  end
  if task then task.scanWarned = nil end
  local targets = {}
  local inv = (4 - calib.offset) % 4
  for _, b in ipairs(blocks) do
    if b.name and isValuable(b.name)
       and not (b.x == 0 and b.y == 0 and b.z == 0) then
      local dx, dz = rot(b.x, b.z, inv)
      table.insert(targets, {
        x = pos.x + dx, y = pos.y + b.y, z = pos.z + dz,
        d = math.abs(b.x) + math.abs(b.y) + math.abs(b.z),
      })
    end
  end
  table.sort(targets, function(a, b) return a.d < b.d end)
  for _, t in ipairs(targets) do
    checkControl()
    dropJunk()
    if freeSlots() < 3 then maintainInventory() end
    -- a chased vein may already have eaten this target; travelling there
    -- digs it either way, and the vein chaser catches its neighbours
    if goTo({ x = t.x, y = t.y, z = t.z }) then
      veinCheck(cfg.VEIN_DEPTH)
    end
  end
  goTo(back)
end

-- ================= restock recommendations =================

-- suggest inventory items for the features currently enabled, listing
-- only what is missing; shown at startup and when a task finishes
local function recommendInventory()
  local wants = {}
  local function want(cond, have, text)
    if cond and not have then table.insert(wants, text) end
  end
  local fuelled = fuelLevel() == math.huge or fuelLevel() >= cfg.REFUEL_TARGET
  local crafting = cfg.CRAFT_TORCHES or cfg.CRAFT_CHESTS
  want(not fuelled, findSlot(isFuelItem) ~= nil, "fuel, e.g. coal")
  want(cfg.LAVA_REFUEL and fuelLevel() ~= math.huge,
       findSlot(isBucket) ~= nil, "an empty bucket (LAVA_REFUEL)")
  want(cfg.PLACE_TORCHES and not cfg.CRAFT_TORCHES,
       findSlot(isTorch) ~= nil, "torches (PLACE_TORCHES)")
  want(crafting and not turtle.craft,
       findSlot(isCraftingTable) ~= nil, "a crafting table (CRAFT_*)")
  want(crafting,
       findSlot(function(n) return isLog(n) or isPlanks(n) end) ~= nil,
       "logs or planks (CRAFT_*)")
  want(cfg.CRAFT_TORCHES,
       findSlot(function(n) return n == "minecraft:coal" end) ~= nil,
       "coal (CRAFT_TORCHES)")
  want(cfg.CRAFT_TORCHES,
       findSlot(function(n) return isStick(n) or isLog(n) or isPlanks(n) end) ~= nil,
       "sticks or wood (CRAFT_TORCHES)")
  want(cfg.CRAFT_CHESTS or cfg.UNLOAD_MODE == "chest",
       findSlot(isPlainChest) ~= nil, "chests (unloading/crafting)")
  want(cfg.UNLOAD_MODE == "ender",
       findSlot(isEnderChest) ~= nil, "an ender chest (UNLOAD_MODE ender)")
  want(cfg.ORE_SCAN, findSlot(isScanner) ~= nil, "a block scanner (ORE_SCAN)")
  if #wants > 0 then
    print("Recommended for my current config:")
    for _, t in ipairs(wants) do print("  - " .. t) end
  end
end

-- ================= tasks =================

local function finishTask(msg)
  setStatus("finishing", msg or "")
  goHomeAndUnload()
  task = nil
  saveState()
  setStatus("done", msg or "")
  recommendInventory()
end

-- serpentine cell index -> coordinates; length l along x, width w along z
local function cellCoord(i, l, w)
  local r = math.floor(i / l)
  local c = i % l
  local x = (r % 2 == 0) and c or (l - 1 - c)
  return x, r
end

local function runQuarry()
  local l, w = task.l, task.w
  local cells = l * w
  -- the turtle starts INSIDE the top corner block of the quarry volume:
  -- its own layer is layer 1, and `depth` counts that layer too
  local sign = (task.vert == "up") and 1 or -1  -- up-quarries mine skyward
  while true do
    checkControl()
    local topDug = task.layer * 3
    if task.depth and topDug >= task.depth then break end
    local remain = task.depth and (task.depth - topDug) or 3
    local centerY, digU, digD
    if remain >= 3 then
      centerY = sign * (topDug + 1)           -- middle of a 3-layer slice
      digU, digD = true, true
    elseif remain == 2 then
      centerY = sign * topDug                 -- near layer; dig the far one
      digU, digD = (sign > 0), (sign < 0)
    else
      centerY = sign * topDug                 -- single layer, no extra digs
      digU, digD = false, false
    end

    local reverse = (task.layer % 2 == 1)
    local function mineCell(i)
      local cx, r = cellCoord(i, l, w)
      local cz = (task.dir == "left") and -r or r  -- width side is choosable
      local c = { x = cx, y = centerY, z = cz }
      if goTo(c) or goTo(c, true) then
        if digU then digUpSafe() end
        if digD then digDownSafe() end
        maintainInventory(c)
        return true
      end
      return false
    end
    local failed = {}
    while task.cell < cells do
      checkControl()
      local i = reverse and (cells - 1 - task.cell) or task.cell
      setStatus("quarry", ("layer %d, cell %d/%d"):format(task.layer + 1, task.cell + 1, cells))
      if not mineCell(i) then
        table.insert(failed, i)
        task.failures = (task.failures or 0) + 1
      end
      task.cell = task.cell + 1
      saveState()
    end
    -- a second sweep usually reaches cells that were only shadowed
    -- BEHIND a bedrock column on the serpentine's angle of approach
    for _, i in ipairs(failed) do
      checkControl()
      if mineCell(i) then
        task.failures = task.failures - 1
        saveState()
      end
    end

    if (task.failures or 0) >= cells then
      finishTask("hit bedrock or the world limit")
      return
    end
    task.layer = task.layer + 1
    task.cell = 0
    task.failures = 0
    saveState()
  end
  finishTask("quarry complete")
end

-- path cell i (0-based) of a possibly-snaking strip: rows every 3 blocks
-- (a 2-block gap of untouched stone between them), joined by 2-cell
-- connectors at alternating ends
local function stripCell(i, len, snakes)
  if i < len then return i + 1, 0 end
  local seg = len + 2
  local j = i - len
  local s = math.floor(j / seg) + 1        -- which snaked row (1-based)
  local k = j % seg
  local endX = (s % 2 == 1) and len or 1   -- end where the previous row finished
  if k < 2 then
    return endX, (s - 1) * 3 + 1 + k       -- connector through the gap
  end
  local m = k - 2
  local x = (s % 2 == 1) and (len - m) or (1 + m)
  return x, s * 3
end

local function stripTotal(len, snakes)
  return len + (snakes or 0) * (len + 2)
end

local function runStrip()
  local len = task.len
  local snakes = task.snakes or 0
  local total = task.total or stripTotal(len, snakes)
  while task.cell < total do
    checkControl()
    local i = task.cell
    local x, z = stripCell(i, len, snakes)
    if task.dir == "left" then z = -z end -- snaked rows on the chosen side
    setStatus("strip", ("block %d/%d"):format(i + 1, total))
    if not goTo({ x = x, y = 1, z = z }) then -- travel the upper level
      finishTask("tunnel blocked")
      return
    end
    digDownSafe() -- clear the floor level of the 1x2 tunnel

    if cfg.STRIP_VEIN then
      dropJunk()
      if freeSlots() < 3 then maintainInventory({ x = x, y = 1, z = z }) end
      veinCheck(cfg.VEIN_DEPTH)     -- upper level: sides, ceiling, ahead
      if tryDown() then
        veinCheck(cfg.VEIN_DEPTH)   -- lower level: sides, floor
        tryUp()
      end
    end

    if cfg.ORE_SCAN and (i + 1) % cfg.SCAN_INTERVAL == 0 then
      scanAndChase({ x = x, y = 1, z = z })
    end

    maintainInventory({ x = x, y = 1, z = z })

    if cfg.PLACE_TORCHES and (i + 1) % cfg.TORCH_INTERVAL == 0 then
      if placeTorchDown() then
        task.torchWarned = nil
      elseif not task.torchWarned then
        task.torchWarned = true -- warn once, not at every interval
        note("no torches aboard to place - restock me (or enable CRAFT_TORCHES)")
      end
    end

    task.cell = i + 1
    saveState()
  end
  finishTask("strip complete")
end

local function runGoto()
  local target
  if task.world then
    target = relFromWorld({ x = task.x, y = task.y, z = task.z })
    if not target then
      note("Cannot go to world coords: no GPS calibration")
      task = nil
      saveState()
      setStatus("idle")
      return
    end
  else
    target = { x = task.x, y = task.y, z = task.z }
  end
  setStatus("goto", ("%d, %d, %d"):format(task.x, task.y, task.z))
  goTo(target)
  task = nil
  saveState()
  setStatus("idle", "arrived")
end

-- move into position for a multi-turtle quarry and report ready; mining
-- only begins when the master follows up with a start command
local function runMuster()
  local master = task.master
  if task.right ~= nil then
    -- line mode: sidestep relative to our current facing (no GPS needed)
    local n = task.right
    setStatus("muster", n == 0 and "already in position"
      or ("shifting %d %s"):format(math.abs(n), n < 0 and "left" or "right"))
    if n ~= 0 then
      local h = heading
      face(n > 0 and (h + 1) % 4 or (h + 3) % 4)
      for _ = 1, math.abs(n) do
        if not tryForward() then
          setStatus("blocked", "cannot reach my tile - move me by hand")
          face(h)
          task = nil
          saveState()
          return
        end
      end
      face(h)
    end
  else
    -- GPS mode: travel to absolute coordinates and face the given way
    setStatus("muster", ("to %d,%d,%d"):format(task.x, task.y, task.z))
    if not calib then pcall(calibrate) end
    local target = calib and relFromWorld({ x = task.x, y = task.y, z = task.z })
    if not target then
      note("muster needs GPS - place me at my tile by hand instead")
      task = nil
      saveState()
      setStatus("idle")
      return
    end
    if not goTo(target) then
      setStatus("blocked", "cannot reach my tile - move me by hand")
      task = nil
      saveState()
      return
    end
    if task.face then face((task.face - calib.offset) % 4) end
  end
  task = nil
  saveState()
  if hasModem and master then
    rednet.send(master, { kind = "ready", id = os.getComputerID(),
                          label = os.getComputerLabel() }, PROTO_STATUS)
  end
  setStatus("ready", "in position - waiting for start")
end

local function runTask()
  if task.kind == "quarry" then runQuarry()
  elseif task.kind == "strip" then runStrip()
  elseif task.kind == "goto" then runGoto()
  elseif task.kind == "muster" then runMuster()
  else
    note("Unknown task kind: " .. tostring(task.kind))
    task = nil
    saveState()
  end
end

-- ================= interrupt handling & worker =================

local function waitForFuel()
  local target = math.min(cfg.REFUEL_TARGET, 20000)
  while fuelLevel() < target and fuelLevel() ~= math.huge do
    if refuelFromInventory(target) then break end
    setStatus("waiting", "out of fuel - put coal in my inventory")
    sleep(3)
    checkControl()
  end
  setStatus("refuelled", tostring(turtle.getFuelLevel()))
end

local function handleInterrupt(kind)
  recovering = true
  local ok, err = pcall(function()
    if kind == "stop" then
      if task then task.paused = true end
      saveState()
      setStatus("paused", "stopped in place")
    elseif kind == "return" then
      goHomeAndUnload()
      if task then task.paused = true end
      saveState()
      setStatus("paused", "parked at home")
    elseif kind == "abort" then
      task = nil
      saveState()
      setStatus("idle", "task aborted")
    elseif kind == "fuel" then
      goHomeAndUnload()
      waitForFuel()
      -- not paused: the worker loop resumes the task automatically
    elseif kind == "fuelwait" then
      waitForFuel() -- AUTO_RETURN off: wait right where we are
    end
  end)
  recovering = false
  if not ok and type(err) == "table" and err.wb then
    handleInterrupt(err.wb) -- a stop/abort arrived while recovering
  end
end

local function workerLoop()
  while true do
    if task and not task.paused then
      local ok, err = pcall(runTask)
      if not ok then
        if type(err) == "table" and err.wb then
          handleInterrupt(err.wb)
        else
          if task then task.paused = true end
          saveState()
          setStatus("error", tostring(err))
        end
      end
      if not task and not hasModem then
        print("Task finished. Bye!")
        return -- standalone turtle: end the program instead of idling forever
      end
    else
      sleep(0.3)
    end
  end
end

-- ================= command handling =================

local function coerce(v)
  if v == "true" then return true end
  if v == "false" then return false end
  local n = tonumber(v)
  if n then return n end
  return v
end

local function startTask(t)
  rebase()
  pcall(calibrate) -- calibration moves the turtle; never let a fuel interrupt escape here
  haul = { total = 0, ores = {} }
  t.paused = false
  task = t
  saveState()
end

local function handleCmd(sender, msg)
  local function reply(text)
    if hasModem then
      rednet.send(sender, { kind = "note", id = os.getComputerID(),
                            label = os.getComputerLabel(), text = text }, PROTO_STATUS)
    end
  end

  -- when locked, only the paired master may control us (monitoring stays open)
  if cfg.MASTER_ID ~= 0 and sender ~= cfg.MASTER_ID
     and msg.cmd ~= "ping" and msg.cmd ~= "get" then
    reply(("locked to master #%d"):format(cfg.MASTER_ID))
    return
  end

  if msg.cmd == "ping" or msg.cmd == "get" then
    rednet.send(sender, buildStatus(), PROTO_STATUS)

  elseif msg.cmd == "start" then
    if task and not task.paused then
      reply("busy - stop me first")
      return
    end
    if msg.mode == "quarry" and msg.l and msg.w then
      startTask({ kind = "quarry", l = msg.l, w = msg.w, depth = msg.depth,
                  dir = msg.dir, vert = msg.vert, layer = 0, cell = 0 })
      reply(("starting quarry %dx%d"):format(msg.l, msg.w))
    elseif msg.mode == "strip" and msg.len then
      local snakes = msg.snakes or 0
      startTask({ kind = "strip", len = msg.len, snakes = snakes, dir = msg.dir,
                  total = stripTotal(msg.len, snakes), cell = 0 })
      reply(("starting strip %d%s"):format(msg.len,
        snakes > 0 and (" x" .. (snakes + 1) .. " snaked rows") or ""))
    else
      reply("bad start parameters")
    end

  elseif msg.cmd == "muster" then
    -- multi-quarry positioning: move to the assigned tile, report ready,
    -- and wait; the master sends start once every turtle is in place
    if task and not task.paused then
      reply("busy - stop me first")
      return
    end
    task = { kind = "muster", x = msg.x, y = msg.y, z = msg.z,
             face = msg.face, right = msg.right, master = sender }
    saveState()
    reply("mustering")

  elseif msg.cmd == "pose" then
    -- refresh GPS calibration and report back (position + world heading);
    -- calibration steps the turtle forward, so never do it mid-task
    if not (task and not task.paused) then
      pcall(calibrate)
    end
    rednet.send(sender, buildStatus(), PROTO_STATUS)

  elseif msg.cmd == "goto" then
    if task and not task.paused then
      reply("busy - stop me first")
      return
    end
    task = { kind = "goto", x = msg.x, y = msg.y, z = msg.z, world = msg.world and true or false }
    saveState()
    reply("moving")

  elseif msg.cmd == "stop" then
    if task and not task.paused then control.request = "stop" else reply("nothing to stop") end
  elseif msg.cmd == "return" then
    if task and not task.paused then control.request = "return"
    else task = { kind = "goto", x = 0, y = 0, z = 0, world = false } saveState() end
  elseif msg.cmd == "abort" then
    if task and not task.paused then control.request = "abort"
    else task = nil saveState() setStatus("idle", "task cleared") end
  elseif msg.cmd == "resume" then
    if task and task.paused then
      task.paused = false
      saveState()
      reply("resuming")
    else
      reply("nothing to resume")
    end

  elseif msg.cmd == "set" then
    if msg.key and cfg[msg.key] ~= nil and msg.value ~= nil then
      cfg[msg.key] = msg.value
      saveConfig()
      reply(msg.key .. " = " .. tostring(msg.value))
      broadcastStatus()
    else
      reply("unknown config key: " .. tostring(msg.key))
    end

  elseif msg.cmd == "update" then
    -- over-the-air code update pushed by the master
    if type(msg.code) == "string" and #msg.code > 1000 then
      local loader = loadstring or load
      local fn, err = loader(msg.code)
      if fn then
        -- write the file we are RUNNING FROM, not just /wb2.lua: a
        -- pastebin-installed fleet runs an extensionless /wb2, which
        -- shadows /wb2.lua on the shell path - updating only the
        -- latter acks "updated" forever while the old code keeps
        -- booting. Update both names and the shadow disappears.
        local paths = { ["/wb2.lua"] = true }
        if shell and shell.getRunningProgram then
          local self = shell.getRunningProgram()
          if self and self ~= "" then paths["/" .. self] = true end
        end
        for p in pairs(paths) do
          local f = fs.open(p, "w")
          if f then
            f.write(msg.code)
            f.close()
          end
        end
        reply("updated - rebooting")
        os.reboot() -- startup resumes any saved task on the new code
      else
        reply("update rejected: " .. tostring(err))
      end
    else
      reply("update rejected: no code")
    end

  elseif msg.cmd == "reboot" then
    reply("rebooting")
    os.reboot()
  end
end

local function commsLoop()
  if not hasModem then
    while true do os.pullEvent("wb2_never") end
  end
  while true do
    local sender, msg = rednet.receive(PROTO_CMD)
    if type(msg) == "table" and msg.cmd then
      pcall(handleCmd, sender, msg)
    end
  end
end

local function heartbeatLoop()
  if not hasModem then
    while true do os.pullEvent("wb2_never") end
  end
  while true do
    broadcastStatus()
    sleep(cfg.STATUS_INTERVAL)
  end
end

-- ================= CLI / wizard =================

local function ask(prompt, default)
  write(prompt)
  local v = read()
  if v == "" then return default end
  return v
end

local function wizard()
  print("World Breaker 2 - setup")
  print("(enter accepts the [default])")
  local mode = ask("Mode - [q]uarry / strip (q/s) [q]: ", "q")
  if mode:lower():sub(1, 1) == "s" then
    local len = tonumber(ask("Tunnel length [64]: ", "64")) or 64
    cfg.PLACE_TORCHES = ask("Place torches? (y/n) [y]: ", "y"):lower():sub(1, 1) == "y"
    cfg.STRIP_VEIN = ask("Chase ore veins? (y/n) [y]: ", "y"):lower():sub(1, 1) == "y"
    local snakes, dir = 0, nil
    if ask("Snake back and forth? (y/n) [n]: ", "n"):lower():sub(1, 1) == "y" then
      snakes = tonumber(ask("How many times to wind back? [4]: ", "4")) or 4
      dir = ask("Snake to my right or left? (r/l) [r]: ", "r"):lower():sub(1, 1) == "l"
            and "left" or "right"
    end
    saveConfig()
    print("(more toggles: run 'wb2 config' / 'wb2 set <KEY> <value>')")
    return { kind = "strip", len = len, snakes = snakes, dir = dir,
             total = stripTotal(len, snakes), cell = 0 }
  else
    local l = tonumber(ask("Length (forward) [16]: ", "16")) or 16
    local w = tonumber(ask("Width (to my right/left) [16]: ", "16")) or 16
    local dir = ask("Width to my right or left? (r/l) [r]: ", "r"):lower():sub(1, 1) == "l"
                and "left" or "right"
    local vert = ask("Dig down or up? (d/u) [d]: ", "d"):lower():sub(1, 1) == "u"
                 and "up" or "down"
    local d = tonumber(ask("Depth/height (blank = to bedrock/sky): ", ""))
    print("(I count my own layer as layer 1 - I sit inside the corner block)")
    return { kind = "quarry", l = l, w = w, depth = d,
             dir = dir, vert = vert, layer = 0, cell = 0 }
  end
end

local function printConfig()
  for k, v in pairs(cfg) do
    if type(v) == "table" then
      print(k .. " = {" .. table.concat(v, ", ") .. "}")
    else
      print(k .. " = " .. tostring(v))
    end
  end
end

-- ================= main =================

local args = { ... }

if not fs.exists(STATE_DIR) then fs.makeDir(STATE_DIR) end
if not os.getComputerLabel() then
  os.setComputerLabel("WB-" .. os.getComputerID())
end
loadConfig()
openModems()

-- two copies under different names shadow each other on the shell path
-- and make OTA updates appear to do nothing; say so loudly
if fs.exists("/wb2") and fs.exists("/wb2.lua") then
  local me = (shell and shell.getRunningProgram and shell.getRunningProgram()) or "?"
  print(("Warning: both /wb2 and /wb2.lua exist. I'm running /%s - delete the other copy."):format(me))
end

local verb = (args[1] or ""):lower()

if verb == "set" then
  if args[2] and args[3] ~= nil and cfg[args[2]] ~= nil then
    cfg[args[2]] = coerce(args[3])
    saveConfig()
    print(args[2] .. " = " .. tostring(cfg[args[2]]))
  else
    print("Unknown key. Run 'wb2 config' to list keys.")
  end
  return
elseif verb == "config" then
  printConfig()
  return
elseif verb == "reset" then
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  if fs.exists(CONFIG_FILE) then fs.delete(CONFIG_FILE) end
  print("Saved task and config cleared.")
  return
elseif verb == "quarry" then
  local l = tonumber(args[2])
  local w = tonumber(args[3])
  if not (l and w) then
    print("Usage: wb2 quarry <length> <width> [depth] [left|right] [up|down]")
    return
  end
  local d, dir, vert
  for i = 4, #args do
    local a = args[i]:lower()
    if tonumber(a) then d = tonumber(a)
    elseif a == "left" or a == "right" then dir = a
    elseif a == "up" or a == "down" then vert = a end
  end
  startTask({ kind = "quarry", l = l, w = w, depth = d,
              dir = dir, vert = vert, layer = 0, cell = 0 })
elseif verb == "strip" then
  local len = tonumber(args[2])
  if not len then
    print("Usage: wb2 strip <length> [snakes] [left|right]")
    return
  end
  local snakes, dir = 0, nil
  for i = 3, #args do
    local a = args[i]:lower()
    if tonumber(a) then snakes = tonumber(a)
    elseif a == "left" or a == "right" then dir = a end
  end
  startTask({ kind = "strip", len = len, snakes = snakes, dir = dir,
              total = stripTotal(len, snakes), cell = 0 })
elseif verb == "resume" then
  if not loadState() or not task then
    print("Nothing to resume.")
    if not hasModem then return end
    print("Listening for master commands instead.")
    setStatus("idle")
  else
    -- fix any drift from a mid-move server stop, if GPS is reachable
    if hasModem and calib then
      local x, y, z = gps.locate(1)
      if x then
        local rel = relFromWorld({ x = x, y = y, z = z })
        if rel then pos = rel saveState() end
      end
    end
    setStatus(task.paused and "paused" or "resuming",
      task.kind .. (task.paused and " (paused - send resume to continue)" or ""))
  end
elseif verb == "listen" then
  if not hasModem then
    print("No modem attached - nothing to listen with.")
    print("Equip a wireless modem, or run 'wb2' to mine standalone.")
    return
  end
  setStatus("idle", "awaiting master commands")
elseif verb == "" then
  startTask(wizard())
else
  print("Usage: wb2 [quarry|strip|listen|resume|set|config|reset]")
  return
end

if fuelLevel() ~= math.huge and fuelLevel() < 100 then
  print(("Warning: fuel is low (%d). Put coal in my inventory - I refuel myself."):format(fuelLevel()))
end
recommendInventory()

parallel.waitForAny(workerLoop, commsLoop, heartbeatLoop)
