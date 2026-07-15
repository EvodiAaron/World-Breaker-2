os.setComputerLabel("World Breaker " .. os.getComputerID())

local f = fs.open("/WorldBreaker.lua", "w")
local content = http.get("http://helios/repositories/WorldBreaker/WorldBreaker.lua").readAll()
f.write(content)
f.close()

f = fs.open("/startup.lua", "w")
content = http.get("http://helios/repositories/WorldBreaker/startup.lua").readAll()
f.write(content)
f.close()

f = fs.open("/Initialise.lua", "w")
content = http.get("http://helios/repositories/WorldBreaker/Initialise.lua").readAll()
f.write(content)
f.close()