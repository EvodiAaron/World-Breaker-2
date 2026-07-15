os.setComputerLabel("World Breaker Master Computer")

local f = fs.open("/WorldBreakerMasterComputer.lua", "w")
local content = http.get("http://helios/repositories/WorldBreakerMasterComputer/WorldBreakerMasterComputer.lua").readAll()
f.write(content)
f.close()

f = fs.open("/startup.lua", "w")
content = http.get("http://helios/repositories/WorldBreakerMasterComputer/startup.lua").readAll()
f.write(content)
f.close()

f = fs.open("/Initialise.lua", "w")
content = http.get("http://helios/repositories/WorldBreakerMasterComputer/Initialise.lua").readAll()
f.write(content)
f.close()

f = fs.open("/menu.lua", "w")
content = http.get("http://helios/repositories/WorldBreakerMasterComputer/menu.lua").readAll()
f.write(content)
f.close()

os.reboot()