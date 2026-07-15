-- World Breaker 2 installer
-- Run in-game:  install turtle   (on a mining turtle)
--               install master   (on the master computer)
--
-- Downloads straight from GitHub over the in-game http API.
-- After pushing this repo to GitHub, update BASE below to match
-- your username/repo/branch.

local BASE = "https://github.com/EvodiAaron/World-Breaker-2/World-Breaker-2/tree/main"

local SETS = {
  turtle = {
    ["turtle/wb2.lua"]     = "wb2.lua",
    ["turtle/startup.lua"] = "startup.lua",
  },
  master = {
    ["master/wb2master.lua"] = "wb2master.lua",
    ["master/startup.lua"]   = "startup.lua",
    ["turtle/wb2.lua"]       = "wb2.lua", -- kept locally so [v] can push updates to turtles
  },
}

local which = ({ ... })[1]
if not which or not SETS[which] then
  print("Usage: install <turtle|master>")
  return
end
if not http then
  print("The http API is disabled on this server.")
  print("Ask an admin, or copy the files via pastebin/disk drive instead.")
  return
end

for remote, localName in pairs(SETS[which]) do
  write("Downloading " .. remote .. " ... ")
  local response = http.get(BASE .. "/" .. remote)
  if not response then
    print("FAILED")
    print("Check BASE at the top of install.lua points at your repo.")
    return
  end
  local content = response.readAll()
  response.close()
  local f = fs.open("/" .. localName, "w")
  f.write(content)
  f.close()
  print("ok")
end

print("")
print("Installed. Reboot, or run:")
if which == "turtle" then
  print("  wb2          - setup wizard")
  print("  wb2 quarry 16 16")
else
  print("  wb2master")
end
