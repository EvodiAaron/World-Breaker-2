--  ### World Breaker Architecture
--      - World Breaker Master Computer
--        A computer that manages the World Breaker pool via commands.

--      - World Breaker Remote
--        A remote computer that relays commands to the World Breaker pool via the Master Computer.

--      - World Breaker Turtle
--        Mining turtles that receive commands from the master computer. They can be individually instructed in order to orchestrate coordinated actions.

--      - World Breaker Despatch Turtle
--        A multi-tooled turtle that receive commands from the master computer. This turtle swaps its off-hand tool (not its modem) between crafting bench and pickaxe.
--        It uses the crafting bench to create World Breaker Turtles, whereas it uses the pickaxe for travel. The primary purposes of this turtle are to create new turtles, initialise them, and despatch them to designated locations (saving fuel by using only one turtle to travel).

--  ### Transmission ###
--      ## Messages ##
--          - The World Breaker network leverages rednet. Where the master computer registers its hostname as "MasterComputer" on the "WorldBreaker" protocol.
--          - Similarly, the remote has a registered hostname "Remote" on the "WorldBreaker" protocol, allowing the master computer to identify its instructions.
--          - Turtles enrol themselves with the master computer so it knows who to transmit to and receive from.

--  ### Turtle Enrollment & Unenrollment ###
--      - In order for the master computer to manage a pool of turtles, it must know what turtles are available to coordinate.
--        As such, turtles must be enrolled and unenrolled with the master computer.

--      - To enrol, a turtle must transmit "ENROL" to the master computer.
--      - Upon receiving an "ENROL" message, the master computer will store the ID of the message's source in a pool table.

--      - To unenrol, a turtle must transmit "UNENROL" to the master computer.
--      - Upon receiving an "UNENROL" message, the master computer will remove the ID of the message's source from its pool table.
--      - Upon a program termination event, turtles will automatically inform the master computer that it wishes to unenrol.
--      - Periodically, the master computer check how long it has been since each turtle had contact with it. If it exceeds a certain period of time, it will be unenrolled.

--      - Periodically, the master computer will request metadata from enrolled turtles like current location, fuel level, etc.


-- ############### PROGRAM INITIALISATION ###############

-- runtime variables
shutdown = false
printCommunications = false
manualConsoleEnabled = false
pool = {}   -- pool of enrolled turtles

-- settings
REDNET_SIDE = "back"
OVERWRITE_ENROLLMENTS = true    -- overwrite existing enrollments when enrolling or deny the new enrollment

-- APIs
os.loadAPI("/menu.lua")

-- rednet
rednet.open(REDNET_SIDE)
rednet.host("WorldBreaker", "MasterComputer")

-- commands
REQUEST_LOCATION_COMMAND =  "GET LOCATION"
REQUEST_FUEL_COMMAND =      "GET FUEL"

function main()
    
    generateMenus()
    menu.load("main")
    menu.draw()

    requestReenrollment()
end

-- generate all required menus
function generateMenus()

    menu.create("main")
    menu.load("main")
    menu.setHeaderText("World Breaker Master Computer")
    menu.enableHeader()
    menu.enableMenuItems()
    menu.upsertMenuItem("Pool Management")
    menu.upsertMenuItem("Manual Command Mode")
    menu.upsertMenuItem("View Communications")
    
    menu.create("pool-management")
    menu.load("pool-management")
    menu.setHeaderText("Pool Management")
    menu.setFooterText("Back")
    menu.setFooterLineCharacter("")
    menu.enableHeader()
    menu.enableFooter()
    menu.enableMenuItems()
    menu.upsertMenuItem("Enrollments")
    menu.upsertMenuItem("Status")
    menu.upsertMenuItem("Locations")

    menu.create("pool-enrollments")
    menu.load("pool-enrollments")
    menu.setHeaderText("Pool Enrollments (click to refresh)")
    menu.setFooterText("Back")
    menu.setFooterLineCharacter("")
    menu.enableHeader()
    menu.enableFooter()

end


-- ############### ENROLLMENT MANAGEMENT ###############

-- adds a turtle to the enrolled pool, returning false if already enrolled and OVERWRITE_ENROLLMENTS = false
function enrol(turtleID)
    -- check for existing enrollment
    for index, enrollment in pairs(pool) do
        if enrollment.id == turtleID then
            if(OVERWRITE_ENROLLMENTS) then
                table.remove(pool, index)
            else
                return false
            end
        end
    end
    
    table.insert(pool, {
        id = turtleID,
        location = {
            x = nil,
            y = nil,
            z = nil
        },
        fuel = nil,
        lastOperation = "",
        lastContact = os.time()
    })
    return true
end

-- removes a turtle from enrollment, returning false 
function unenrol(turtleID)
    for index, enrollment in pairs(pool) do
        if enrollment.id == turtleID then
            table.remove(pool, index)
            return true
        end
    end
    return false
end

-- queries if a computer ID is present in the enrolled turtle pool
function isEnrolled(ID)
    for index, enrollment in pairs(pool) do
        if enrollment.id == ID then
            return true
        end
    end
    return false
end


-- ############### POOL METADATA UPDATES ###############

function setTurtleLocation(turtleID, xCoordinate, yCoordinate, zCoordinate)
    for index, enrollment in pairs(pool) do
        if enrollment.id == turtleID then
            pool[index].location = {x = xCoordinate, y = yCoordinate, z = zCoordinate}
        end
    end
    return false
end

function setTurtleFuelLevel(turtleID, fuelLevel)
    for index, enrollment in pairs(pool) do
        if enrollment.id == turtleID then
            pool[index].fuel = fuelLevel
        end
    end
    return false
end

function setTurtleLastOperation(turtleID, lastOperation)
    for index, enrollment in pairs(pool) do
        if enrollment.id == turtleID then
            pool[index].lastOperation = lastOperation
        end
    end
    return false
end

function setTurtleLastContact(turtleID, lastContact)
    for index, enrollment in pairs(pool) do
        if enrollment.id == turtleID then
            pool[index].lastContact = lastContact
        end
    end
    return false
end


-- ############### TRANSMISSION ###############

-- message received via rednet
function messageReceived(sender, message, protocol)
    if(protocol == "dns") then
        return
    end

    if(printCommunications) then
        print("RECEIVED: " .. message)
    end

    local tokens = split(message, " ")
        
    -- determine if the message source is enrolled
    local isEnrolledSender = isEnrolled(sender)

    if(message == "ENROL") then
        if(enrol(sender)) then
            transmitToTurtle(sender, "APPROVED")
        else
            transmitToTurtle(sender, "DENIED")
        end
    end

    if(isEnrolledSender) then
        setTurtleLastContact(sender, os.time())

        if(tokens[1] == "LOCATION") then
            if(tokens[2] ~= nil and tokens[3] ~= nil and tokens[4] ~= nil) then
                setTurtleLocation(sender, tokens[2], tokens[3], tokens[4])
            end

        elseif(tokens[1] == "FUEL") then
            if(tokens[2] ~= nil) then
                setTurtleFuelLevel(sender, tokens[2])
            end
        
        elseif(tokens[1] == "OPERATION") then
            if(tokens[2] ~= nil) then
                setTurtleLastOperation(sender, tokens[2])
            else
                setTurtleLastOperation(sender, "")
            end
        end
    end
end

-- broadcast a reenrollment request
function requestReenrollment()
    rednet.broadcast("REENROL")
end

-- transmit message to a turtle
function transmitToTurtle(turtleID, message)
    os.sleep(0.1)
    
    if(turtleID == "*") then
        for index, enrollment in pairs(pool) do
            if(printCommunications) then
                print("TRANSMITTED TO " .. enrollment.id .. ": " .. message)
            end
            rednet.send(enrollment.id, message:upper())
        end
    else
        if(tonumber(turtleID) ~= nil) then
            rednet.send(math.floor(tonumber(turtleID)), message:upper())
        end
    end
end

-- transmit a message to the remote
function transmitToRemote(message)
    local remoteID = rednet.lookup("WorldBreaker", "Remote")
    if(not remoteID) then
        print("Could not find remote")
        return false
    end

    rednet.send(remoteID, message:upper())

    if(printCommunications) then
        print("TRANSMITTED TO REMOTE: " .. message)
    end

    return true
end

-- every second, request metadata from the turtle pool
function requestUpdatedPoolMetaData()
    while not shutdown do

        -- check for dead enrollments (no contact in over 9 seconds)
        for index, enrollment in pairs(pool) do
            if(os.time() * 50 - enrollment.lastContact * 50 >= 9) then
                unenrol(enrollment.id)
            end
        end

        os.sleep(3)
        
        transmitToTurtle("*", REQUEST_FUEL_COMMAND)
        transmitToTurtle("*", REQUEST_LOCATION_COMMAND)
    end
end


-- ############### GENERAL FUNCTIONALITY ###############

-- manual console that user can type in to execute commands
function manualConsole()

    while not shutdown do   -- constantly check if manual console is enabled, if so, show it
        if(manualConsoleEnabled) then

            menu.unload()
            term.setCursorPos(1, 1)
            print("Manual Console Enabled")
            print("'quit' or 'exit' to return")
            print("")

            -- receive commands from the user
            local command = ""
            while command ~= "QUIT" and command ~= "EXIT" and command ~= "SHUTDOWN" do
                write("> ")
                command = read():upper()

                if(command == "HELP") then
                    print("")
                    print("Commands available:")
                    textutils.slowPrint(" - General: stop, return, locate", 60)
                    textutils.slowPrint(" - Digging: tunnel, dig [direction]", 60)
                    textutils.slowPrint(" - Movement: forward [blocks], backward [blocks], up [blocks], down [blocks], left, right, rotate", 60)
                    textutils.slowPrint(" - Resources: refuel  [items], get fuel", 60)
                    textutils.slowPrint(" - Settings: get [setting], enable [setting], disable [setting], set [setting] [parameter], add [setting] [parameter], remove [setting] [parameter]", 60)
                    textutils.slowPrint(" - Configuration: reset, initialise")
                    print("")
                elseif(command == "SETTINGS") then
                    print("")
                    print("Settings available to change:", 60)
                    textutils.slowPrint("PLACE_TORCHES, PLACE_CHESTS, USE_ENDER_CHESTS, BLOCK_ALERTS, REPORT_STATISTICS, AUTO_RETURN, AUTO_REFUEL, TORCH_INTERVAL, BLOCK_ALERT_WHITELIST, UNLOAD_BLACKLIST, BLOCK_CHASE_WHITELIST", 60)
                    print("")
                elseif(command == "LIST ENROLLMENTS") then
                    printEnrollments()
                elseif(command == "REENROL") then
                    requestReenrollment()
                elseif(command == "SHUTDOWN") then
                    shutdown = true
                elseif(command ~= "QUIT" and command ~= "EXIT") then
                    local tokens = split(command, " ")

                    local target = tokens[1]
                    table.remove(tokens, 1)

                    local toTransmit = tableToString(tokens, " ")

                    transmitToTurtle(target, toTransmit)     
                end
            end
            manualConsoleEnabled = false
            menu.load("main")
            menu.draw()
        else
            os.sleep(0)        
        end
    end
end

function printEnrollments()
    for index, enrollment in pairs(pool) do
        print(enrollment.id)
        print(enrollment.fuel)
        print(enrollment.location.x)
        print(enrollment.location.y)
        print(enrollment.location.z)
        print("")
    end
end

-- display enrollments in the menu area
function displayEnrollments()
    local enrollmentList = ""
    for index, enrollment in pairs(pool) do
        if(index == 1) then
            enrollmentList = tostring(enrollment.id)
        else
            enrollmentList = enrollmentList .. ", " .. tostring(enrollment.id)
        end
    end

    local bounds = menu.getMenuBounds()
    term.setCursorPos(bounds.xStart, bounds.yStart)
    print(enrollmentList)
end

-- display enrollments in the menu area
function displayEnrollmentStatus()
    local bounds = menu.getMenuBounds()
    term.setCursorPos(bounds.xStart, bounds.yStart)

    for index, enrollment in pairs(pool) do
        print(enrollment.id)
        local lastOperation = enrollment.lastOperation
        if(lastOperation == "") then
            lastOperation = "<none>"
        end
        print(" Current Operation: " .. lastOperation)
        if(enrollment.fuel ~= nil) then
            print(" Fuel Level: " .. enrollment.fuel)
        end
        if(enrollment.location ~= nil and enrollment.location.x ~= nil and enrollment.location.y ~= nil and enrollment.location.z ~= nil) then
            print(" Location: (" .. enrollment.location.x .. ", " .. enrollment.location.y .. ", " .. enrollment.location.z .. ")")
        end
        print("")
    end    
end


-- ############### INPUT ###############

-- a key has been pressed
function keyPressed(id, key)
    if(printCommunications) then
        printCommunications = false
        menu.load("main")
        menu.draw()
        return
    end

    -- check if the keyboard selection option is hidden, if it is, first get it shown
    if(menu.isKeyboardSelectionHidden()) then
        menu.showKeyboardSelection()
    else
        if(id == 200 or id == 17) then     -- UP or W
            menu.decrementSelectedMenuItem()
        elseif(id == 208 or id == 30 or id == 31) then -- DOWN or S or TAB
            menu.incrementSelectedMenuItem()
        elseif(id == 28) then  -- ENTER
            menuItemSelected(menu.getSelectedMenuItem())
        end
    end
end

-- user has mouse clicked or touched a monitor
function graphicalInteraction(side, xPos, yPos)
    if(printCommunications) then
        printCommunications = false
        menu.load("main")
        menu.draw()
        return
    end

    menu.hideKeyboardSelection()

    local menuData = menu.getData()
    if(menuData ~= nil) then

        -- look for hitbox collision
        if(menuData.options.headerEnabled) then
            if(menuData.header.hitbox.xStart <= xPos and menuData.header.hitbox.xEnd >= xPos and menuData.header.hitbox.yStart <= yPos and menuData.header.hitbox.yEnd >= yPos) then
                -- user has selected header
                headerSelected()
            end
        end

        if(menuData.options.footerEnabled) then
            if(menuData.footer.hitbox.xStart <= xPos and menuData.footer.hitbox.xEnd >= xPos and menuData.footer.hitbox.yStart <= yPos and menuData.footer.hitbox.yEnd >= yPos) then
                -- user has selected footer
                footerSelected()
            end
        end

        if(menuData.options.menuItemsEnabled) then
            for item, options in pairs(menuData.items) do
                if(options.hitbox.xStart <= xPos and options.hitbox.xEnd >= xPos and options.hitbox.yStart <= yPos and options.hitbox.yEnd >= yPos) then
                    -- user has selected menu item: item
                    menuItemSelected(item)
                end
            end
        end

        if(menuData.options.customPointsEnabled) then
            for customPoint, options in pairs(menuData.customPoints) do
                if(options.hitbox.xStart <= xPos and options.hitbox.xEnd >= xPos and options.hitbox.yStart <= yPos and options.hitbox.yEnd >= yPos) then
                    -- user has selected menu item: item
                    customPointSelected(customPoint)
                end
            end
        end
    end

    if(menu.getLoaded() == "pool-enrollments") then
        menu.draw()
        displayEnrollmentStatus()
    end
end

-- a monitor has been resized
function monitorResized(side)
    menu.updateWindowSize()    -- update the window size model in the UI API
end

function menuItemSelected(menuItem)

    if(menu.getLoaded() == "main") then
        if(menuItem == "Manual Command Mode") then
            manualConsoleEnabled = true
    
            menu.load("main")
            menu.draw()
        elseif(menuItem == "Pool Management") then
            menu.load("pool-management")
            menu.draw()
        elseif(menuItem == "View Communications") then
            menu.unload()
            term.setCursorPos(1, 1)
            print("Communication log")
            print("Do anything to return to the menu")
            print("")
            printCommunications = true
        end
    elseif(menu.getLoaded() == "pool-management") then
        if(menuItem == "Enrollments") then   
            menu.load("pool-enrollments")
            menu.draw()

            displayEnrollments()
        elseif(menuItem == "Status") then   
            menu.load("pool-enrollments")
            menu.draw()

            displayEnrollmentStatus()
        end
    end
end

function customPointSelected(customPoint)
    -- nothing here yet
end

function headerSelected()
    -- nothing here yet
end

function footerSelected()
    if(menu.getLoaded() == "pool-management") then
        menu.load("main")
        menu.draw()
    elseif(menu.getLoaded() == "pool-enrollments") then
        menu.load("pool-management")
        menu.draw()
    end
end


-- ############### GENERIC FUNCTIONS ###############

-- split string via delimiter into a table
function split(s, delimiter)
    result = {}
    for match in (s..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, match)
    end
    return result
end

-- get string of delimiter-separated values from table
function tableToString(tbl, delimiter)
    local s = ""
    local entries = 0

    -- concatenate comma-separated values
    for index, value in ipairs(tbl) do
        s = s .. value .. delimiter
        entries = entries + 1
    end
    
    -- remove comma if at least one entry was found
    if(entries > 0) then
        s = s:sub(1, -(string.len(delimiter) + 1))
    end
    
    return s
end


-- ############### EVENT HANDLING ###############

-- outline what events and handlers should be mapped
function eventListener()
    listenForEvent({rednet_message=messageReceived, key=keyPressed, monitor_touch=graphicalInteraction, mouse_click=graphicalInteraction, monitor_resize=monitorResized})
end 

-- listen constantly for events and redirect them appropriately to the event handler
function listenForEvent(functionTbl)
    while not shutdown do
        tbl = {os.pullEvent()}
        if type(functionTbl[tbl[1]]) == "function" then
            functionTbl[tbl[1]](select(2, unpack(tbl)))
        end
    end
end

-- run main function and event handling code simultaneously
parallel.waitForAll(main, eventListener, requestUpdatedPoolMetaData, manualConsole)