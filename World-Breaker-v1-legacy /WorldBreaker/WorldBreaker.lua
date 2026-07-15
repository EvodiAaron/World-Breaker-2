modem = peripheral.find("modem")

function loadDefaults()
    MODEM_FREQUENCY = 69            -- modem frequency to listen to
    REMOTE_FREQUENCY = 70           -- modem frequency to transmit to

    MAX_ITEM_SLOTS = 16             -- number of item slots available
    TORCH_INTERVAL = 13             -- number of blocks between torches
    MAX_TUNNEL_DISTANCE = 80        -- maximum number of blocks before a tunnel is stopped or snaked
    SNAKE_TUNNEL_SEPARATION = 4     -- number of blocks between snaked-tunnel passages
    SNAKE_TUNNELS = true            -- whether or not to "snake" a tunnel when reaching max distance
    PLACE_TORCHES = true            -- place torches occasionally
    PLACE_CHESTS = true             -- place chests and unload inventory when full
    USE_ENDER_CHESTS = true         -- place, unload to, then break ender chests rather than placing and filling occasional regular chests
    BLOCK_ALERTS = true             -- send alerts about a set of blocks when detected
    REPORT_STATISTICS = true        -- report occasional statistics when digging
    AUTO_RETURN = true              -- automatically return from tunneling when running out of fuel
    AUTO_REFUEL = true              -- automatically consume coal found in a dig when low on fuel
    BLOCK_CHASE = true              -- "chase" certain blocks by ensuring to mine all nearby instances of it when found
    BLOCK_ALERT_WHITELIST = {"minecraft:diamond_ore", "IC2:itemOreIridium"} -- item IDs that will result in alerts when encountered
    UNLOAD_BLACKLIST = {"minecraft:torch", "minecraft:chest", "enderstorage:ender_storage"}   -- item IDs that will not be unloaded to chests
    BLOCK_CHASE_WHITELIST = {"minecraft:diamond_ore", "minecraft:iron_ore", "minecraft:coal_ore", "minecraft:redstone_ore"}  -- item IDs that the turtle should "chase"

    -- global variables that dictate operations
    operationRestoredFromMemory = false
    currentOperation = ""
    currentOperationParameters = {}

    snakesMade = 0  -- number of times a tunnel has been snaked, used by return operation to get back to beginning of tunnel
    blocksTunneled = 0
end

-- manage each operation in the main thread
function main()
    term.clear()
    loadDefaults()
    initialise()
    output("World Breaker online")

    -- if program is not being told to shutdown
    while currentOperation ~= "SHUTDOWN" do
        
        if(currentOperation == "TUNNEL") then
            moveToDigPosition()                        
        elseif(currentOperation == "STOP") then
            stopOperation()
        elseif(currentOperation == "RETURN") then
            returnOperation()
        elseif(currentOperation == "UP") then
            move("up")
        elseif(currentOperation == "DOWN") then
            move("down")
		elseif(currentOperation == "FORWARD") then
            move("forward")
		elseif(currentOperation == "BACK" or currentOperation == "BACKWARD") then
            move("backward")
        elseif(currentOperation == "ROTATE") then
            turtle.turnRight()
            turtle.turnRight()
            output("Rotated 180 degrees")
            setOperation("")
        elseif(currentOperation == "LEFT") then
            turtle.turnLeft()
            output("Rotated left")
            setOperation("")
        elseif(currentOperation == "RIGHT") then
            turtle.turnRight()
            output("Rotated right")
            setOperation("")
        elseif(currentOperation == "DIG") then
            dig()
            setOperation("")
        else    -- keeps loop active after extended amount of time
            os.queueEvent("fakeEvent")
            os.pullEvent()
        end
    end
end

-- dig a 1x2 tunnel straight with torches until out of fuel or out of inventory
function tunnelOperation()   
    
    output("Now tunneling")
       
    blocksTunneled = 0
    snakesMade = 0
    if(operationRestoredFromMemory) then    -- attempt to restore all runtime state values if this operation was restored from memory
        if(fs.exists("/WorldBreakerState/operation/numbers")) then
            local memoryFile = fs.open("/WorldBreakerState/operation/numbers", "r")
            blocksTunneled = tonumber(memoryFile.readLine())
            snakesMade = tonumber(memoryFile.readLine())
            memoryFile.close()
        end
    end
    
    while currentOperation == "TUNNEL" and turtle.getFuelLevel() > 0 do
                     
        -- check in front if alert should occur
        if(BLOCK_ALERTS) then
            local blockFound, blockMetaData = turtle.inspect()
            if(blockFound) then
                if(tableHasValue(BLOCK_ALERT_WHITELIST, blockMetaData.name)) then
                    output(blockMetaData.name .. " encountered")
                end
                
                -- keep digging (looped as falling entities may be present)
                while turtle.dig() do
                end
            end
        end

        turtle.forward()
        
        -- check below if alert should occur
        if(BLOCK_ALERTS) then
            blockFound, blockMetaData = turtle.inspectDown()
            if(blockFound) then
                if(tableHasValue(BLOCK_ALERT_WHITELIST, blockMetaData.name)) then
                    output(blockMetaData.name .. " encountered")
                end
                
                turtle.digDown()
            end
        end

        -- if fuel falls below blocksTunneled + 25, try refuel or return
        if(turtle.getFuelLevel() < blocksTunneled + 25) then
            -- if AUTO_REFUEL enabled, check if there is any coal on-hand, if so refuel 32 coal
            if(AUTO_REFUEL) then
                local coalSlot = getItemSlotWithItem("minecraft:coal")
                if(coalSlot ~= -1) then
                    turtle.select(coalSlot)
                    turtle.refuel()

                    output("Automatic refuelling complete")
                end
            end

            -- if still insufficient fuel and AUTO_RETURN enabled, commence returning
            if(turtle.getFuelLevel() < blocksTunneled + 25 and AUTO_RETURN) then
                setOperation("RETURN")
            end
        end

        if(turtle.getFuelLevel() == 0) then
            output("Out of fuel. Halting tunnel operation.")
            setOperation("")
        end

        -- check how many item slots are consumed
        if(PLACE_CHESTS) then  
            if(getConsumedItemSlots() == MAX_ITEM_SLOTS) then
                unloadToChest(true)        
            end
        end

        -- place torch every X blocks  
        if(PLACE_TORCHES) then
            if(blocksTunneled % TORCH_INTERVAL == 0) then
                placeDown("minecraft:torch")
            end
        end
    
        blocksTunneled = blocksTunneled + 1
        -- write to memory the current state of the tunneling operation
        memoryFile = fs.open("/WorldBreakerState/operation/numbers", "w")
        memoryFile.writeLine(blocksTunneled)
        memoryFile.writeLine(snakesMade)
        memoryFile.close()
        
        -- report occasional statistics
        if(REPORT_STATISTICS) then
            if(blocksTunneled % 50 == 0) then
                output("Tunneled: " .. blocksTunneled, " blocks")
            end
            if(turtle.getFuelLevel() % 100 == 0) then
                output("Fuel Level: " .. turtle.getFuelLevel())
            end
        end

        -- check if the tunnel is too long and needs to be stopped or snaked
        if(blocksTunneled % MAX_TUNNEL_DISTANCE == 0 and blocksTunneled ~= 0) then
            output("Tunnel has exceeded the maximum permitted length of " .. MAX_TUNNEL_DISTANCE)
            
            -- if allowed to snake tunnels
            if(SNAKE_TUNNELS) then
                output("Snaking tunnel in other direction")

                -- place a torch at the corner of the turn
                if(PLACE_TORCHES) then
                    placeDown("minecraft:torch")
                end

                -- alternate between turning left and right to make a snaking pattern
                if(snakesMade % 2 == 0) then
                    turtle.turnRight()
                else
                    turtle.turnLeft()
                end

                -- mine across SNAKE_TUNNEL_SEPARATION blocks to next turn
                for blocks = 0, SNAKE_TUNNEL_SEPARATION do
                    turtle.dig()
                    turtle.forward()
                    turtle.digDown()
                end

                if(turtle.getFuelLevel() == 0) then
                    output("Out of fuel. Halting snaking operation during tunneling.")
                    setOperation("")
                else
                    if(snakesMade % 2 == 0) then
                        turtle.turnRight()
                    else
                        turtle.turnLeft()
                    end
                end

                -- place a torch at the corner of the turn
                if(PLACE_TORCHES) then
                    placeDown("minecraft:torch")
                end

                snakesMade = snakesMade + 1
            else    -- snaking is not enabled, so return to start of tunnel
                setOperation("RETURN")
            end
        end
    end
end

-- back up until a wall is reached
function returnOperation()
    output("Returning")

    local nextTurn = "left"
    if(snakesMade % 2 == 0) then
        nextTurn = "right"
    end
    local startTurn = 1

    if(operationRestoredFromMemory) then    -- attempt to restore all runtime state values if this operation was restored from memory
        if(fs.exists("/WorldBreakerState/operation/numbers")) then
            local memoryFile = fs.open("/WorldBreakerState/operation/numbers", "r")
            memoryFile.readLine()   -- irrelevant line
            snakesMade = tonumber(memoryFile.readLine())
            memoryFile.close()
        end

        if(fs.exists("/WorldBreakerState/operation/return")) then
            local memoryFile = fs.open("/WorldBreakerState/operation/return", "r")
            startTurn = tonumber(memoryFile.readLine())
            nextTurn = memoryFile.readLine()
            memoryFile.close()
        end
    end

    local turnsMade = (snakesMade * 2) + 1

    for turn = startTurn, turnsMade do 
        while turtle.back() and currentOperation == "RETURN" do   
        end

        if(turn < turnsMade) then
            if(nextTurn == "left") then
                turtle.turnLeft()
            else
                turtle.turnRight()
            end
        end

        if(turn % 2 == 0) then
            if(nextTurn == "left") then
                nextTurn = "right"
            else
                nextTurn = "left"
            end
        end

        -- write to memory the current state of the return operation
        memoryFile = fs.open("/WorldBreakerState/operation/return", "w")
        memoryFile.writeLine(turn)
        memoryFile.writeLine(nextTurn)
        memoryFile.close()
    end
    turtle.down()
    
    -- if operation hasn't changed during the return, reset it now that return is complete
    if(currentOperation == "RETURN") then
        setOperation("")
    end

    output("Returned") 
    
    if(turtle.getFuelLevel() == 0) then
        output("Out of fuel!")
    end
end

-- halt movement and move to ground
function stopOperation()
    output("Stopping")
    
    while turtle.down() do
    end
    
    output("Stopped")

    if(turtle.getFuelLevel() == 0) then
        output("Out of fuel!")
    end

    setOperation("")
end

-- jump up a block and move until a wall is found
function moveToDigPosition()    
    output("Moving into position")
    
    if(operationRestoredFromMemory == false) then
        turtle.digUp()
        turtle.up()
    end

    while turtle.forward() do
    end
    
    tunnelOperation()    
end

-- dump mined into a chest temporarily
function unloadToChest(isTunnel)
    local chestSlot
    if(USE_ENDER_CHESTS) then
        chestSlot = getItemSlotWithItem("enderstorage:ender_storage")
    else
        chestSlot= getItemSlotWithItem("minecraft:chest")
    end
    
    if(chestSlot ~= -1) then

        turtle.select(chestSlot)

        -- depending on type of dig and chest, place chest in different locations
        if(isTunnel and USE_ENDER_CHESTS == false) then
            -- dig off to the left and place a chest
            turtle.turnLeft()
            turtle.dig()
            turtle.forward()
            turtle.digDown()
            turtle.placeDown()
        elseif(USE_ENDER_CHESTS) then
            -- place ender chest below turtle
            if(turtle.placeDown() == false) then
                turtle.digDown()
                turtle.placeDown()
            end
        else
            -- move to ground level and place chest there
            while turtle.down() do
            end

            turtle.up()
            if(turtle.placeDown() == false) then
                turtle.digDown()
                turtle.placeDown()
            end
        end

        -- unload inventory to chest
        output("Unloading inventory to chest")
        local keptCoal = false
        for slot = 1, MAX_ITEM_SLOTS do
            turtle.select(slot)
            if(turtle.getItemDetail()) then
                if(tableHasValue(UNLOAD_BLACKLIST, turtle.getItemDetail().name) == false) then  -- do not unload certain items

                    -- preserve first slot of coal (and only first slot) [this only applies if AUTO_REFUEL is enabled]
                    if(turtle.getItemDetail().name == "minecraft:coal" and keptCoal == false and AUTO_REFUEL) then
                        keptCoal = true
                    else
                        turtle.dropDown()   -- unload to chest
                    end
                end      
            end
        end
        
        -- depending on type of dig and chest, return to digging position differently
        if(isTunnel and USE_ENDER_CHESTS == false) then
            turtle.back()
            turtle.turnRight()
        elseif(USE_ENDER_CHESTS) then
            turtle.digDown()
        else
            while(turtle.up()) do
            end
        end
    end
end

-- place a given block below the turtle
function placeDown(block)
    local slot = getItemSlotWithItem(block)
    if(slot ~= -1) then
        turtle.select(slot)
        turtle.placeDown()
    end
end

-- move turtle in a given direction, will look to operation parameters for number of blocks to move
function move(direction)
    local blocksToMove = 1

    -- check for number of blocks to move (if specified)
    if(currentOperationParameters[1] ~= nil) then
        blocksToMove = tonumber(currentOperationParameters[1])
	       if(blocksToMove == false) then
            blocksToMove = 1
        end
    end
    
    output("Moving " .. blocksToMove .. " block(s) " .. direction)
    
    for i = 1, blocksToMove do
        if(direction == "backward") then
            turtle.back()
        elseif(direction == "up") then
            turtle.up()
        elseif(direction == "down") then
            turtle.down()
        else
            turtle.forward()
        end

        -- save number of blocks remaining to memory just in case turtle needs to resume from memory
        currentOperationParameters[1] = tonumber(currentOperationParameters[1]) - 1
        updateMemory()
    end
    
    if(turtle.getFuelLevel() == 0) then
        output("Out of fuel!")
    end
                
    output("Movement complete")
    setOperation("")
end

-- move turtle in a given direction, will look to operation parameters for number of blocks to move
function dig()
    local direction = "FORWARD"

    -- check for number of blocks to move (if specified)
    if(currentOperationParameters[1] ~= nil) then
        direction = currentOperationParameters[1]
	        if(direction == false) then
            direction = "FORWARD"
        end
    end
    
    if(direction == "UP") then
        local blockFound, blockMetaData = turtle.inspectUp()
        if(blockFound) then
            if(turtle.digUp()) then
                output("Dug " .. blockMetaData.name)
            else
                output("Failed to dig")
            end
        else
            output("No block detected")
        end
    elseif(direction == "DOWN") then
        local blockFound, blockMetaData = turtle.inspectDown()
        if(blockFound) then
            if(turtle.digDown()) then
                output("Dug " .. blockMetaData.name)
            else
                output("Failed to dig")
            end
        else
            output("No block detected")
        end
    elseif(direction == "LEFT") then
        turtle.turnLeft()
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                output("Dug " .. blockMetaData.name)
            else
                output("Failed to dig")
            end
        else
            output("No block detected")
        end
        turtle.turnRight()
    elseif(direction == "RIGHT") then
        turtle.turnRight()
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                output("Dug " .. blockMetaData.name)
            else
                output("Failed to dig")
            end
        else
            output("No block detected")
        end
        turtle.turnLeft()
    elseif(direction == "BACK" or direction == "BACKWARDS") then
        turtle.turnRight()
        turtle.turnRight()
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                output("Dug " .. blockMetaData.name)
            else
                output("Failed to dig")
            end
        else
            output("No block detected")
        end
        turtle.turnLeft()
        turtle.turnLeft()
    else    -- default: dig forward
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                output("Dug " .. blockMetaData.name)
            else
                output("Failed to dig")
            end
        else
            output("No block detected")
        end
    end
    
    if(turtle.getFuelLevel() == 0) then
        output("Out of fuel!")
    end
                
    setOperation("")
end

-- will cease current turtle operation but will not shutdown the program
function setOperation(operation)
    operationRestoredFromMemory = false
    currentOperation = operation
    currentOperationParameters = {}
    updateMemory()
end

-- GENERIC FUNCTIONS

-- check how many item slots are consumed
function getConsumedItemSlots()
    local consumedItemSlots = 0
    for slot = 1, MAX_ITEM_SLOTS do
        if(turtle.getItemDetail(slot)) then
            consumedItemSlots = consumedItemSlots + 1
        end
    end
    return consumedItemSlots
end

-- return the item slot index that contains the given item name (will return -1 if not found)
function getItemSlotWithItem(itemName)
    for slot = 1, MAX_ITEM_SLOTS do
        if turtle.getItemDetail(slot) then
            if(turtle.getItemDetail(slot).name == itemName) then
                return slot
            end
        end
    end
    return -1
end

-- does table contain value?
function tableHasValue(tbl, val)
    for index, value in ipairs(tbl) do
        if value == val then
            return true
        end
    end
    
    return false
end

-- return index of item in table
function indexOfInTable(tbl, el)
    for index, value in pairs(tbl) do
        if value == el then
            return index
        end
    end
end

-- get string of comma-separated values from table
function tableToString(tbl)
    local s = ""
    local entries = 0

    -- concatenate comma-separated values
    for index, value in ipairs(tbl) do
        s = s .. value .. ", "
        entries = entries + 1
    end
    
    -- remove comma if at least one entry was found
    if(entries > 0) then
        s = s:sub(1, -3)
    end
    
    return s
end

-- convert "true" to true and "false" to false, defaults to false
function stringToBoolean(s)
    if(s:upper() == "TRUE") then
        return true
    else
        return false
    end
end

-- split string via delimiter into a table
function split(s, delimiter)
    result = {};
    for match in (s..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, match);
    end
    return result;
end

-- print message to console and output via modem
function output(message)
    print(message)
    modem.transmit(REMOTE_FREQUENCY, MODEM_FREQUENCY, message .. " [" .. os.getComputerID() .. "]")
end

-- STATE SAVING

-- initialise program state from files
function initialise()
    modem.open(MODEM_FREQUENCY)

    -- load configuration/state from files
    if(fs.exists("/WorldBreakerState/operation/operation")) then
        local memoryFile = fs.open("/WorldBreakerState/operation/operation", "r")
        local temp = memoryFile.readLine()
        if(currentOperation ~= temp) then
            operationRestoredFromMemory = true
        end
        currentOperation = temp
        memoryFile.close()
    end

    if(fs.exists("/WorldBreakerState/operation/operationParameters")) then
        local memoryFile = fs.open("/WorldBreakerState/operation/operationParameters", "r")
        local line = memoryFile.readLine()
        while line ~= nil do
            table.insert(currentOperationParameters, line)
            line = memoryFile.readLine()
        end
        memoryFile.close()
    end

    if(fs.exists("/WorldBreakerState/tables/BLOCK_ALERT_WHITELIST")) then
        local memoryFile = fs.open("/WorldBreakerState/tables/BLOCK_ALERT_WHITELIST", "r")
        line = memoryFile.readLine()
        while line ~= nil do
            table.insert(BLOCK_ALERT_WHITELIST, line)
            line = memoryFile.readLine()
        end
        memoryFile.close()
    end

    if(fs.exists("/WorldBreakerState/tables/UNLOAD_BLACKLIST")) then
        local memoryFile = fs.open("/WorldBreakerState/tables/UNLOAD_BLACKLIST", "r")
        line = memoryFile.readLine()
        while line ~= nil do
            table.insert(UNLOAD_BLACKLIST, line)
            line = memoryFile.readLine()
        end
        memoryFile.close()
    end

    if(fs.exists("/WorldBreakerState/tables/BLOCK_CHASE_WHITELIST")) then
        local memoryFile = fs.open("/WorldBreakerState/tables/BLOCK_CHASE_WHITELIST", "r")
        line = memoryFile.readLine()
        while line ~= nil do
            table.insert(BLOCK_CHASE_WHITELIST, line)
            line = memoryFile.readLine()
        end
        memoryFile.close()
    end

    if(fs.exists("/WorldBreakerState/booleans")) then
        local memoryFile = fs.open("/WorldBreakerState/booleans", "r")
        SNAKE_TUNNELS = stringToBoolean(memoryFile.readLine())
        PLACE_TORCHES = stringToBoolean(memoryFile.readLine())
        PLACE_CHESTS = stringToBoolean(memoryFile.readLine())
        USE_ENDER_CHESTS = stringToBoolean(memoryFile.readLine())
        BLOCK_ALERTS = stringToBoolean(memoryFile.readLine())
        REPORT_STATISTICS = stringToBoolean(memoryFile.readLine())
        AUTO_RETURN = stringToBoolean(memoryFile.readLine())
        AUTO_REFUEL = stringToBoolean(memoryFile.readLine())
        BLOCK_CHASE = stringToBoolean(memoryFile.readLine())
        memoryFile.close()
    end

    if(fs.exists("/WorldBreakerState/numbers")) then
        local memoryFile = fs.open("/WorldBreakerState/numbers", "r")
        MAX_ITEM_SLOTS = tonumber(memoryFile.readLine())
        TORCH_INTERVAL = tonumber(memoryFile.readLine())
        MAX_TUNNEL_DISTANCE = tonumber(memoryFile.readLine())
        SNAKE_TUNNEL_SEPARATION = tonumber(memoryFile.readLine())
        memoryFile.close()
    end
end

-- save current state of program to file which can be reloaded later
function updateMemory()
    local memoryFile = fs.open("/WorldBreakerState/operation/operation", "w")
    memoryFile.writeLine(currentOperation)
    memoryFile.close()

    memoryFile = fs.open("/WorldBreakerState/operation/operationParameters", "w")
    for index, value in ipairs(currentOperationParameters) do
        memoryFile.writeLine(value)
    end
    memoryFile.close()

    memoryFile = fs.open("/WorldBreakerState/tables/BLOCK_ALERT_WHITELIST", "w")
    for index, value in ipairs(BLOCK_ALERT_WHITELIST) do
        memoryFile.writeLine(value)
    end
    memoryFile.close()

    memoryFile = fs.open("/WorldBreakerState/tables/UNLOAD_BLACKLIST", "w")
    for index, value in ipairs(UNLOAD_BLACKLIST) do
        memoryFile.writeLine(value)
    end
    memoryFile.close()

    memoryFile = fs.open("/WorldBreakerState/tables/BLOCK_CHASE_WHITELIST", "w")
    for index, value in ipairs(BLOCK_CHASE_WHITELIST) do
        memoryFile.writeLine(value)
    end
    memoryFile.close()

    memoryFile = fs.open("/WorldBreakerState/booleans", "w")
    memoryFile.writeLine(SNAKE_TUNNELS)
    memoryFile.writeLine(PLACE_TORCHES)
    memoryFile.writeLine(PLACE_CHESTS)
    memoryFile.writeLine(USE_ENDER_CHESTS)
    memoryFile.writeLine(BLOCK_ALERTS)
    memoryFile.writeLine(REPORT_STATISTICS)
    memoryFile.writeLine(AUTO_RETURN)
    memoryFile.writeLine(AUTO_REFUEL)
    memoryFile.writeLine(BLOCK_CHASE)
    memoryFile.close()

    memoryFile = fs.open("/WorldBreakerState/numbers", "w")
    memoryFile.writeLine(MAX_ITEM_SLOTS)
    memoryFile.writeLine(TORCH_INTERVAL)
    memoryFile.writeLine(MAX_TUNNEL_DISTANCE)
    memoryFile.writeLine(SNAKE_TUNNEL_SEPARATION)
    memoryFile.close()    
end

-- EVENT HANDLING

-- message received on modem
function modemMessageReceived(name, channel, replyChannel, message, distance)
    local tokens = split(message, " ")

    if(tokens[1] == "ENABLE") then  -- enable a boolean
        if(tokens[2] ~= nil) then
            if(tokens[2] == "PLACE_TORCHES") then
                PLACE_TORCHES = true
                output("Automatic torch placement every " .. TORCH_INTERVAL .. " blocks enabled")
            elseif(tokens[2] == "PLACE_CHESTS") then
                PLACE_CHESTS = true
                output("Automatic chest placement and unloading when full enabled")
            elseif(tokens[2] == "USE_ENDER_CHESTS") then
                USE_ENDER_CHESTS = true
                output("Automatic chest placement using ender chests enabled")
            elseif(tokens[2] == "BLOCK_ALERTS") then
                BLOCK_ALERTS = true
                output("Alerts for given set of blocks when detected enabled")
            elseif(tokens[2] == "REPORT_STATISTICS") then
                REPORT_STATISTICS = true
                output("Occasional statistics reports enabled")
            elseif(tokens[2] == "AUTO_RETURN") then
                AUTO_RETURN = true
                output("Automatic return upon low fuel level enabled")
            elseif(tokens[2] == "AUTO_REFUEL") then
                AUTO_REFUEL = true
                output("Automatic refuel using on-hand coal enabled")
            elseif(tokens[2] == "BLOCK_CHASE") then
                BLOCK_CHASE = true
                output("Certain blocks to be mined in their entirety enabled")
            elseif(tokens[2] == "SNAKE_TUNNELS") then
                SNAKE_TUNNELS = true
                output("Snaking of maximum distance tunnels enabled")
            end
        end

    elseif(tokens[1] == "DISABLE") then -- disable a boolean
        if(tokens[2] ~= nil) then
            if(tokens[2] == "PLACE_TORCHES") then
                PLACE_TORCHES = false
                output("Automatic torch placement every " .. TORCH_INTERVAL .. " blocks disabled")
            elseif(tokens[2] == "PLACE_CHESTS") then
                PLACE_CHESTS = false
                output("Automatic chest placement and unloading when full disabled")
            elseif(tokens[2] == "USE_ENDER_CHESTS") then
                USE_ENDER_CHESTS = false
                output("Automatic chest placement using ender chests disabled")
            elseif(tokens[2] == "BLOCK_ALERTS") then
                BLOCK_ALERTS = false
                output("Alerts for given set of blocks when detected disabled")
            elseif(tokens[2] == "REPORT_STATISTICS") then
                REPORT_STATISTICS = false
                output("Occasional statistics reports disabled")
            elseif(tokens[2] == "AUTO_RETURN") then
                AUTO_RETURN = false
                output("Automatic return upon low fuel level disabled")
            elseif(tokens[2] == "AUTO_REFUEL") then
                AUTO_REFUEL = false
                output("Automatic refuel using on-hand coal disabled")
            elseif(tokens[2] == "BLOCK_CHASE") then
                BLOCK_CHASE = false
                output("Certain blocks to be mined in their entirety disabled")
            elseif(tokens[2] == "SNAKE_TUNNELS") then
                SNAKE_TUNNELS = false
                output("Snaking of maximum distance tunnels disabled")
            end
        end

    elseif(tokens[1] == "SET") then     -- set a value
        if(tokens[2] ~= nil and tokens[3] ~= nil) then
            if(tokens[2] == "TORCH_INTERVAL") then
                local temp = tonumber(tokens[3])

                if(temp == false) then
                    output("That is not a valid integer for TORCH_INTERVAL")
                else
                    TORCH_INTERVAL = temp
                    output("Automatic torch placements will be " .. TORCH_INTERVAL .. " blocks apart")
                end
            elseif(tokens[2] == "MAX_TUNNEL_DISTANCE") then
                local temp = tonumber(tokens[3])

                if(temp == false) then
                    output("That is not a valid integer for MAX_TUNNEL_DISTANCE")
                else
                    MAX_TUNNEL_DISTANCE = temp
                    output("Tunnels are limited at " .. MAX_TUNNEL_DISTANCE .. " blocks long")
                end
            elseif(tokens[2] == "SNAKE_TUNNEL_SEPARATION") then
                local temp = tonumber(tokens[3])

                if(temp == false) then
                    output("That is not a valid integer for SNAKE_TUNNEL_SEPARATION")
                else
                    SNAKE_TUNNEL_SEPARATION = temp
                    output("Tunnels snaked " .. SNAKE_TUNNEL_SEPARATION .. " blocks apart")
                end
            end
        end

    elseif(tokens[1] == "ADD") then     -- add value to table
        if(tokens[2] ~= nil and tokens[3] ~= nil) then
            if(tokens[2] == "BLOCK_ALERT_WHITELIST") then
                table.insert(BLOCK_ALERT_WHITELIST, tokens[3])
                output("When detecting " .. tokens[3] .. " an alert will be sent")
            elseif(tokens[2] == "UNLOAD_BLACKLIST") then
                table.insert(UNLOAD_BLACKLIST, tokens[3])
                output("When unloading to a chest, " .. tokens[3] .. " will be prevented from being unloaded")
            elseif(tokens[2] == "BLOCK_CHASE_WHITELIST") then
                table.insert(BLOCK_CHASE_WHITELIST, tokens[3])
                output("When encountered, " .. tokens[3] .. " will be mined in its entirety")
            end
        end

    elseif(tokens[1] == "REMOVE") then  -- remove value from table
        if(tokens[2] ~= nil and tokens[3] ~= nil) then
            if(tokens[2] == "BLOCK_ALERT_WHITELIST") then
                table.remove(BLOCK_ALERT_WHITELIST, indexOfInTable(BLOCK_ALERT_WHITELIST, tokens[3]))
                output(tokens[3] .. " is no longer subject to alerts when detected")
            elseif(tokens[2] == "UNLOAD_BLACKLIST") then
                table.remove(UNLOAD_BLACKLIST, indexOfInTable(UNLOAD_BLACKLIST, tokens[3]))
                output("When unloading to a chest, " .. tokens[3] .. " will now be allowed to be unloaded")
            elseif(tokens[2] == "BLOCK_CHASE_WHITELIST") then
                table.remove(BLOCK_CHASE_WHITELIST, indexOfInTable(BLOCK_CHASE_WHITELIST, tokens[3]))
                output("When encountered, " .. tokens[3] .. " will not be mined in its entirety")
            end
        end

    elseif(tokens[1] == "GET") then     -- get a value
        if(tokens[2] ~= nil) then
            if(tokens[2] == "FUEL") then
                output(turtle.getFuelLevel())
            elseif(tokens[2] == "PLACE_TORCHES") then
                output(tostring(PLACE_TORCHES))
            elseif(tokens[2] == "PLACE_CHESTS") then
                output(tostring(PLACE_CHESTS))
            elseif(tokens[2] == "USE_ENDER_CHESTS") then
                output(tostring(USE_ENDER_CHESTS))
            elseif(tokens[2] == "BLOCK_ALERTS") then
                output(tostring(BLOCK_ALERTS))
            elseif(tokens[2] == "REPORT_STATISTICS") then
                output(tostring(REPORT_STATISTICS))
            elseif(tokens[2] == "AUTO_RETURN") then
                output(tostring(AUTO_RETURN))
            elseif(tokens[2] == "AUTO_REFUEL") then
                output(tostring(AUTO_REFUEL))
            elseif(tokens[2] == "SNAKE_TUNNELS") then
                output(tostring(SNAKE_TUNNELS))
            elseif(tokens[2] == "TORCH_INTERVAL") then
                output(tostring(TORCH_INTERVAL))
            elseif(tokens[2] == "MAX_TUNNEL_DISTANCE") then
                output(tostring(MAX_TUNNEL_DISTANCE))
            elseif(tokens[2] == "SNAKE_TUNNEL_SEPARATION") then
                output(tostring(SNAKE_TUNNEL_SEPARATION))
            elseif(tokens[2] == "BLOCK_ALERT_WHITELIST") then
                output(tableToString(BLOCK_ALERT_WHITELIST))
            elseif(tokens[2] == "UNLOAD_BLACKLIST") then
                output(tableToString(UNLOAD_BLACKLIST))
            elseif(tokens[2] == "BLOCK_CHASE_WHITELIST") then
                output(tableToString(BLOCK_CHASE_WHITELIST))
            end
        end

    elseif(tokens[1] == "REFUEL") then  -- refuel requested
        local refuelAmount = 64

        -- get refuel amount if specified
        if(tokens[2] ~= nil) then
            refuelAmount = tonumber(tokens[2])
            if(refuelAmount == false) then
                refuelAmount = 64
            end
        end

        local coalSlot = getItemSlotWithItem("minecraft:coal")
        if(coalSlot ~= -1) then
            turtle.select(coalSlot)
            turtle.refuel(refuelAmount)
            output("Fuel level: " .. turtle.getFuelLevel())  
        else
            output("No fuel available to consume")  
        end 

    elseif(tokens[1] == "RESET") then   -- reset to default requested
        loadDefaults()
        updateMemory()
        output("Default configuration loaded")
    elseif(tokens[1] == "INITIALISE") then  -- update code
        output("Initialising")
        dofile("/Initialise.lua")
    elseif(tokens[1] == "LOCATE") then  -- locate using GPS
        local x, y, z = gps.locate()
        output("Located at " .. x .. ", " .. y .. ", " .. z)
    else    -- is an operation or typo 
        -- parse out first token as operation, and set following tokens as parameters
        operationRestoredFromMemory = false
        currentOperation = tokens[1]
        table.remove(tokens, 1)
        currentOperationParameters = tokens 
    end

    updateMemory()
end

-- outline what events and handlers should be mapped
function eventListener()
    listenForEvent({modem_message=modemMessageReceived})
end

-- listen constantly for events and redirect them appropriately to the event handler
function listenForEvent(functionTbl)
    while currentOperation ~= "SHUTDOWN" do
        tbl = {os.pullEvent()}
        if type(functionTbl[tbl[1]]) == "function" then
            functionTbl[tbl[1]](select(2, unpack(tbl)))
        end
    end
end

-- run main function and event handling code simultaneously
parallel.waitForAll(main, eventListener)