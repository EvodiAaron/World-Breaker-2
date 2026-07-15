MODEM_FREQUENCY = 70    -- modem frequency to listen to
TURTLE_FREQUENCY = 69   -- modem frequency to transmit to

modem = peripheral.find("modem")
modem.open(MODEM_FREQUENCY)

command = ""

function main()
    term.clear()
    print("World Breaker Remote")

    while command ~= "QUIT" and command ~= "EXIT" do
        command = read():upper()

        if(command == "HELP") then
            print("")
            print("Commands available:", 60)
            textutils.slowPrint(" - General: stop, return, locate", 60)
            textutils.slowPrint(" - Digging: tunnel, dig [direction]", 60)
            textutils.slowPrint(" - Movement: forward [blocks], backward [blocks], up [blocks], down [blocks], left, right, rotate", 60)
            textutils.slowPrint(" - Resources: refuel  [items], get fuel", 60)
            textutils.slowPrint(" - Settings: get [setting], enable [setting], disable [setting], set [setting] [parameter], add [setting] [parameter], remove [setting] [parameter]", 60)
            textutils.slowPrint(" - Configuration: reset, initialise")
            print("")
        if(command == "SETTINGS") then
            print("")
            print("Settings available to change:", 60)
            textutils.slowPrint("PLACE_TORCHES, PLACE_CHESTS, USE_ENDER_CHESTS, BLOCK_ALERTS, REPORT_STATISTICS, AUTO_RETURN, AUTO_REFUEL, TORCH_INTERVAL, BLOCK_ALERT_WHITELIST, UNLOAD_BLACKLIST, BLOCK_CHASE_WHITELIST", 60)
            print("")
        else
            modem.transmit(TURTLE_FREQUENCY, MODEM_FREQUENCY, command)

            if(command == "INITIALISE") then
                dofile("/Initialise.lua")
            end
        end
    end
end

function monitorModem()
    while command ~= "QUIT" and command ~= "EXIT" do
       event, side, frequency, replyFrequency, message, distance = os.pullEvent("modem_message")
       print(message)
    end
end

parallel.waitForAll(main, monitorModem)