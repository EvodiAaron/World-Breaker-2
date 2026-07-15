os.setComputerLabel("World Breaker " .. os.getComputerID())

local f = fs.open("/WorldBreakerTurtle.lua", "w")
local content = http.get("http://helios/repositories/WorldBreakerTurtle/WorldBreakerTurtle.lua").readAll()
f.write(content)
f.close()

f = fs.open("/startup.lua", "w")
content = http.get("http://helios/repositories/WorldBreakerTurtle/startup.lua").readAll()
f.write(content)
f.close()

f = fs.open("/Initialise.lua", "w")
content = http.get("http://helios/repositories/WorldBreakerTurtle/Initialise.lua").readAll()
f.write(content)
f.close()

os.reboot()