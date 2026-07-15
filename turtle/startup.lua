-- World Breaker 2 turtle startup
-- Resumes an interrupted task after a reboot / chunk reload,
-- otherwise idles awaiting master commands (if a modem is attached).
-- Press any key within 3 seconds to get a normal shell instead.

print("World Breaker 2 starting in 3s - press any key for shell")
local timer = os.startTimer(3)
while true do
  local ev, arg = os.pullEvent()
  if ev == "key" then
    print("Startup aborted. Run 'wb2' to mine.")
    return
  elseif ev == "timer" and arg == timer then
    break
  end
end

if fs.exists("/wb2data/state") then
  shell.run("wb2", "resume")
else
  shell.run("wb2", "listen")
end
