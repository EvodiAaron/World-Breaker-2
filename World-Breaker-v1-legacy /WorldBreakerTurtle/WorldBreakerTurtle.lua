--  ### Transmission Protocol ###

--      ## OUTGOING TRANSMISSION SCHEMA ##
--          # ENROLLMENTS #
--              - "ENROL"
--              - "UNENROL"
--          # METADATA UPDATES #
--              - "FUEL [current fuel level]"
--              - "LOCATION [x coordinate], [y coordinate], [z coordinate]"
--              - "TUNNELED [blocks tunnelled]"
--          # CURRENT OPERATION #
--              - "OPERATION STOPPING"
--              - "OPERATION STOPPED"
--              - "OPERATION RETURNING"
--              - "OPERATION TUNNELLING"
--              - "OPERATION UNLOADING"
--              - "OPERATION SNAKING"
--          # CONFIGURATION #
--              - "SETTING [setting] [current setting parameter]"


--      ## INCOMING TRANSMISSION SCHEMA ##
--          # METADATA UPDATE REQUESTS #
--              - "GET SETTING [setting]"
--              - "GET FUEL"
--              - "GET LOCATION"
--              - "GET OPERATION"
--          # GENERAL #
--              - "REFUEL [number of items to consume]" (defaults to 64)
--              - "OPERATION DIG [direction]" (defaults up)
--              - "SHUTDOWN"
--              - "REBOOT"
--          # TUNNELLING #
--              - "OPERATION TUNNEL"
--              - "OPERATION STOP"
--              - "OPERATION RETURN"
--          # MOVEMENT #
--              - "OPERATION FORWARD [number of blocks]" (defaults to 1 block)
--              - "OPERATION BACKWARD [number of blocks]" (defaults to 1 block)
--              - "OPERATION UP [number of blocks]" (defaults to 1 block)
--              - "OPERATION DOWN [number of blocks]" (defaults to 1 block)
--              - "OPERATION LEFT"
--              - "OPERATION RIGHT"
--              - "OPERATION ROTATE"
--          # CONFIGURATION #
--              - "ENABLE/DISABLE/SET/ADD/REMOVE [setting] [setting parameter]"
--              - "RESET"


-- ############### PROGRAM INITIALISATION ###############

isEnrolled = false

-- settings
REDNET_SIDE = "right"

-- rednet
rednet.open(REDNET_SIDE)

-- manage each operation in the main thread
function main()
    term.clear()
    loadDefaultSettings()
    initialiseFromMemory()

    print(os.getComputerLabel() .. " online")

    -- check for changes in operation and act upon them
    while currentOperation ~= "SHUTDOWN" do
        if(currentOperation == "TUNNEL") then
            tunnelOperation()                 
        elseif(currentOperation == "STOP") then
            stopOperation()
        elseif(currentOperation == "MOVE") then
            moveOperation()
        elseif(currentOperation == "TURN") then
            turnOperation()
        elseif(currentOperation == "DIG") then
            digOperation()
        elseif(currentOperation == "LOCOMOTE") then
            locomoteOperation()
        elseif(currentOperation == "ORIENTATE") then
            orientateOperation()
        elseif(currentOperation == "EXCAVATE") then
            excavateOperation()
        elseif(currentOperation == "REBOOT") then
            unenrol()
            os.reboot()
        else
            os.sleep(0)
        end
    end
end


-- ############### OPERATION MANAGEMENT ###############

-- set the operation of the turtle and alert the master computer
function setOperation(operation, preserveParameters)
    operationRestoredFromMemory = false
    currentOperation = operation
    
    if(preserveParameters ~= nil) then
        if(not preserveParameters) then
            currentOperationParameters = {}
        end
    else
        currentOperationParameters = {}
    end
    updateMemory()

    transmitToMaster("OPERATION " .. currentOperation)
end


-- ############### OPERATIONS ###############
-- operation methods gather data from operation parameters and manage sub-operation methods to complete the operation

-- OPERATION: dig a 1x2 tunnel straight with torches until out of fuel or out of inventory
function tunnelOperation()   
    local startX, startY, startZ = gps.locate(2)
    if(startX == nil) then
        print("Could not contact GPS")
    end

    moveToTunnelPosition()

    blocksTunneled = 0
    snakesMade = 0
    if(operationRestoredFromMemory) then    -- attempt to restore all runtime state values if this operation was restored from memory
        if(fs.exists("/WorldBreakerState/operation/numbers")) then
            local memoryFile = fs.open("/WorldBreakerState/operation/numbers", "r")
            blocksTunneled = tonumber(memoryFile.readLine())
            snakesMade = tonumber(memoryFile.readLine())
            startX = tonumber(memoryFile.readLine())
            startY = tonumber(memoryFile.readLine())
            startZ = tonumber(memoryFile.readLine())
            memoryFile.close()
        end
    end
    
    while currentOperation == "TUNNEL" and turtle.getFuelLevel() > 0 do
                     
        -- check IN FRONT if alert should occur
        if(BLOCK_ALERTS) then
            local blockFound, blockMetaData = turtle.inspect()
            if(blockFound) then
                if(tableHasValue(BLOCK_ALERT_WHITELIST, blockMetaData.name)) then
                    transmitToMaster(blockMetaData.name .. " encountered")
                end
                
                -- keep digging (looped as falling entities may be present)
                while turtle.dig() do
                end
            end
        end

        turtle.forward()
        
        -- check BELOW if alert should occur
        if(BLOCK_ALERTS) then
            blockFound, blockMetaData = turtle.inspectDown()
            if(blockFound) then
                if(tableHasValue(BLOCK_ALERT_WHITELIST, blockMetaData.name)) then
                    transmitToMaster(blockMetaData.name .. " encountered")
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

                    transmitToMaster("FUEL " .. turtle.getFuelLevel())
                end
            end

            -- if still insufficient fuel and AUTO_RETURN enabled, commence returning
            -- calculate number of block movements needed to return to start
            local currentX, currentY, currentZ = gps.locate(2)
            if(currentX == nil) then
                print("Could not contact GPS")
            else
                local axisDifference = math.abs(startX - currentX) + math.abs(startY - currentY) + math.abs(startZ - currentZ)
                if(turtle.getFuelLevel() < axisDifference + 10 and AUTO_RETURN and startX ~= nil) then
                    setOperation("RETURN")
                    locomote(startX, startY, startZ)
                end
            end
        end

        if(turtle.getFuelLevel() == 0) then
            transmitToMaster("FUEL " .. turtle.getFuelLevel())
            setOperation("")
        end

        -- dump if enabled
        if(DUMP) then
            dump()
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
        memoryFile.writeLine(startX)
        memoryFile.writeLine(startY)
        memoryFile.writeLine(startZ)
        memoryFile.close()
        
        -- report occasional statistics
        if(REPORT_STATISTICS) then
            if(blocksTunneled % 10 == 0) then
                transmitToMaster("TUNNELED " .. blocksTunneled)
            end
        end

        -- check if the tunnel is too long and needs to be stopped or snaked
        if(blocksTunneled % MAX_TUNNEL_DISTANCE == 0 and blocksTunneled ~= 0) then
            
            -- if allowed to snake tunnels
            if(SNAKE_TUNNELS) then

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
                    transmitToMaster("FUEL " .. turtle.getFuelLevel())
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

    -- if RETURN operation has been requested whilst tunnelling, locomote to starting position
    if(currentOperation == "RETURN") then
        if(startX ~= nil) then
            setOperation("LOCOMOTE")
            locomote(startX, startY, startZ)
        end

        if(currentOperation == "RETURN" or currentOperation == "LOCOMOTE") then
            setOperation("")
        end
    end

    if(currentOperation == "TUNNEL") then
        setOperation("")
    end
end

-- OPERATION: halt movement and move to ground
function stopOperation()
    
    while turtle.down() and currentOperation == "STOP" do
    end

    if(turtle.getFuelLevel() == 0) then
        transmitToMaster("FUEL " .. turtle.getFuelLevel())
    end

    if(currentOperation == "STOP") then
        setOperation("")
    end
end

-- OPERATION: move turtle in a given direction a given number of blocks
function moveOperation()
    
    local direction = currentOperationParameters[1]
    if(direction == "BACKWARD") then
        setOperation("BACKWARD", true)
    elseif(direction == "UP") then
        setOperation("UP", true)
    elseif(direction == "DOWN") then
        setOperation("DOWN", true)
    else
        setOperation("FORWARD", true)
    end
    
    local blocksToMove = 1
    -- check for number of blocks to move (if specified)
    if(currentOperationParameters[2] ~= nil) then
        blocksToMove = tonumber(currentOperationParameters[2])
        if(blocksToMove == false) then
            blocksToMove = 1
        end
    end
    
    for i = 1, blocksToMove do
        if(currentOperation == "MOVE") then
            if(direction == "BACKWARD") then
                turtle.back()
            elseif(direction == "UP") then
                turtle.up()
            elseif(direction == "DOWN") then
                turtle.down()
            else
                turtle.forward()
            end

            -- save number of blocks remaining to memory just in case turtle needs to resume from memory
            currentOperationParameters[2] = tonumber(blocksToMove) - 1
            updateMemory()
        end
    end
    
    if(turtle.getFuelLevel() == 0) then
        transmitToMaster("FUEL " .. turtle.getFuelLevel())
    end

    if(currentOperation == "MOVE") then
        setOperation("")
    end
end

-- OPERATION: break a block in any direction around the turtle
function digOperation()
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
                transmitToMaster("DUG " .. blockMetaData.name)
            else
                transmitToMaster("DUG FAILURE")
            end
        else
            transmitToMaster("DUG NOTHING")
        end
    elseif(direction == "DOWN") then
        local blockFound, blockMetaData = turtle.inspectDown()
        if(blockFound) then
            if(turtle.digDown()) then
                transmitToMaster("DUG " .. blockMetaData.name)
            else
                transmitToMaster("DUG FAILURE")
            end
        else
            transmitToMaster("DUG NOTHING")
        end
    elseif(direction == "LEFT") then
        turtle.turnLeft()
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                transmitToMaster("DUG " .. blockMetaData.name)
            else
                transmitToMaster("DUG FAILURE")
            end
        else
            transmitToMaster("DUG NOTHING")
        end
        turtle.turnRight()
    elseif(direction == "RIGHT") then
        turtle.turnRight()
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                transmitToMaster("DUG " .. blockMetaData.name)
            else
                transmitToMaster("DUG FAILURE")
            end
        else
            transmitToMaster("DUG FAILURE")
        end
        turtle.turnLeft()
    elseif(direction == "BACK" or direction == "BACKWARDS") then
        turtle.turnRight()
        turtle.turnRight()
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                transmitToMaster("DUG " .. blockMetaData.name)
            else
                transmitToMaster("DUG FAILURE")
            end
        else
            transmitToMaster("DUG NOTHING")
        end
        turtle.turnLeft()
        turtle.turnLeft()
    else    -- default: dig forward
        local blockFound, blockMetaData = turtle.inspect()
        if(blockFound) then
            if(turtle.dig()) then
                transmitToMaster("DUG " .. blockMetaData.name)
            else
                transmitToMaster("DUG FAILURE")
            end
        else
            transmitToMaster("DUG NOTHING")
        end
    end
                
    if(currentOperation == "DIG") then
        setOperation("")
    end
end

-- OPERATION: navigate to a coordinate
function locomoteOperation()
    local destinationX = tonumber(currentOperationParameters[1])
    local destinationY = tonumber(currentOperationParameters[2])
    local destinationZ = tonumber(currentOperationParameters[3])

    if(destinationX ~= nil and destinationY ~= nil and destinationZ ~= nil) then
        locomote(destinationX, destinationY, destinationZ)
    else
        print("Coordinates for locomotion are missing/invalid")
    end

    if(currentOperation == "LOCOMOTE") then
        setOperation("")
    end
end

-- OPERATION: turn to a specified heading
function orientateOperation()
    local desiredHeading = currentOperationParameters[1]:upper()

    if(desiredHeading ~= nil and (desiredHeading == "NORTH" or desiredHeading == "SOUTH" or desiredHeading == "EAST" or desiredHeading == "WEST")) then
        changeHeading(desiredHeading, determineOrientation(false, true))
    end

    if(currentOperation == "ORIENTATE") then
        setOperation("")
    end
end

-- OPERATION: turn left, right, or around
function turnOperation()
    local turn = currentOperationParameters[1]
    if(turn ~= nil) then
        turn = turn:upper()
    end

    if(turn == "LEFT") then
        turtle.turnLeft()
    elseif(turn == "RIGHT") then
        turtle.turnRight()
    else
        turtle.turnRight()
        turtle.turnRight()
    end

    if(currentOperation == "TURN") then
        setOperation("")
    end
end

-- OPERATION: dig out a box
function excavateOperation()
    local startX, startY, startZ = gps.locate(2)
    if(startX == nil) then
        print("Could not contact GPS")
    end

    local lengthBlocks = tonumber(currentOperationParameters[1])
    local widthBlocks = tonumber(currentOperationParameters[2])
    local heightBlocks = tonumber(currentOperationParameters[3])

    local heightDirection = currentOperationParameters[4]

    local startLengthParameter = 0
    local startWidthParameter = 0
    local startHeightParameter = 0

    if(operationRestoredFromMemory) then    -- attempt to restore all runtime state values if this operation was restored from memory
        if(fs.exists("/WorldBreakerState/operation/numbers")) then
            local memoryFile = fs.open("/WorldBreakerState/operation/numbers", "r")
            lengthBlocks = tonumber(memoryFile.readLine())
            widthBlocks = tonumber(memoryFile.readLine())
            heightBlocks = tonumber(memoryFile.readLine())
            heightDirection = memoryFile.readLine()
            startLengthParameter = tonumber(memoryFile.readLine())
            startWidthParameter = tonumber(memoryFile.readLine())
            startHeightParameter = tonumber(memoryFile.readLine())
            startX = tonumber(memoryFile.readLine())
            startY = tonumber(memoryFile.readLine())
            startZ = tonumber(memoryFile.readLine())
            memoryFile.close()
        end
    end

    
    
    if(heightDirection == nil) then
        heightDirection = "DOWN" -- default to down
    else
        heightDirection = heightDirection:upper()
        if(heightDirection ~= "UP" and heightDirection ~= "DOWN") then
            heightDirection = "DOWN" -- default to down
        end
    end

    if(lengthBlocks ~= nil and widthBlocks ~= nil and heightBlocks ~= nil) then

        for height = startHeightParameter, heightBlocks - 1 do

            local startWidth = startWidthParameter
            local endWidth = widthBlocks - 1
            local step = 1
            if(height % 2 == 1) then
                startWidth = endWidth
                endWidth = 0
                step = -1
            end

            for width = startWidth, endWidth, step do
                for length = startLengthParameter, lengthBlocks - 2 do
                    if(currentOperation == "EXCAVATE") then
                        while turtle.dig() and currentOperation == "EXCAVATE" do
                        end

                        -- dump if enabled
                        if(DUMP) then
                            dump()
                        end

                        -- check how many item slots are consumed
                        if(PLACE_CHESTS) then  
                            if(getConsumedItemSlots() == MAX_ITEM_SLOTS) then
                                unloadToChest(false)
                            end
                        end

                        if(turtle.getFuelLevel() == 0) then
                            transmitToMaster("FUEL " .. turtle.getFuelLevel())
                            setOperation("")
                        end

                        while not turtle.forward() do
                        end

                        -- write to memory the current state of the excavation operation
                        local memoryFile = fs.open("/WorldBreakerState/operation/numbers", "w")
                        memoryFile.writeLine(lengthBlocks)
                        memoryFile.writeLine(widthBlocks)
                        memoryFile.writeLine(heightBlocks)
                        memoryFile.writeLine(heightDirection)
                        memoryFile.writeLine(length)
                        memoryFile.writeLine(width)
                        memoryFile.writeLine(height)
                        memoryFile.writeLine(startX)
                        memoryFile.writeLine(startY)
                        memoryFile.writeLine(startZ)
                        memoryFile.close()

                        -- if fuel falls below aproximate blocks mined + 25, try refuel or return
                        if(turtle.getFuelLevel() < ((height + 1) * (width + 1) * (length + 1)) + 25) then
                            -- if AUTO_REFUEL enabled, check if there is any coal on-hand, if so refuel 32 coal
                            if(AUTO_REFUEL) then
                                local coalSlot = getItemSlotWithItem("minecraft:coal")
                                if(coalSlot ~= -1) then
                                    turtle.select(coalSlot)
                                    turtle.refuel()

                                    transmitToMaster("FUEL " .. turtle.getFuelLevel())
                                end
                            end

                            -- if still insufficient fuel and AUTO_RETURN enabled, commence returning
                            -- calculate number of block movements needed to return to start
                            local currentX, currentY, currentZ = gps.locate(2)
                            if(currentX == nil) then
                                print("Could not contact GPS")
                            else
                                local axisDifference = math.abs(startX - currentX) + math.abs(startY - currentY) + math.abs(startZ - currentZ)
                                if(turtle.getFuelLevel() < axisDifference + 10 and AUTO_RETURN and startX ~= nil) then
                                    setOperation("RETURN")
                                    locomote(startX, startY, startZ)
                                end
                            end
                        end                       
                    end
                end

                if(currentOperation == "EXCAVATE") then
                    if(endWidth > startWidth) then  -- standard
                        if(width < endWidth) then
                            if(width % 2 == 1) then
                                turtle.turnLeft()
                                while turtle.dig() do
                                end

                                while not turtle.forward() do
                                end

                                turtle.turnLeft()
                            else
                                turtle.turnRight()
                                while turtle.dig() do
                                end

                                while not turtle.forward() do
                                end

                                turtle.turnRight()
                            end
                        end
                    else    -- reversed
                        if(width > endWidth) then
                            if(width % 2 == 1) then
                                turtle.turnLeft()
                                while turtle.dig() do
                                end
                                turtle.forward()
                                turtle.turnLeft()
                            else
                                turtle.turnRight()
                                while turtle.dig() do
                                end
                                turtle.forward()
                                turtle.turnRight()
                            end
                        end
                    end
                end
            end
            
            -- move up or down
            if(height < heightBlocks - 1 and currentOperation == "EXCAVATE") then
                if(heightDirection == "UP") then
                    turtle.digUp()

                    while not turtle.up() do
                    end
                    
                    turtle.turnRight()
                    turtle.turnRight()
                else
                    turtle.digDown()

                    while not turtle.down() do
                    end

                    turtle.turnRight()
                    turtle.turnRight()
                end
            end
        end
    end

    -- if RETURN operation has been requested whilst tunnelling, locomote to starting position
    if(currentOperation == "RETURN") then
        if(startX ~= nil) then
            setOperation("LOCOMOTE")
            locomote(startX, startY, startZ)
        end

        if(currentOperation == "RETURN" or currentOperation == "LOCOMOTE") then
            setOperation("")
        end
    end

    if(currentOperation == "EXCAVATE") then
        setOperation("")
    end
end

-- ############### SUB-OPERATION METHODS ###############

-- jump up a block and move until a wall is found
function moveToTunnelPosition()
    if(operationRestoredFromMemory == false) then
        turtle.digUp()
        turtle.up()
    end

    while turtle.forward() and currentOperation == "TUNNEL" do
    end
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

-- dump items from DUMP_WHITELIST
function dump()
    for index, itemToDump in pairs(DUMP_WHITELIST) do
        local slot = getItemSlotWithItem(itemToDump) 
        if(slot ~= -1) then
            turtle.select(slot)
            turtle.drop()
        end
    end
end

-- move turn to a direction that the turtle can move forward and will return the heading
function determineOrientation(allowBlockBreak, stayInPlace)
    local startX, startY, startZ = gps.locate(2)
    if(startX == nil) then
        print("Could not contact GPS")
        return false
    end

    if(allowBlockBreak) then    -- if allowed, just break any blocks ahead and move there
        while(turtle.dig()) do
        end
        turtle.forward()
    else
        -- try to move in a direction
        if(turtle.forward()) then                               -- try forward
        elseif(turtle.turnRight() and turtle.forward()) then    -- was blocked, turn and try again
        elseif(turtle.turnRight() and turtle.forward()) then    -- was blocked, turn and try again
        elseif(turtle.turnRight() and turtle.forward()) then    -- was blocked, turn and try again
        else    
            print("Cannot move in any direction to determine orientation")
            return nil
        end
    end

    local finishX, finishY, finishZ = gps.locate(2)
    if(finishX == nil) then
        print("Could not contact GPS")
        return false
    end

    if(stayInPlace) then
        turtle.back()
    end

    -- determine direction
    if(finishX > startX) then
        return "EAST"
    elseif(finishX < startX) then
        return "WEST"
    elseif(finishZ > startZ) then
        return "SOUTH"
    elseif(finishZ < startZ) then
        return "NORTH"
    else
        print("An unknown error occured whilst attempting to orientate")
        return nil
    end
end

-- turn from current heading to a desired heading
function changeHeading(desiredHeading, currentHeading)
    local desiredHeadingRotations
    local currentHeadingRotations
    local requiredRotations
    
    if(desiredHeading == "NORTH") then
        desiredHeadingRotations = 0
    elseif(desiredHeading == "EAST") then
        desiredHeadingRotations = 1
    elseif(desiredHeading == "SOUTH") then
        desiredHeadingRotations = 2
    elseif(desiredHeading == "WEST") then
        desiredHeadingRotations = 3
    else
        return nil
    end

    if(currentHeading == "NORTH") then
        currentHeadingRotations = 0
    elseif(currentHeading == "EAST") then
        currentHeadingRotations = 1
    elseif(currentHeading == "SOUTH") then
        currentHeadingRotations = 2
    else
        currentHeadingRotations = 3
    end

    requiredRotations = desiredHeadingRotations - currentHeadingRotations
    if(requiredRotations < 0) then
        requiredRotations = requiredRotations + 4
    end
    
    if(requiredRotations == 3) then
        turtle.turnLeft()
    else
        while requiredRotations > 0 do
            turtle.turnRight()
            requiredRotations = requiredRotations - 1
        end
    end

    return desiredHeading
end

-- navigate to a GPS location
function locomote(destinationX, destinationY, destinationZ)
    
    -- attempt to determine orientation
    local orientation = determineOrientation(false, false)
    if(orientation == nil) then
        orientation = determineOrientation(true, false)  -- if turtle was blocked, allow breaking of blocks this time
    end
    if(orientation == nil) then
        print("Cannot orientate for locomotion")
    elseif(not orientation) then
        print("GPS connection is inhibited")

    else
        -- get starting position
        local x, y, z = gps.locate(2)
        if(x == nil) then
            print("Could not contact GPS")
            setOperation("")
            return
        end

        if(x == destinationX and y == destinationY and z == destinationZ)  then
            print("Already at destination")
        else
            local xDifference = destinationX - x
            local yDifference = destinationY - y
            local zDifference = destinationZ - z
            local xTravelled = 0
            local yTravelled = 0
            local zTravelled = 0

            -- x axis
            if(xDifference > 0 and currentOperation == "LOCOMOTE") then
                -- travel EAST
                orientation = changeHeading("EAST", orientation)
                while(xTravelled < xDifference and currentOperation == "LOCOMOTE") do
                    while(turtle.dig()) do
                    end
                    turtle.forward()

                    xTravelled = xTravelled + 1
                end

            elseif(xDifference < 0 and currentOperation == "LOCOMOTE") then
                -- travel WEST
                orientation = changeHeading("WEST", orientation)
                while(xTravelled > xDifference and currentOperation == "LOCOMOTE") do
                    while(turtle.dig()) do
                    end
                    turtle.forward()

                    xTravelled = xTravelled - 1
                end
            end

            -- z axis
            if(zDifference > 0 and currentOperation == "LOCOMOTE") then
                -- travel SOUTH
                orientation = changeHeading("SOUTH", orientation)
                while(zTravelled < zDifference and currentOperation == "LOCOMOTE") do
                    while(turtle.dig()) do
                    end
                    turtle.forward()

                    zTravelled = zTravelled + 1
                end

            elseif(zDifference < 0 and currentOperation == "LOCOMOTE") then
                -- travel NORTH
                orientation = changeHeading("NORTH", orientation)
                while(zTravelled > zDifference and currentOperation == "LOCOMOTE") do
                    while(turtle.dig()) do
                    end
                    turtle.forward()

                    zTravelled = zTravelled - 1
                end
            end

            -- y axis
            if(yDifference > 0 and currentOperation == "LOCOMOTE") then
                -- travel UP
                while(yTravelled < yDifference and currentOperation == "LOCOMOTE") do
                    while(turtle.digUp()) do
                    end
                    turtle.up()

                    yTravelled = yTravelled + 1
                end

            elseif(yDifference < 0 and currentOperation == "LOCOMOTE") then
                -- travel DOWN
                while(yTravelled > yDifference and currentOperation == "LOCOMOTE") do
                    while(turtle.digDown()) do
                    end
                    turtle.down()

                    yTravelled = yTravelled - 1
                end
            end
        end
    end
end

-- ############### TRANSMISSION ###############

-- attempt to enrol when turtle is unenrolled
function enrol()
    while not shutdown do
        if(not isEnrolled) then
            print("Requesting enrollment with master computer")
            transmitToMaster("ENROL")
            os.sleep(0.5)
        else
            sleep(0)
        end
    end
end

function unenrol()
    transmitToMaster("UNENROL")
end

-- print message to console and output via rednet
function transmitToMaster(message)
    local serverID = rednet.lookup("WorldBreaker", "MasterComputer")
    if(not serverID) then
        print("Could not find master computer")
        return false
    end
    
    rednet.send(serverID, message)
    return true
end

-- message received via rednet
function messageReceived(sender, message, protocol)
    if(protocol == "dns") then
        return
    end

    local tokens = split(message, " ")
    
    if(tokens[1] == "ENABLE") then          -- enable a boolean
        if(tokens[2] ~= nil) then
            if(tokens[2] == "PLACE_TORCHES") then
                PLACE_TORCHES = true
            elseif(tokens[2] == "PLACE_CHESTS") then
                PLACE_CHESTS = true
            elseif(tokens[2] == "USE_ENDER_CHESTS") then
                USE_ENDER_CHESTS = true
            elseif(tokens[2] == "BLOCK_ALERTS") then
                BLOCK_ALERTS = true
            elseif(tokens[2] == "REPORT_STATISTICS") then
                REPORT_STATISTICS = true
            elseif(tokens[2] == "AUTO_RETURN") then
                AUTO_RETURN = true
            elseif(tokens[2] == "AUTO_REFUEL") then
                AUTO_REFUEL = true
            elseif(tokens[2] == "BLOCK_CHASE") then
                BLOCK_CHASE = true
            elseif(tokens[2] == "SNAKE_TUNNELS") then
                SNAKE_TUNNELS = true
            elseif(tokens[2] == "DUMP") then
                DUMP = true
            end
        end

    elseif(tokens[1] == "DISABLE") then     -- disable a boolean
        if(tokens[2] ~= nil) then
            if(tokens[2] == "PLACE_TORCHES") then
                PLACE_TORCHES = false
            elseif(tokens[2] == "PLACE_CHESTS") then
                PLACE_CHESTS = false
            elseif(tokens[2] == "USE_ENDER_CHESTS") then
                USE_ENDER_CHESTS = false
            elseif(tokens[2] == "BLOCK_ALERTS") then
                BLOCK_ALERTS = false
            elseif(tokens[2] == "REPORT_STATISTICS") then
                REPORT_STATISTICS = false
            elseif(tokens[2] == "AUTO_RETURN") then
                AUTO_RETURN = false
            elseif(tokens[2] == "AUTO_REFUEL") then
                AUTO_REFUEL = false
            elseif(tokens[2] == "BLOCK_CHASE") then
                BLOCK_CHASE = false
            elseif(tokens[2] == "SNAKE_TUNNELS") then
                SNAKE_TUNNELS = false
            elseif(tokens[2] == "DUMP") then
                DUMP = false
            end
        end

    elseif(tokens[1] == "SET") then         -- set a value
        if(tokens[2] ~= nil and tokens[3] ~= nil) then
            if(tokens[2] == "TORCH_INTERVAL") then
                local temp = tonumber(tokens[3])

                if(temp) then
                    TORCH_INTERVAL = temp
                end
            elseif(tokens[2] == "MAX_TUNNEL_DISTANCE") then
                local temp = tonumber(tokens[3])

                if(temp) then
                    MAX_TUNNEL_DISTANCE = temp
                end
            elseif(tokens[2] == "SNAKE_TUNNEL_SEPARATION") then
                local temp = tonumber(tokens[3])

                if(temp) then
                    SNAKE_TUNNEL_SEPARATION = temp
                end
            end
        end

    elseif(tokens[1] == "ADD") then         -- add value to table
        if(tokens[2] ~= nil and tokens[3] ~= nil) then
            if(tokens[2] == "BLOCK_ALERT_WHITELIST") then
                table.insert(BLOCK_ALERT_WHITELIST, tokens[3])
            elseif(tokens[2] == "UNLOAD_BLACKLIST") then
                table.insert(UNLOAD_BLACKLIST, tokens[3])
            elseif(tokens[2] == "BLOCK_CHASE_WHITELIST") then
                table.insert(BLOCK_CHASE_WHITELIST, tokens[3])
            elseif(tokens[2] == "DUMP_WHITELIST") then
                table.insert(DUMP_WHITELIST, tokens[3])
            end
        end

    elseif(tokens[1] == "REMOVE") then      -- remove value from table
        if(tokens[2] ~= nil and tokens[3] ~= nil) then
            if(tokens[2] == "BLOCK_ALERT_WHITELIST") then
                table.remove(BLOCK_ALERT_WHITELIST, indexOfInTable(BLOCK_ALERT_WHITELIST, tokens[3]))
            elseif(tokens[2] == "UNLOAD_BLACKLIST") then
                table.remove(UNLOAD_BLACKLIST, indexOfInTable(UNLOAD_BLACKLIST, tokens[3]))
            elseif(tokens[2] == "BLOCK_CHASE_WHITELIST") then
                table.remove(BLOCK_CHASE_WHITELIST, indexOfInTable(BLOCK_CHASE_WHITELIST, tokens[3]))
            elseif(tokens[2] == "DUMP_WHITELIST") then
                table.remove(DUMP_WHITELIST, indexOfInTable(DUMP_WHITELIST, tokens[3]))
            end
        end

    elseif(tokens[1] == "GET") then         -- get a value
        if(tokens[2] ~= nil) then
            if(tokens[2] == "FUEL") then
                transmitToMaster("FUEL " .. turtle.getFuelLevel())
            elseif(tokens[2] == "LOCATION") then
                local x, y, z = gps.locate(0.5)
                if(x ~= nil) then
                    transmitToMaster("LOCATION " .. x .. " " .. y .. " " .. z)
                else
                    print("Could not contact GPS")
                end
            elseif(tokens[2] == "OPERATION") then
                transmitToMaster("OPERATION " .. currentOperation)
            elseif(tokens[2] == "PLACE_TORCHES") then
                transmitToMaster("SETTING PLACE_TORCHES " .. tostring(PLACE_TORCHES))
            elseif(tokens[2] == "PLACE_CHESTS") then
                transmitToMaster("SETTING PLACE_CHESTS " .. tostring(PLACE_CHESTS))
            elseif(tokens[2] == "USE_ENDER_CHESTS") then
                transmitToMaster("SETTING USE_ENDER_CHESTS " .. tostring(USE_ENDER_CHESTS))
            elseif(tokens[2] == "BLOCK_ALERTS") then
                transmitToMaster("SETTING BLOCK_ALERTS " .. tostring(BLOCK_ALERTS))
            elseif(tokens[2] == "REPORT_STATISTICS") then
                transmitToMaster("SETTING REPORT_STATISTICS " .. tostring(REPORT_STATISTICS))
            elseif(tokens[2] == "AUTO_RETURN") then
                transmitToMaster("SETTING AUTO_RETURN " .. tostring(AUTO_RETURN))
            elseif(tokens[2] == "AUTO_REFUEL") then
                transmitToMaster("SETTING AUTO_REFUEL " .. tostring(AUTO_REFUEL))
            elseif(tokens[2] == "SNAKE_TUNNELS") then
                transmitToMaster("SETTING SNAKE_TUNNELS " .. tostring(SNAKE_TUNNELS))
            elseif(tokens[2] == "DUMP") then
                transmitToMaster("SETTING DUMP " .. tostring(DUMP))
            elseif(tokens[2] == "TORCH_INTERVAL") then
                transmitToMaster("SETTING TORCH_INTERVAL " .. tostring(TORCH_INTERVAL))
            elseif(tokens[2] == "MAX_TUNNEL_DISTANCE") then
                transmitToMaster("SETTING MAX_TUNNEL_DISTANCE " .. tostring(MAX_TUNNEL_DISTANCE))
            elseif(tokens[2] == "SNAKE_TUNNEL_SEPARATION") then
                transmitToMaster("SETTING SNAKE_TUNNEL_SEPARATION " .. tostring(SNAKE_TUNNEL_SEPARATION))
            elseif(tokens[2] == "BLOCK_ALERT_WHITELIST") then
                transmitToMaster("SETTING BLOCK_ALERT_WHITELIST " .. tableToString(BLOCK_ALERT_WHITELIST))
            elseif(tokens[2] == "UNLOAD_BLACKLIST") then
                transmitToMaster("SETTING UNLOAD_BLACKLIST " .. tableToString(UNLOAD_BLACKLIST))
            elseif(tokens[2] == "BLOCK_CHASE_WHITELIST") then
                transmitToMaster("SETTING BLOCK_CHASE_WHITELIST " .. tableToString(BLOCK_CHASE_WHITELIST))
            elseif(tokens[2] == "DUMP_WHITELIST") then
                transmitToMaster("SETTING DUMP_WHITELIST " .. tableToString(DUMP_WHITELIST))
            end
        end

    elseif(tokens[1] == "REFUEL") then      -- refuel requested
        local refuelAmount = 64

        -- get refuel amount if specified
        if(tokens[3] ~= nil) then
            refuelAmount = tonumber(tokens[3])
            if(refuelAmount == false) then
                refuelAmount = 64
            end
        end

        local coalSlot = getItemSlotWithItem("minecraft:coal")
        if(coalSlot ~= -1) then
            turtle.select(coalSlot)
            turtle.refuel(refuelAmount)
        end 

        transmitToMaster("FUEL " .. turtle.getFuelLevel())

    elseif(tokens[1] == "RESET") then       -- reset to default requested
        loadDefaultSettings()
        updateMemory()

    elseif(tokens[1] == "OPERATION") then   -- is an operation
        if(tokens[2] ~= nil) then
            -- parse out first token as operation, and set following tokens as parameters
            operationRestoredFromMemory = false
            currentOperation = tokens[2]
            table.remove(tokens, 2) -- remove operation parameter
            table.remove(tokens, 1) -- remove "OPERATION"
            currentOperationParameters = tokens
        end
    elseif(tokens[1] == "REENROL") then     -- master has requested reenrollment
        print("Reenrolling at master computer's request")
        isEnrolled = false

    elseif(tokens[1] == "APPROVED") then    -- master has approved enrollment
        print("Enrollment approved")
        isEnrolled = true
    elseif(tokens[1] == "DENIED") then      -- master has denied enrollment
        print("Enrollment denied")
        transmitToMaster("ENROL")
    end

    updateMemory()
end


-- ############### GENERIC FUNCTIONS ###############

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


-- ############### STATE SAVING & RESTORATION ###############

-- initialise program state from files
function initialiseFromMemory()
    
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

-- load default settings and save them to memory
function loadDefaultSettings()
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
    DUMP = true                     -- dump certain blocks (outlined by DUMP_WHITELIST) when mined
    BLOCK_ALERT_WHITELIST = {"minecraft:diamond_ore", "IC2:itemOreIridium"} -- item IDs that will result in alerts when encountered
    UNLOAD_BLACKLIST = {"minecraft:torch", "minecraft:chest", "enderstorage:ender_storage"} -- item IDs that will not be unloaded to chests
    BLOCK_CHASE_WHITELIST = {"minecraft:diamond_ore", "minecraft:iron_ore", "minecraft:coal_ore", "minecraft:redstone_ore"} -- item IDs that the turtle should "chase"
    DUMP_WHITELIST = {"minecraft:stone", "minecraft:dirt", "minecraft:cobblestone", "minecraft:sandstone"} -- item IDs that the turtle should dump

    -- global variables that dictate operations
    operationRestoredFromMemory = false
    currentOperation = ""
    currentOperationParameters = {}

    snakesMade = 0  -- number of times a tunnel has been snaked, used by return operation to get back to beginning of tunnel
    blocksTunneled = 0
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


-- ############### EVENT HANDLING ###############

-- outline what events and handlers should be mapped
function eventListener()
    listenForEvent({rednet_message=messageReceived, terminate=unenrol})
end

-- listen constantly for events and redirect them appropriately to the event handler
function listenForEvent(functionTbl)
    while currentOperation ~= "SHUTDOWN" do
        tbl = {os.pullEventRaw()}
        if type(functionTbl[tbl[1]]) == "function" then
            functionTbl[tbl[1]](select(2, unpack(tbl)))
        end
    end
end

-- run main function and event handling code simultaneously
parallel.waitForAll(main, eventListener, enrol)