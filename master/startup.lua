-- World Breaker 2 master startup
-- Press any key within 3 seconds to get a normal shell instead.

print("World Breaker 2 master starting in 3s - press any key for shell")
local timer = os.startTimer(3)
while true do
  local ev, arg = os.pullEvent()
  if ev == "key" then
    print("Startup aborted. Run 'wb2master' for the console.")
    return
  elseif ev == "timer" and arg == timer then
    break
  end
end

shell.run("wb2master")
