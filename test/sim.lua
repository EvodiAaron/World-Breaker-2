-- Headless simulator for wb2.lua — run with desktop Lua (5.3+):
--   lua test/sim.lua
-- Mocks just enough of the ComputerCraft APIs to drive real mining
-- runs and assert on the resulting world. Not a CC emulator; comms,
-- GPS and crafting paths are exercised only as far as their guards.

local SCRIPT = arg[0]:match("^(.*)/[^/]*$") or "."
local WB2 = SCRIPT .. "/../turtle/wb2.lua"

-- ===================== mock environment =====================

local world, files, inv, tpos, thead, fuel, labels
local containers   -- [key] = list of {name, count} stacks (chest inventories)
local equipment    -- what is on each turtle side

-- comms mocks, opt-in per scenario (all cleared by resetWorld):
local modemSide    -- set to a side name to give the turtle a wireless modem
local gpsEnabled   -- gps.locate returns tpos + (100, 60, 200) when true
local rednetQueue  -- injected commands: {when?, sender, msg, proto}; `when`
                   -- is an optional function - the message is delivered as
                   -- soon as it returns true (mid-run config changes etc.)
local rednetSent   -- every message the turtle broadcast/sent
local shutdownWhen -- function(msg): with a modem the worker loop idles
                   -- forever, so the sim ends once a sent status matches
local pendingShutdown
local simEvents    -- scheduled world changes: {when = fn->bool, fn = ...};
                   -- fired by the scheduler once `when` first returns true
                   -- (e.g. "the blocking turtle moves away")

local DXW = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local DZW = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

local function key(x, y, z) return x .. "," .. y .. "," .. z end

local function resetWorld()
  world, files, inv, containers = {}, {}, {}, {}
  for i = 1, 16 do inv[i] = nil end
  tpos, thead, fuel = { x = 0, y = 0, z = 0 }, 0, 100000
  labels = {}
  equipment = { left = nil, right = "minecraft:diamond_pickaxe" }
  if turtle then turtle.craft = nil end
  modemSide, gpsEnabled, shutdownWhen = nil, false, nil
  rednetQueue, rednetSent, pendingShutdown = {}, {}, false
  simEvents = {}
end

-- in CC every turtle op yields; mirroring that gives the comms coroutine
-- a fair turn mid-task (needed for injected commands). Top-level calls
-- (outside the scheduler) must not yield, hence the guard.
local function maybeYield()
  if coroutine.isyieldable() then coroutine.yield("op") end
end

local function addChest(x, y, z)
  world[key(x, y, z)] = "minecraft:chest"
  containers[key(x, y, z)] = {}
end

local function ahead() return tpos.x + DXW[thead], tpos.y, tpos.z + DZW[thead] end

-- fluids: invisible to detect(), not diggable, don't block movement —
-- but they DO show up on inspect(), exactly like in-game
local function isFluid(b)
  return b == "minecraft:lava" or b == "minecraft:flowing_lava"
      or b == "minecraft:water" or b == "minecraft:flowing_water"
end

local function dropName(block)
  if block == "minecraft:stone" then return "minecraft:cobblestone" end
  return block
end

local function addItem(name)
  for i = 1, 16 do
    if inv[i] and inv[i].name == name and inv[i].count < 64 then
      inv[i].count = inv[i].count + 1
      return true
    end
  end
  for i = 1, 16 do
    if not inv[i] then
      inv[i] = { name = name, count = 1 }
      return true
    end
  end
  return false -- inventory full: item lost, same as CC
end

local selected = 1

local function takeSelected()
  local s = inv[selected]
  if not s then return nil end
  s.count = s.count - 1
  local name = s.name
  if s.count == 0 then inv[selected] = nil end
  return name
end

-- ===== turtle API =====
turtle = {}
function turtle.select(n) selected = n return true end
function turtle.getItemCount(n) return inv[n] and inv[n].count or 0 end
function turtle.getItemDetail(n)
  n = n or selected
  if inv[n] then return { name = inv[n].name, count = inv[n].count } end
  return nil
end
function turtle.getFuelLevel() return fuel end
function turtle.refuel(n)
  local s = inv[selected]
  if s and s.name == "minecraft:coal" then
    if (n or 1) > 0 then takeSelected() fuel = fuel + 80 end
    return true
  end
  if s and s.name == "minecraft:lava_bucket" then
    if (n or 1) > 0 then
      s.name = "minecraft:bucket" -- the empty bucket stays behind
      fuel = fuel + 1000
    end
    return true
  end
  return false
end

local function move(dx, dy, dz)
  maybeYield()
  local nx, ny, nz = tpos.x + dx, tpos.y + dy, tpos.z + dz
  local b = world[key(nx, ny, nz)]
  if b and not isFluid(b) then return false end
  if fuel <= 0 then return false end
  fuel = fuel - 1
  tpos = { x = nx, y = ny, z = nz }
  return true
end
function turtle.forward() local dx, _, dz = DXW[thead], 0, DZW[thead] return move(DXW[thead], 0, DZW[thead]) end
function turtle.back() return move(-DXW[thead], 0, -DZW[thead]) end
function turtle.up() return move(0, 1, 0) end
function turtle.down() return move(0, -1, 0) end
function turtle.turnLeft() thead = (thead + 3) % 4 return true end
function turtle.turnRight() thead = (thead + 1) % 4 return true end

local function digAt(x, y, z)
  maybeYield()
  local b = world[key(x, y, z)]
  if not b then return false end
  if b == "minecraft:bedrock" or isFluid(b) then return false end
  world[key(x, y, z)] = nil
  addItem(dropName(b))
  return true
end
function turtle.dig() return digAt(ahead()) end
function turtle.digUp() return digAt(tpos.x, tpos.y + 1, tpos.z) end
function turtle.digDown() return digAt(tpos.x, tpos.y - 1, tpos.z) end

local function inspectAt(x, y, z)
  local b = world[key(x, y, z)]
  if b then return true, { name = b } end
  return false, "No block to inspect" -- CC returns a truthy STRING here
end
function turtle.inspect() return inspectAt(ahead()) end
function turtle.inspectUp() return inspectAt(tpos.x, tpos.y + 1, tpos.z) end
function turtle.inspectDown() return inspectAt(tpos.x, tpos.y - 1, tpos.z) end
local function detectAt(x, y, z)
  local b = world[key(x, y, z)]
  return b ~= nil and not isFluid(b)
end
function turtle.detect() return detectAt(ahead()) end
function turtle.detectUp() return detectAt(tpos.x, tpos.y + 1, tpos.z) end
function turtle.detectDown() return detectAt(tpos.x, tpos.y - 1, tpos.z) end

function turtle.attack() return false end
function turtle.attackUp() return false end
function turtle.attackDown() return false end

local function placeAt(x, y, z)
  local name = inv[selected] and inv[selected].name
  if not name then return false end
  -- an empty bucket "placed" against a lava source scoops it up
  if name == "minecraft:bucket" and world[key(x, y, z)] == "minecraft:lava" then
    takeSelected()
    world[key(x, y, z)] = nil
    addItem("minecraft:lava_bucket")
    return true
  end
  if world[key(x, y, z)] then return false end
  takeSelected()
  world[key(x, y, z)] = name
  -- any mod's chest becomes a working container when placed
  if name:find("chest") then containers[key(x, y, z)] = {} end
  return true
end
function turtle.place() return placeAt(ahead()) end
function turtle.placeDown() return placeAt(tpos.x, tpos.y - 1, tpos.z) end
function turtle.placeUp() return placeAt(tpos.x, tpos.y + 1, tpos.z) end

local function dropInto(x, y, z, n)
  local s = inv[selected]
  if not s then return false end
  n = math.min(n or s.count, s.count) -- turtle.drop([count]) drops part of the stack
  if n <= 0 then return true end
  local c = containers[key(x, y, z)]
  if c then table.insert(c, { name = s.name, count = n }) end
  -- no container = dropped into the void
  if n >= s.count then inv[selected] = nil else s.count = s.count - n end
  return true
end
function turtle.drop(n) local x, y, z = ahead() return dropInto(x, y, z, n) end
function turtle.dropDown(n) return dropInto(tpos.x, tpos.y - 1, tpos.z, n) end
function turtle.dropUp(n) return dropInto(tpos.x, tpos.y + 1, tpos.z, n) end

local function addStack(name, count)
  for i = 1, 16 do
    if inv[i] and inv[i].name == name and inv[i].count + count <= 64 then
      inv[i].count = inv[i].count + count
      return true
    end
  end
  for i = 1, 16 do
    if not inv[i] then
      inv[i] = { name = name, count = count }
      return true
    end
  end
  return false
end

function turtle.suck()
  local c = containers[key(ahead())]
  if not c or #c == 0 then return false end
  if addStack(c[1].name, c[1].count) then
    table.remove(c, 1)
    return true
  end
  return false
end

function turtle.transferTo(target, count)
  local s = inv[selected]
  if not s or target == selected then return false end
  count = math.min(count or s.count, s.count)
  local t = inv[target]
  if t and t.name ~= s.name then return false end
  if t then
    count = math.min(count, 64 - t.count)
    if count <= 0 then return false end
    t.count = t.count + count
  else
    inv[target] = { name = s.name, count = count }
  end
  s.count = s.count - count
  if s.count == 0 then inv[selected] = nil end
  return true
end

-- ===== equipment & crafting (turtle.craft exists only with a workbench on) =====
local GRIDS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

local function craftImpl()
  for i = 1, 16 do
    local inGrid = false
    for _, g in ipairs(GRIDS) do if g == i then inGrid = true end end
    if not inGrid and inv[i] then return false end -- CC: non-grid slots must be empty
  end
  local function n(s) return inv[s] and inv[s].count or 0 end
  local function nm(s) return inv[s] and inv[s].name or nil end
  local function only(slots)
    for _, g in ipairs(GRIDS) do
      local listed = false
      for _, s in ipairs(slots) do if s == g then listed = true end end
      if not listed and inv[g] then return false end
    end
    return true
  end
  local function consume(s, c)
    inv[s].count = inv[s].count - c
    if inv[s].count == 0 then inv[s] = nil end
  end
  local function isPlankName(x) return x and x:find("plank") ~= nil end
  local function isLogName(x) return x and x:find("log") ~= nil and not x:find("logi") end
  if nm(1) == "minecraft:coal" and nm(5) == "minecraft:stick" and only({ 1, 5 }) then
    local c = math.min(n(1), n(5))
    consume(1, c) consume(5, c)
    for _ = 1, c * 4 do addItem("minecraft:torch") end
    return true
  end
  -- sticks: two identical plank stacks (mixing mods' woods is NOT a recipe)
  if isPlankName(nm(1)) and nm(1) == nm(5) and only({ 1, 5 }) then
    local c = math.min(n(1), n(5))
    consume(1, c) consume(5, c)
    for _ = 1, c * 4 do addItem("minecraft:stick") end
    return true
  end
  -- planks from any mod's log, yielding that mod's planks
  if isLogName(nm(1)) and only({ 1 }) then
    local c = n(1)
    local planks = nm(1) == "minecraft:log" and "minecraft:planks" or nm(1):gsub("log", "planks")
    consume(1, c)
    for _ = 1, c * 4 do addItem(planks) end
    return true
  end
  -- chest: ring of eight identical plank stacks
  local ring = { 1, 2, 3, 5, 7, 9, 10, 11 }
  local okRing, c = isPlankName(nm(1)), math.huge
  for _, s in ipairs(ring) do
    if nm(s) ~= nm(1) then okRing = false end
    c = math.min(c, n(s))
  end
  if okRing and only(ring) then
    for _, s in ipairs(ring) do consume(s, c) end
    for _ = 1, c do addItem("minecraft:chest") end
    return true
  end
  return false
end

local function equipSide(side)
  local incoming = nil
  if inv[selected] then
    incoming = inv[selected].name
    inv[selected].count = inv[selected].count - 1
    if inv[selected].count == 0 then inv[selected] = nil end
  end
  local outgoing = equipment[side]
  equipment[side] = incoming
  if outgoing then
    if inv[selected] then addItem(outgoing) else inv[selected] = { name = outgoing, count = 1 } end
  end
  local crafty = equipment.left == "minecraft:crafting_table" or equipment.right == "minecraft:crafting_table"
  turtle.craft = crafty and craftImpl or nil
  return true
end
function turtle.equipLeft() return equipSide("left") end
function turtle.equipRight() return equipSide("right") end
-- turtle.craft starts nil: not a crafty turtle until a workbench is equipped

-- ===== fs / os / misc APIs =====
fs = {}
function fs.exists(p) return files[p] ~= nil end
function fs.makeDir(p) end
function fs.delete(p) files[p] = nil end
function fs.open(p, mode)
  if mode == "r" then
    local content = files[p]
    if not content then return nil end
    return { readAll = function() return content end, close = function() end }
  else
    local buf = {}
    return {
      write = function(_, s) if s == nil then s = _ end table.insert(buf, s) end,
      writeLine = function(_, s) if s == nil then s = _ end table.insert(buf, tostring(s) .. "\n") end,
      close = function() files[p] = table.concat(buf) end,
    }
  end
end

textutils = {}
local function ser(v, seen)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      table.insert(parts, "[" .. ser(k) .. "]=" .. ser(val))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
function textutils.serialize(t) return ser(t) end
function textutils.unserialize(s)
  local f = load("return " .. s)
  if f then return f() end
  return nil
end

peripheral = {
  getType = function(side)
    if modemSide and side == modemSide then return "modem" end
    return nil
  end,
  -- a Plethora block scanner: works only while equipped, reports every
  -- block within an 8-block cube as WORLD-axis offsets (like the mod)
  wrap = function(side)
    if equipment[side] and equipment[side]:find("scanner") then
      return { scan = function()
        local res = {}
        for k, b in pairs(world) do
          local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
          x, y, z = tonumber(x) - tpos.x, tonumber(y) - tpos.y, tonumber(z) - tpos.z
          if math.abs(x) <= 8 and math.abs(y) <= 8 and math.abs(z) <= 8 then
            table.insert(res, { x = x, y = y, z = z, name = b })
          end
        end
        return res
      end }
    end
    return nil
  end,
}

rednet = {}
function rednet.open() end
local function recordSend(msg, proto)
  table.insert(rednetSent, { msg = msg, proto = proto })
  if shutdownWhen and type(msg) == "table" and shutdownWhen(msg) then
    pendingShutdown = true
  end
end
function rednet.broadcast(msg, proto) recordSend(msg, proto) end
function rednet.send(id, msg, proto) recordSend(msg, proto) end
function rednet.receive(proto)
  while true do
    for i, m in ipairs(rednetQueue) do
      if (not m.when or m.when()) and (not proto or m.proto == proto) then
        table.remove(rednetQueue, i)
        return m.sender or 1, m.msg, m.proto
      end
    end
    if pendingShutdown and #rednetQueue == 0 then
      coroutine.yield("shutdown")
    end
    coroutine.yield("park")
  end
end

gps = { locate = function()
  if not gpsEnabled then return nil end
  return 100 + tpos.x, 60 + tpos.y, 200 + tpos.z
end }

local osExtra = {
  getComputerID = function() return 7 end,
  getComputerLabel = function() return labels[1] end,
  setComputerLabel = function(l) labels[1] = l end,
  pullEvent = function() coroutine.yield("park") end,
  reboot = function() error("reboot called") end,
}
setmetatable(os, { __index = osExtra })

function sleep() coroutine.yield("sleep") end
write = io.write

parallel = {
  waitForAny = function(...)
    local cos = {}
    for _, fn in ipairs({ ... }) do table.insert(cos, coroutine.create(fn)) end
    local steps = 0
    while true do
      for _, co in ipairs(cos) do
        if coroutine.status(co) == "suspended" then
          local ok, ev = coroutine.resume(co)
          if not ok then error(ev, 0) end
          if ev == "shutdown" then return end -- see shutdownWhen
          if coroutine.status(co) == "dead" then return end
        end
      end
      for i = #simEvents, 1, -1 do
        if simEvents[i].when() then
          local e = table.remove(simEvents, i)
          e.fn()
        end
      end
      steps = steps + 1
      if steps > 2000000 then error("simulation did not terminate") end
    end
  end,
}

-- ===================== harness =====================

-- capture everything wb2 prints so scenarios can assert on status lines
local logLines = {}
local realPrint = print
function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  table.insert(logLines, table.concat(parts, " "))
  realPrint(...)
end
local function logClear() logLines = {} end
local function logHas(pattern)
  for _, line in ipairs(logLines) do
    if line:find(pattern) then return true end
  end
  return false
end

local function countInvItem(name)
  local total = 0
  for i = 1, 16 do
    if inv[i] and inv[i].name == name then total = total + inv[i].count end
  end
  return total
end

local failures = 0
local function check(cond, msg)
  if cond then
    print("  PASS  " .. msg)
  else
    failures = failures + 1
    print("  FAIL  " .. msg)
  end
end

local function runWB2(...)
  local chunk, err = loadfile(WB2)
  assert(chunk, err)
  chunk(...)
end

local function fillGround(x1, x2, z1, z2, y1, y2, block)
  for x = x1, x2 do
    for z = z1, z2 do
      for y = y1, y2 do
        world[key(x, y, z)] = block or "minecraft:stone"
      end
    end
  end
end

-- ---------- scenario 1: quarry ----------
-- the turtle sits INSIDE the top corner block: its own layer is layer 1,
-- so depth 3 spans y = 0 .. -2
print("scenario: quarry 3x2, depth 3 (turtle inside the corner block)")
resetWorld()
fillGround(-3, 6, -3, 6, -6, -1)          -- ground everywhere below y=0
world[key(-1, 0, 0)] = "minecraft:chest"  -- home chest behind the turtle
runWB2("quarry", "3", "2", "3")

local allMined = true
for x = 0, 2 do
  for z = 0, 1 do
    for y = 0, -2, -1 do
      if world[key(x, y, z)] then allMined = false end
    end
  end
end
check(allMined, "all 18 quarry blocks removed (y 0..-2)")
check(world[key(3, -1, 0)] ~= nil, "no digging beyond quarry length")
check(world[key(0, -1, -1)] ~= nil, "no digging beyond quarry width")
check(world[key(0, -3, 0)] ~= nil, "no digging below requested depth")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")
check(world[key(-1, 0, 0)] == "minecraft:chest", "home chest untouched")

-- ---------- scenario 2: quarry to bedrock ----------
print("scenario: quarry 2x2 down to bedrock")
resetWorld()
fillGround(-3, 5, -3, 5, -4, -1)
fillGround(-3, 5, -3, 5, -5, -5, "minecraft:bedrock")
world[key(-1, 0, 0)] = "minecraft:chest"
runWB2("quarry", "2", "2")

local mined = true
for x = 0, 1 do
  for z = 0, 1 do
    for y = -1, -4, -1 do
      if world[key(x, y, z)] then mined = false end
    end
  end
end
check(mined, "everything above bedrock removed")
check(world[key(0, -5, 0)] == "minecraft:bedrock", "bedrock survives")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 3: strip with vein chasing + torches ----------
print("scenario: strip 6 with ore vein and torches")
resetWorld()
fillGround(-2, 10, -3, 3, -3, 2)          -- solid rock band from y=-3..2
world[key(0, 0, 0)] = nil                  -- the turtle's own cell
world[key(-1, 0, 0)] = "minecraft:chest"
-- a small diamond vein hanging off the tunnel wall at floor level
world[key(3, 0, 1)] = "minecraft:diamond_ore"
world[key(3, 0, 2)] = "minecraft:diamond_ore"
world[key(3, -1, 1)] = "minecraft:diamond_ore"
inv[16] = { name = "minecraft:torch", count = 64 }

logClear()
runWB2("set", "PLACE_TORCHES", "true")
runWB2("set", "TORCH_INTERVAL", "2")
runWB2("strip", "6")

local tunnelClear = true
for x = 1, 6 do
  for y = 0, 1 do
    local b = world[key(x, y, 0)]
    if b and b ~= "minecraft:torch" then tunnelClear = false end
  end
end
check(tunnelClear, "1x2 tunnel is clear for 6 blocks")
check(world[key(3, 0, 1)] == nil, "ore vein block 1 extracted")
check(world[key(3, 0, 2)] == nil, "ore vein block 2 extracted (chased)")
check(world[key(3, -1, 1)] == nil, "ore vein block 3 extracted (chased down)")
check(logHas("diamond_ore found"), "diamond find announced (ALERT_BLOCKS)")
check(world[key(7, 1, 0)] ~= nil, "tunnel stops at requested length")
check(world[key(2, 0, 0)] == "minecraft:torch", "torch placed at interval 2")
check(world[key(4, 0, 0)] == "minecraft:torch", "torch placed at interval 4")
check(world[key(6, 0, 0)] == "minecraft:torch", "torch placed at interval 6")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home over its torches")

-- ---------- scenario 4: gravel column ----------
print("scenario: strip through gravel")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
world[key(-1, 0, 0)] = "minecraft:chest"
world[key(2, 1, 0)] = "minecraft:gravel"
world[key(2, 2, 0)] = "minecraft:gravel"   -- will not fall in the mock, but exercises the loop
runWB2("strip", "4")
check(world[key(2, 1, 0)] == nil and world[key(2, 0, 0)] == nil, "gravel cleared from tunnel")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 5: inventory fills up -> haul home mid-task ----------
print("scenario: strip 20 with unstackable loot (forces unload trips)")
resetWorld()
fillGround(-2, 25, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
world[key(-1, 0, 0)] = "minecraft:chest"
-- every block is unique, so nothing stacks and nothing counts as junk/ore
local n = 0
for k, v in pairs(world) do
  if v == "minecraft:stone" then
    n = n + 1
    world[k] = "mod:block_" .. n
  end
end
world[key(-1, 0, 0)] = "minecraft:chest"
runWB2("strip", "20")
local cleared = true
for x = 1, 20 do
  if world[key(x, 0, 0)] or world[key(x, 1, 0)] then cleared = false end
end
check(cleared, "full 20-block tunnel dug despite unload trips")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")
local slotsUsed = 0
for i = 1, 16 do if inv[i] then slotsUsed = slotsUsed + 1 end end
check(slotsUsed <= 2, "loot was unloaded to the home chest")

-- ---------- scenario 6: resume a half-finished quarry after 'reboot' ----------
print("scenario: resume quarry from saved state")
resetWorld()
fillGround(-3, 5, -3, 5, -6, -1)
world[key(-1, 0, 0)] = "minecraft:chest"
-- pretend cells 0 and 1 of a 2x2 quarry were already mined before the
-- "crash" (depth 3 spans y = 0..-2; the y=0 layer was already air)
world[key(0, -1, 0)] = nil world[key(0, -2, 0)] = nil
world[key(1, -1, 0)] = nil world[key(1, -2, 0)] = nil
tpos = { x = 1, y = -1, z = 0 }
thead = 0
files["/wb2data/state"] = textutils.serialize({
  pos = { x = 1, y = -1, z = 0 },
  heading = 0,
  task = { kind = "quarry", l = 2, w = 2, depth = 3, layer = 0, cell = 2 },
})
runWB2("resume")
local resumed = true
for x = 0, 1 do
  for z = 0, 1 do
    for y = 0, -2, -1 do
      if world[key(x, y, z)] then resumed = false end
    end
  end
end
check(resumed, "remaining quarry cells mined after resume")
check(world[key(0, -3, 0)] ~= nil, "resume respected the requested depth")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home after resume")

-- ---------- scenario 7: torch crafting via workbench tool-swap ----------
print("scenario: craft torches at home by swapping in a carried crafting table")
resetWorld()
fillGround(-2, 5, -2, 2, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)              -- loot chest behind home
addChest(0, 0, -1)              -- crafting buffer chest to the LEFT of home
inv[1] = { name = "minecraft:crafting_table", count = 1 }
inv[2] = { name = "minecraft:coal", count = 10 }
inv[3] = { name = "minecraft:log", count = 6 }

runWB2("set", "CRAFT_TORCHES", "true")
runWB2("set", "CRAFT_CHESTS", "true")
runWB2("strip", "2")

local function countInv(name)
  local total = 0
  for i = 1, 16 do
    if inv[i] and inv[i].name == name then total = total + inv[i].count end
  end
  return total
end
check(countInv("minecraft:torch") >= 24, "torches crafted (logs -> planks -> sticks -> torches)")
check(countInv("minecraft:chest") == 2, "chests crafted from logs (logs -> planks -> chests)")
check(countInv("minecraft:crafting_table") == 1, "crafting table back in the inventory")
check(equipment.right == "minecraft:diamond_pickaxe", "pickaxe re-equipped after crafting")
check(#containers[key(0, 0, -1)] == 0, "crafting buffer chest left empty")
check(countInv("minecraft:coal") == 4, "only the needed coal was consumed")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 8: no chest at home, but chests in inventory ----------
print("scenario: turtle places its own home chest from inventory")
resetWorld()
fillGround(-3, 4, -3, 4, -6, -1, "minecraft:iron_ore") -- non-junk loot so it must be hauled
inv[1] = { name = "minecraft:chest", count = 2 }
runWB2("quarry", "2", "2", "3")
check(world[key(-1, 0, 0)] == "minecraft:chest", "chest placed behind home from inventory")
check(#containers[key(-1, 0, 0)] > 0, "loot deposited into the placed chest")
check(countInv("minecraft:chest") == 1, "only one chest used")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")
-- depth 3 spans y 0..-2 and the y=0 layer is air, so 8 ore blocks
local savedState = textutils.unserialize(files["/wb2data/state"])
check(savedState and savedState.haul and savedState.haul.total == 8,
  "haul statistics: 8 blocks dug")
check(savedState and savedState.haul.ores["minecraft:iron_ore"] == 8,
  "haul statistics: all 8 counted as iron ore")

-- ---------- scenario 9: low fuel -> retreat home, refuel, resume ----------
print("scenario: low-fuel retreat home, refuel, auto-resume")
resetWorld()
fillGround(-2, 12, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
inv[1] = { name = "minecraft:coal", count = 20 }
fuel = 12 -- barely anything; forces a retreat almost immediately
logClear()
runWB2("set", "STRIP_VEIN", "false")
runWB2("set", "AUTO_REFUEL", "false")
runWB2("strip", "8")
check(logHas("refuelled"), "turtle retreated, waited, and refuelled at home")
local dug9 = true
for x = 1, 8 do
  if world[key(x, 0, 0)] or world[key(x, 1, 0)] then dug9 = false end
end
check(dug9, "strip completed after refuelling")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle home at end")
check(fuel > 500, "fuel restored from inventory coal")

-- ---------- scenario 10: snaking strip ----------
print("scenario: snaking strip (4 long, 2 snakes, 2-block gaps)")
resetWorld()
fillGround(-2, 8, -2, 10, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
runWB2("strip", "4", "2")
local rowsOk = true
for _, z in ipairs({ 0, 3, 6 }) do
  for x = 1, 4 do
    for y = 0, 1 do
      if world[key(x, y, z)] then rowsOk = false end
    end
  end
end
check(rowsOk, "all three rows dug (z = 0, 3, 6)")
local connOk = not (world[key(4, 0, 1)] or world[key(4, 0, 2)]
                 or world[key(1, 0, 4)] or world[key(1, 0, 5)])
check(connOk, "connectors dug at alternating ends")
local gapOk = world[key(2, 0, 1)] ~= nil and world[key(2, 0, 2)] ~= nil
          and world[key(3, 0, 4)] ~= nil and world[key(2, 0, 5)] ~= nil
check(gapOk, "2-block gaps between rows left intact")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 11: modded wood types (FTB naming schemes) ----------
print("scenario: craft torches from Biomes O' Plenty wood without mixing mods")
resetWorld()
fillGround(-2, 5, -2, 2, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
addChest(0, 0, -1)
inv[1] = { name = "minecraft:crafting_table", count = 1 }
inv[2] = { name = "minecraft:coal", count = 10 }
inv[3] = { name = "biomesoplenty:log_0", count = 2 }   -- modded log naming
inv[4] = { name = "minecraft:planks", count = 3 }      -- decoy minority planks
runWB2("set", "CRAFT_TORCHES", "true")
runWB2("strip", "2")
local function countInv11(name)
  local total = 0
  for i = 1, 16 do
    if inv[i] and inv[i].name == name then total = total + inv[i].count end
  end
  return total
end
check(countInv11("minecraft:torch") >= 24, "torches crafted from modded logs")
check(countInv11("minecraft:planks") == 3, "minority vanilla planks not mixed into the recipe")
check(countInv11("biomesoplenty:log_0") == 0, "modded logs were recognised and used")
check(equipment.right == "minecraft:diamond_pickaxe", "pickaxe re-equipped")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 12: lava-bucket refueling ----------
print("scenario: scoop a lava source into a carried bucket for fuel")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
world[key(2, 0, 0)] = "minecraft:lava"   -- source in the tunnel floor
inv[1] = { name = "minecraft:bucket", count = 1 }
fuel = 500                                -- below REFUEL_TARGET, so scooping is worth it
logClear()
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "4")
local function countInv12(name)
  local total = 0
  for i = 1, 16 do
    if inv[i] and inv[i].name == name then total = total + inv[i].count end
  end
  return total
end
check(logHas("scooped lava"), "lava scoop announced")
check(fuel > 1000, "lava burned for fuel (+1000)")
check(countInv12("minecraft:bucket") == 1, "empty bucket kept after refuelling")
check(countInv12("minecraft:lava_bucket") == 0, "lava bucket was consumed, not hauled")
check(world[key(2, 0, 0)] == nil, "lava source removed from the tunnel")
local dug12 = true
for x = 1, 4 do
  if world[key(x, 0, 0)] or world[key(x, 1, 0)] then dug12 = false end
end
check(dug12, "strip completed through the lava")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 13: torches enabled but none aboard ----------
print("scenario: PLACE_TORCHES on with no torches -> a single warning")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
logClear()
runWB2("set", "PLACE_TORCHES", "true")
runWB2("set", "TORCH_INTERVAL", "2")
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "4")
check(logHas("no torches aboard"), "missing-torch warning raised")
local warns = 0
for _, line in ipairs(logLines) do
  if line:find("no torches aboard") then warns = warns + 1 end
end
check(warns == 1, "warned once, not at every torch interval")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 14: buffer chest placed by the turtle itself ----------
print("scenario: turtle digs out and places its own crafting buffer chest")
resetWorld()
fillGround(-2, 5, -2, 2, -3, 2)      -- (0,0,-1), LEFT of home, is solid stone
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)                   -- loot chest only; NO buffer chest
inv[1] = { name = "minecraft:crafting_table", count = 1 }
inv[2] = { name = "minecraft:coal", count = 10 }
inv[3] = { name = "minecraft:log", count = 6 }
inv[4] = { name = "minecraft:chest", count = 1 }
logClear()
runWB2("set", "CRAFT_TORCHES", "true")
runWB2("strip", "2")
check(world[key(0, 0, -1)] == "minecraft:chest", "buffer chest placed to the LEFT of home")
check(logHas("Placed my own crafting buffer chest"), "self-placement announced")
check(countInvItem("minecraft:torch") >= 24, "torches crafted using the placed buffer")
check(countInvItem("minecraft:chest") == 0, "the carried chest was used for the buffer")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 15: quarry with the width to the LEFT ----------
print("scenario: quarry 2x2 depth 2, width to the left")
resetWorld()
fillGround(-3, 6, -6, 3, -6, -1)
world[key(-1, 0, 0)] = "minecraft:chest"
runWB2("quarry", "2", "2", "2", "left")
local leftMined = true
for x = 0, 1 do
  for z = 0, -1, -1 do
    if world[key(x, -1, z)] then leftMined = false end
  end
end
check(leftMined, "quarry dug on the LEFT side (z 0..-1)")
check(world[key(0, -1, 1)] ~= nil, "right side untouched")
check(world[key(0, -2, 0)] ~= nil, "no digging below depth 2 (y 0..-1)")
check(world[key(-1, 0, 0)] == "minecraft:chest", "home chest untouched")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 16: quarry mining upward ----------
print("scenario: quarry 2x2 height 3, upward")
resetWorld()
fillGround(-3, 6, -3, 6, 1, 4)       -- a solid slab overhead (y 1..4)
world[key(-1, 0, 0)] = "minecraft:chest"
runWB2("quarry", "2", "2", "3", "up")
local upMined = true
for x = 0, 1 do
  for z = 0, 1 do
    for y = 1, 2 do
      if world[key(x, y, z)] then upMined = false end
    end
  end
end
check(upMined, "volume above the turtle mined (y 0..2)")
check(world[key(0, 3, 0)] ~= nil, "no digging above the requested height")
check(world[key(0, -1, 0)] == nil, "nothing dug below the turtle")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 17: snaking strip to the LEFT ----------
print("scenario: snaking strip (4 long, 1 snake) to the left")
resetWorld()
fillGround(-2, 8, -10, 2, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
runWB2("strip", "4", "1", "left")
local rowsLeft = true
for _, z in ipairs({ 0, -3 }) do
  for x = 1, 4 do
    for y = 0, 1 do
      if world[key(x, y, z)] then rowsLeft = false end
    end
  end
end
check(rowsLeft, "both rows dug on the LEFT (z = 0 and z = -3)")
check(world[key(4, 0, -1)] == nil and world[key(4, 0, -2)] == nil,
  "connector dug through the gap at the far end")
check(world[key(2, 0, -1)] ~= nil and world[key(2, 0, -2)] ~= nil,
  "2-block gap between rows left intact")
check(world[key(1, 0, 1)] ~= nil, "nothing dug on the right side")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 18: config change applies mid-run ----------
print("scenario: PLACE_TORCHES enabled over rednet MID-RUN takes effect immediately")
resetWorld()
modemSide = "left"
fillGround(-2, 10, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
inv[16] = { name = "minecraft:torch", count = 16 }
runWB2("set", "PLACE_TORCHES", "false")
runWB2("set", "TORCH_INTERVAL", "2")
runWB2("set", "STRIP_VEIN", "false")
-- flip the toggle once the tunnel floor reaches x=5 (i.e. mid-task)
table.insert(rednetQueue, { proto = "wb2cmd", sender = 42,
  msg = { cmd = "set", key = "PLACE_TORCHES", value = true },
  when = function() return world[key(5, 0, 0)] == nil end })
shutdownWhen = function(msg) return msg.state == "done" end
runWB2("strip", "8")
check(world[key(2, 0, 0)] ~= "minecraft:torch" and world[key(4, 0, 0)] ~= "minecraft:torch",
  "no torches placed before the toggle arrived")
check(world[key(6, 0, 0)] == "minecraft:torch", "torch at 6: change applied mid-run")
check(world[key(8, 0, 0)] == "minecraft:torch", "torch at 8: change stayed applied")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 19: bedrock intrusion inside a quarry ----------
print("scenario: quarry tolerates a bedrock column poking into it")
resetWorld()
fillGround(-3, 6, -3, 6, -6, -1)
for y = -2, -6, -1 do world[key(1, y, 1)] = "minecraft:bedrock" end
world[key(-1, 0, 0)] = "minecraft:chest"
logClear()
runWB2("quarry", "3", "3", "6")
local aroundBedrock = true
for x = 0, 2 do
  for z = 0, 2 do
    for y = -1, -5, -1 do
      if not (x == 1 and z == 1 and y <= -2) then
        if world[key(x, y, z)] then aroundBedrock = false end
      end
    end
  end
end
check(aroundBedrock, "every reachable block mined, including cells behind the bedrock")
check(world[key(1, -2, 1)] == "minecraft:bedrock", "the bedrock column survives")
check(logHas("quarry complete"), "task finished cleanly despite the bedrock")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 20: Plethora block scanner ore homing ----------
print("scenario: strip mode homes in on scanner-located ore (ORE_SCAN)")
resetWorld()
modemSide = "left"
gpsEnabled = true                       -- scanner offsets are world-aligned
fillGround(-2, 10, -6, 2, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
world[key(4, 0, -5)] = "minecraft:diamond_ore" -- far beyond vein-chasing sight
inv[1] = { name = "plethora:module_scanner", count = 1 }
shutdownWhen = function(msg) return msg.state == "done" end
runWB2("set", "STRIP_VEIN", "false")
runWB2("set", "ORE_SCAN", "true")
runWB2("set", "SCAN_INTERVAL", "4")
logClear()
runWB2("strip", "8")
check(world[key(4, 0, -5)] == nil, "scanner-located ore mined")
check(logHas("diamond_ore found"), "the find was announced")
check(countInvItem("plethora:module_scanner") == 1, "scanner back in the inventory")
check(equipment.right == "minecraft:diamond_pickaxe", "pickaxe re-equipped after scanning")
local tunnel20 = true
for x = 1, 8 do
  if world[key(x, 0, 0)] or world[key(x, 1, 0)] then tunnel20 = false end
end
check(tunnel20, "tunnel still completed to full length")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 21: decorative stones are junk (one toggle) ----------
print("scenario: modded marble discarded via DROP_JUNK, hauled when off")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2, "chisel:marble")
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "4")
local marbleInChest = 0
for _, s in ipairs(containers[key(-1, 0, 0)]) do
  if s.name == "chisel:marble" then marbleInChest = marbleInChest + s.count end
end
check(countInvItem("chisel:marble") == 0 and marbleInChest == 0,
  "marble discarded, not hauled (DROP_JUNK on)")

resetWorld()
fillGround(-2, 6, -1, 1, -3, 2, "chisel:marble")
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
runWB2("set", "STRIP_VEIN", "false")
runWB2("set", "DROP_JUNK", "false")
runWB2("strip", "4")
marbleInChest = 0
for _, s in ipairs(containers[key(-1, 0, 0)]) do
  if s.name == "chisel:marble" then marbleInChest = marbleInChest + s.count end
end
check(marbleInChest + countInvItem("chisel:marble") > 0,
  "marble hauled home with DROP_JUNK off")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 22: muster to a world position (GPS mode) ----------
print("scenario: muster (GPS): walk to world coords, face the given heading")
resetWorld()
modemSide = "left"
gpsEnabled = true
thead = 1  -- the turtle's own frame differs from the world frame
table.insert(rednetQueue, { proto = "wb2cmd", sender = 5,
  msg = { cmd = "muster", x = 103, y = 60, z = 205, face = 2 } })
shutdownWhen = function(msg) return msg.state == "ready" end
runWB2("listen")
check(tpos.x == 3 and tpos.y == 0 and tpos.z == 5, "turtle at the mustered world position")
check(thead == 2, "turtle faces the requested world heading")
local readySent = false
for _, s in ipairs(rednetSent) do
  if type(s.msg) == "table" and s.msg.kind == "ready" then readySent = true end
end
check(readySent, "ready reported back to the master")

-- ---------- scenario 23: muster by counting (line mode, no GPS) ----------
print("scenario: muster (line mode): sidestep right with no GPS at all")
resetWorld()
modemSide = "left"
table.insert(rednetQueue, { proto = "wb2cmd", sender = 5,
  msg = { cmd = "muster", right = 3 } })
shutdownWhen = function(msg) return msg.state == "ready" end
runWB2("listen")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 3, "turtle shifted 3 blocks to its right")
check(thead == 0, "turtle back on its original facing")
local readySent23 = false
for _, s in ipairs(rednetSent) do
  if type(s.msg) == "table" and s.msg.kind == "ready" then readySent23 = true end
end
check(readySent23, "ready reported back to the master")

-- ---------- scenario 24: modded chest variants ----------
print("scenario: a Quark spruce chest works as the home chest; armour doesn't")
resetWorld()
fillGround(-3, 4, -3, 4, -6, -1, "minecraft:iron_ore") -- loot that must be hauled
inv[1] = { name = "quark:custom_chest", count = 1 }    -- 1.12 variant chest item
inv[2] = { name = "minecraft:diamond_chestplate", count = 1 } -- decoy "chest" name
runWB2("quarry", "2", "2", "2")
check(world[key(-1, 0, 0)] == "quark:custom_chest",
  "variant chest placed behind home from inventory")
check(#containers[key(-1, 0, 0)] > 0, "loot deposited into the variant chest")
local chestplateInChest = false
for _, s in ipairs(containers[key(-1, 0, 0)]) do
  if s.name == "minecraft:diamond_chestplate" then chestplateInChest = true end
end
check(chestplateInChest, "chestplate treated as loot, not as a chest")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 25: never dig another turtle (it moves away) ----------
print("scenario: a fellow turtle in the tunnel is waited out, never dug")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
world[key(2, 1, 0)] = "computercraft:turtle_expanded" -- fleetmate in the path
-- it wanders off shortly after the digger starts waiting for it
table.insert(simEvents, {
  when = function() return logHas("another turtle is in my way") end,
  fn = function() world[key(2, 1, 0)] = nil end,
})
logClear()
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "4")
check(logHas("another turtle is in my way"), "digger waited instead of digging")
check(countInvItem("computercraft:turtle_expanded") == 0, "the other turtle was never broken")
local tunnel25 = true
for x = 1, 4 do
  if world[key(x, 0, 0)] or world[key(x, 1, 0)] then tunnel25 = false end
end
check(tunnel25, "tunnel completed once the way was clear")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 26: blocking turtle never moves -> give up cleanly ----------
print("scenario: a parked turtle that never moves is routed around, not dug")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
world[key(2, 1, 0)] = "computercraft:turtle_expanded" -- parked, forever
logClear()
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "4")
check(world[key(2, 1, 0)] == "computercraft:turtle_expanded", "parked turtle untouched")
check(countInvItem("computercraft:turtle_expanded") == 0, "nothing turtle-shaped in the loot")
check(logHas("tunnel blocked"), "task ended cleanly instead of hanging")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 27: an item that reports no name ----------
-- some 1.12 modded items return a detail table with a nil name; the
-- keep-or-drop decision at the home chest must not crash on them
-- (field crash: "wb2.lua:50: attempt to index local 'name' (a nil value)")
print("scenario: nameless modded item is unloaded as plain loot, no crash")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
inv[10] = { name = nil, count = 1 } -- getItemDetail -> { count = 1 } only
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "2")
check(inv[10] == nil or inv[10].name ~= nil, "nameless item no longer aboard")
check(logHas("strip complete"), "task finished instead of crashing at the chest")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 28: buffer chest placed into OPEN AIR ----------
-- the field crash "after it unloaded and turned once": facing the buffer
-- spot, inspect on open air returns (false, "No block to inspect") - a
-- truthy STRING second value that must never be treated as a block
print("scenario: buffer chest placed into open air after unloading")
resetWorld()
fillGround(-2, 5, -2, 2, -3, 2)
world[key(0, 0, 0)] = nil
world[key(0, 0, -1)] = nil            -- LEFT of home is open air
addChest(-1, 0, 0)
inv[1] = { name = "minecraft:crafting_table", count = 1 }
inv[2] = { name = "minecraft:coal", count = 10 }
inv[3] = { name = "minecraft:log", count = 6 }
inv[4] = { name = "minecraft:chest", count = 1 }
logClear()
runWB2("set", "CRAFT_TORCHES", "true")
runWB2("strip", "2")
check(world[key(0, 0, -1)] == "minecraft:chest", "buffer chest placed into the open spot")
check(logHas("strip complete"), "no crash after the post-unload turn")
check(countInvItem("minecraft:torch") >= 24, "crafting proceeded normally")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 29: gentle GPS orient on boot ----------
-- an idle turtle self-orients when GPS exists, stepping BACKWARD when
-- something (here: a chest) blocks the way forward - and never digging
print("scenario: idle turtle orients via GPS without digging the chest ahead")
resetWorld()
modemSide = "left"
gpsEnabled = true
addChest(1, 0, 0)                       -- furniture directly in front
shutdownWhen = function(msg) return msg.world ~= nil end
runWB2("listen")
check(world[key(1, 0, 0)] == "minecraft:chest", "chest in front was not dug")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle stepped back and returned")
local gotWorld = false
for _, s in ipairs(rednetSent) do
  if type(s.msg) == "table" and type(s.msg.world) == "table"
     and s.msg.world.x == 100 and s.msg.world.z == 200 then
    gotWorld = true
  end
end
check(gotWorld, "status now reports true world coordinates")

-- ---------- scenario 30: mob spawner in the strip tunnel ----------
-- a spawner sitting right in the tunnel line is never broken: its cell
-- is skipped and travel hops over it (up, along, back down)
print("scenario: mob spawner in the tunnel is hopped over, never broken")
resetWorld()
fillGround(-2, 8, -1, 1, -3, 3)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
world[key(3, 1, 0)] = "minecraft:mob_spawner" -- at the travel level, mid tunnel
logClear()
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "6")
check(world[key(3, 1, 0)] == "minecraft:mob_spawner", "spawner still standing")
check(countInvItem("minecraft:mob_spawner") == 0, "no spawner in the loot")
check(world[key(5, 1, 0)] == nil and world[key(5, 0, 0)] == nil, "tunnel continues past the spawner")
check(logHas("spawner"), "spawner announced in the notes")
check(logHas("strip complete"), "strip finished despite the spawner")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 31: mob spawner inside a quarry volume ----------
print("scenario: quarry leaves an embedded mob spawner untouched")
resetWorld()
fillGround(-3, 6, -3, 6, -6, -1)
addChest(-1, 0, 0)
world[key(1, -1, 1)] = "minecraft:mob_spawner" -- buried inside the volume
logClear()
runWB2("quarry", "3", "2", "3")
check(world[key(1, -1, 1)] == "minecraft:mob_spawner", "spawner still standing")
check(countInvItem("minecraft:mob_spawner") == 0, "no spawner in the loot")
check(world[key(2, -2, 1)] == nil, "cells beyond the spawner still mined")
check(world[key(0, -2, 0)] == nil, "layers below the spawner level still mined")
check(logHas("quarry complete"), "quarry ran to completion")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 32: surplus coal is unloaded, one stack kept ----------
-- coal is a keep-item (it's fuel), but dug-up coal must not accumulate
-- forever: everything beyond one stack goes into the chest on unload
print("scenario: coal beyond one stack is unloaded at the home chest")
resetWorld()
fillGround(-2, 6, -1, 1, -3, 2)
world[key(0, 0, 0)] = nil
addChest(-1, 0, 0)
inv[1] = { name = "minecraft:coal", count = 64 }
inv[2] = { name = "minecraft:coal", count = 40 }
inv[3] = { name = "minecraft:lava_bucket", count = 1 }
inv[4] = { name = "minecraft:coal_block", count = 10 } -- 9 coal each: over the cap
world[key(1, 1, 0)] = "minecraft:obsidian" -- dug en route; must be hauled, never junked
logClear()
runWB2("set", "STRIP_VEIN", "false")
runWB2("strip", "2")
check(countInvItem("minecraft:coal") == 64, "exactly one stack of coal kept aboard")
check(countInvItem("minecraft:coal_block") == 0, "coal blocks (9 coal each) over the cap all unloaded")
local coalInChest, blocksInChest, obsidianInChest = 0, 0, 0
for _, s in ipairs(containers[key(-1, 0, 0)]) do
  if s.name == "minecraft:coal" then coalInChest = coalInChest + s.count end
  if s.name == "minecraft:coal_block" then blocksInChest = blocksInChest + s.count end
  if s.name == "minecraft:obsidian" then obsidianInChest = obsidianInChest + s.count end
end
check(coalInChest == 40, "the surplus 40 coal went into the chest")
check(blocksInChest == 10, "the coal blocks went into the chest")
check(obsidianInChest == 1, "obsidian hauled home, not discarded as junk")
check(countInvItem("minecraft:lava_bucket") == 1, "lava bucket (fuel, but a bucket) stays aboard")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0, "turtle returned home")

-- ---------- scenario 33: stale calibration must never steer a muster ----------
-- the field bug: a turtle carries a saved GPS calibration from where it
-- USED to live, gets hand-placed at a new site, boots (startup runs
-- `resume`), and a GPS muster then computed its target against the old
-- anchor - marching the turtle off into unloaded chunks. The boot path
-- must reset the frame, and muster/goto must calibrate fresh + verify.
print("scenario: hand-moved turtle with stale calibration musters correctly")
resetWorld()
modemSide = "left"
gpsEnabled = true
files["/wb2data/state"] = textutils.serialize({
  pos = { x = 0, y = 0, z = 0 },
  heading = 0,
  task = nil, -- previous job finished; nothing to resume
  -- anchor from its old home, ~1100 blocks from where it now stands
  calib = { offset = 2, worldAt = { x = 600, y = 60, z = -400 },
            relAt = { x = 0, y = 0, z = 0 } },
  haul = { total = 0, ores = {} },
})
table.insert(rednetQueue, { proto = "wb2cmd", sender = 5,
  msg = { cmd = "muster", x = 102, y = 60, z = 201, face = 0 } })
shutdownWhen = function(msg) return msg.state == "ready" end
runWB2("resume") -- what startup actually runs on every boot
check(tpos.x == 2 and tpos.y == 0 and tpos.z == 1,
  "turtle at the true world target, not where the stale anchor pointed")
check(thead == 0, "turtle faces the requested world heading")
local readySent33 = false
for _, s in ipairs(rednetSent) do
  if type(s.msg) == "table" and s.msg.kind == "ready" then readySent33 = true end
end
check(readySent33, "ready reported back to the master")

-- ---------- scenario 34: a lying calibration must not teleport a resume ----------
-- the field bug: a mid-quarry turtle reboots (chunk unload) carrying a
-- stale anchor; the boot drift-fix computed pos through it, teleporting
-- the turtle's BELIEF ~700 blocks - it then bored a tunnel toward a
-- phantom cell until its fuel died. A big GPS-vs-anchor disagreement
-- must drop the anchor and keep dead reckoning instead.
print("scenario: resume with a lying calibration keeps dead reckoning")
resetWorld()
modemSide = "left"
gpsEnabled = true
fillGround(-3, 5, -3, 5, -6, -1)
addChest(-1, 0, 0)
world[key(1, 0, 0)] = nil -- the turtle stands mid-quarry, cell already dug
tpos = { x = 1, y = 0, z = 0 }
files["/wb2data/state"] = textutils.serialize({
  pos = { x = 1, y = 0, z = 0 }, -- dead reckoning is CORRECT
  heading = 0,
  task = { kind = "quarry", l = 2, w = 2, depth = 2, layer = 0, cell = 0,
           paused = false },
  calib = { offset = 1, worldAt = { x = 700, y = 60, z = 300 }, -- old life, ~700 blocks off
            relAt = { x = 0, y = 0, z = 0 } },
  haul = { total = 0, ores = {} },
})
logClear()
shutdownWhen = function(msg) return msg.state == "done" end
runWB2("resume")
check(logHas("disagrees with reality"), "lying calibration detected and dropped")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0,
  "turtle finished at its REAL home, not a phantom one")
local q34 = true
for x = 0, 1 do for z = 0, 1 do for y = 0, -1, -1 do
  if world[key(x, y, z)] then q34 = false end
end end end
check(q34, "the quarry it was resuming got finished in place")

-- ---------- scenario 35: honest 1-block drift is still corrected ----------
-- the drift-fix exists for real mid-move server stops; a small
-- disagreement (anchor healthy, one move lost) must still be applied
print("scenario: resume corrects genuine 1-block drift via GPS")
resetWorld()
modemSide = "left"
gpsEnabled = true
fillGround(-3, 5, -3, 5, -6, -1)
addChest(-1, 0, 0)
world[key(1, 0, 0)] = nil
world[key(2, 0, 0)] = nil
tpos = { x = 2, y = 0, z = 0 } -- physically one block FURTHER than believed
files["/wb2data/state"] = textutils.serialize({
  pos = { x = 1, y = 0, z = 0 }, -- the move lost to the server stop
  heading = 0,
  task = { kind = "quarry", l = 2, w = 2, depth = 2, layer = 0, cell = 0,
           paused = false },
  calib = { offset = 0, worldAt = { x = 100, y = 60, z = 200 }, -- healthy anchor
            relAt = { x = 0, y = 0, z = 0 } },
  haul = { total = 0, ores = {} },
})
shutdownWhen = function(msg) return msg.state == "done" end
runWB2("resume")
check(tpos.x == 0 and tpos.y == 0 and tpos.z == 0,
  "turtle home exactly, off-by-one corrected before resuming")

-- ---------- summary ----------
print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
