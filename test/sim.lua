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
  return false, nil
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
  if name == "minecraft:chest" then containers[key(x, y, z)] = {} end
  return true
end
function turtle.place() return placeAt(ahead()) end
function turtle.placeDown() return placeAt(tpos.x, tpos.y - 1, tpos.z) end
function turtle.placeUp() return placeAt(tpos.x, tpos.y + 1, tpos.z) end

local function dropInto(x, y, z)
  local s = inv[selected]
  if not s then return false end
  local c = containers[key(x, y, z)]
  if c then table.insert(c, { name = s.name, count = s.count }) end
  -- no container = dropped into the void
  inv[selected] = nil
  return true
end
function turtle.drop() return dropInto(ahead()) end
function turtle.dropDown() return dropInto(tpos.x, tpos.y - 1, tpos.z) end
function turtle.dropUp() return dropInto(tpos.x, tpos.y + 1, tpos.z) end

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

peripheral = { getType = function() return nil end }
rednet = {}
gps = { locate = function() return nil end }

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
          local ok, err = coroutine.resume(co)
          if not ok then error(err, 0) end
          if coroutine.status(co) == "dead" then return end
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
print("scenario: quarry 3x2, depth 3")
resetWorld()
fillGround(-3, 6, -3, 6, -6, -1)          -- ground everywhere below y=0
world[key(-1, 0, 0)] = "minecraft:chest"  -- home chest behind the turtle
runWB2("quarry", "3", "2", "3")

local allMined = true
for x = 0, 2 do
  for z = 0, 1 do
    for y = -1, -3, -1 do
      if world[key(x, y, z)] then allMined = false end
    end
  end
end
check(allMined, "all 18 quarry blocks removed")
check(world[key(3, -1, 0)] ~= nil, "no digging beyond quarry length")
check(world[key(0, -1, -1)] ~= nil, "no digging beyond quarry width")
check(world[key(0, -4, 0)] ~= nil, "no digging below requested depth")
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
-- pretend cells 0 and 1 of a 2x2 quarry were already mined before the "crash"
world[key(0, -1, 0)] = nil world[key(0, -2, 0)] = nil world[key(0, -3, 0)] = nil
world[key(1, -1, 0)] = nil world[key(1, -2, 0)] = nil world[key(1, -3, 0)] = nil
tpos = { x = 1, y = -2, z = 0 }
thead = 0
files["/wb2data/state"] = textutils.serialize({
  pos = { x = 1, y = -2, z = 0 },
  heading = 0,
  task = { kind = "quarry", l = 2, w = 2, depth = 3, layer = 0, cell = 2 },
})
runWB2("resume")
local resumed = true
for x = 0, 1 do
  for z = 0, 1 do
    for y = -1, -3, -1 do
      if world[key(x, y, z)] then resumed = false end
    end
  end
end
check(resumed, "remaining quarry cells mined after resume")
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
local savedState = textutils.unserialize(files["/wb2data/state"])
check(savedState and savedState.haul and savedState.haul.total == 12,
  "haul statistics: 12 blocks dug")
check(savedState and savedState.haul.ores["minecraft:iron_ore"] == 12,
  "haul statistics: all 12 counted as iron ore")

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

-- ---------- summary ----------
print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
