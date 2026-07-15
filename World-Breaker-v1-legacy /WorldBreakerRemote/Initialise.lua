os.setComputerLabel("World Breaker Remote")

local f = fs.open("/WorldBreakerRemote.lua", "w")
local content = http.get("http://helios/repositories/WorldBreakerRemote/WorldBreakerRemote.lua").readAll()
f.write(content)
f.close()

f = fs.open("/startup.lua", "w")
content = http.get("http://helios/repositories/WorldBreakerRemote/startup.lua").readAll()
f.write(content)
f.close()

f = fs.open("/Initialise.lua", "w")
content = http.get("http://helios/repositories/WorldBreakerRemote/Initialise.lua").readAll()
f.write(content)
f.close()