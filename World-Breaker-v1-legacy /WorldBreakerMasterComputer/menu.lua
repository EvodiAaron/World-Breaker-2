local width, height = term.getSize()
local selectedMenuItemIndex = 1
local displayKeyboardSelection = false
local loadedMenu = nil
local menus = {}


function updateWindowSize()
	width, height = term.getSize()
end

-- return the bounds of the current menu
function getMenuBounds()
	local yStart = 1
	if(menus[loadedMenu].options.headerEnabled) then
		yStart = yStart + 1 + menus[loadedMenu].header.spacingFromTop
		if(menus[loadedMenu].header.drawLine) then
			yStart = yStart + 1 + menus[loadedMenu].header.spacingBetweenLine
		end
	end

	local yEnd = height
	if(menus[loadedMenu].options.footerEnabled) then
		yEnd = yEnd - 1 - menus[loadedMenu].footer.spacingFromBottom
		if(menus[loadedMenu].footer.drawLine) then
			yEnd = yEnd - 1 - menus[loadedMenu].footer.spacingBetweenLine
		end
	end

	return	{
		xStart = 1,
		xEnd = width,
		yStart = yStart,
		yEnd = yEnd
	}
end

-- print functions
local function printCenteredAt(str, xPos, yPos)
	xPos = xPos - (#str / 2)

	local bounds = getMenuBounds()
	if(xPos < bounds.xStart) then
		xPos = bounds.xStart
	elseif(xPos > bounds.xEnd) then
		xPos = bounds.xEnd
	end
	if(yPos < bounds.yStart) then
		yPos = bounds.yStart
	elseif(xPos > bounds.yEnd) then
		yPos = bounds.yEnd
	end

	term.setCursorPos(xPos, yPos)
	term.write(str)

	return {
		xStart = xPos, xEnd = xPos + #str,
		yStart = yPos, yEnd = yPos
	}
end
local function printLeftAt(str, xPos, yPos)
	local bounds = getMenuBounds()
	if(xPos < bounds.xStart) then
		xPos = bounds.xStart
	elseif(xPos > bounds.xEnd) then
		xPos = bounds.xEnd
	end
	if(yPos < bounds.yStart) then
		yPos = bounds.yStart
	elseif(xPos > bounds.yEnd) then
		yPos = bounds.yEnd
	end

	term.setCursorPos(xPos, yPos)
	term.write(str)

	return {
		xStart = xPos, xEnd = xPos + #str,
		yStart = yPos, yEnd = yPos
	}
end
local function printRightAt(str, xPos, yPos)
	xPos = xPos - #str

	local bounds = getMenuBounds()
	if(xPos < bounds.xStart) then
		xPos = bounds.xStart
	elseif(xPos > bounds.xEnd) then
		xPos = bounds.xEnd
	end
	if(yPos < bounds.yStart) then
		yPos = bounds.yStart
	elseif(xPos > bounds.yEnd) then
		yPos = bounds.yEnd
	end

	term.setCursorPos(xPos, yPos)
	term.write(str)

	return {
		xStart = xPos, xEnd = xPos + #str,
		yStart = yPos, yEnd = yPos
	}
end
local function printCentered(str, yPos)
	term.setCursorPos(width / 2 - #str / 2, yPos)
	term.write(str)
end
local function printLeft(str, yPos)
	term.setCursorPos(1, yPos)
	term.write(str)
end
local function printRight(str, yPos)
	term.setCursorPos(width - #str, yPos)
	term.write(str)
end

-- draw functions
local function drawHeader()
	term.setTextColor(menus[loadedMenu].header.colour)

	if(menus[loadedMenu].header.justification:upper() == "LEFT") then
		printLeft(menus[loadedMenu].header.text, menus[loadedMenu].header.spacingFromTop + 1)

	elseif(menus[loadedMenu].header.justification:upper() == "RIGHT") then
		printRight(menus[loadedMenu].header.text, menus[loadedMenu].header.spacingFromTop + 1)

	else
		printCentered(menus[loadedMenu].header.text, menus[loadedMenu].header.spacingFromTop + 1)
	end

	-- record hitbox
	menus[loadedMenu].header.hitbox = {
		xStart = 1, xEnd = width,
		yStart = 1, yEnd = menus[loadedMenu].header.spacingFromTop + 1
	}

	-- draw line
	if(menus[loadedMenu].header.drawLine) then
		printCentered(string.rep(menus[loadedMenu].header.lineCharacter, width), 2 + menus[loadedMenu].header.spacingFromTop + menus[loadedMenu].header.spacingBetweenLine)
		menus[loadedMenu].header.hitbox.yEnd = 2 + menus[loadedMenu].header.spacingFromTop + menus[loadedMenu].header.spacingBetweenLine
	end
end
local function drawFooter()
	term.setTextColor(menus[loadedMenu].footer.colour)

	if(menus[loadedMenu].footer.justification:upper() == "LEFT") then
		printLeft(menus[loadedMenu].footer.text, height - menus[loadedMenu].footer.spacingFromBottom)

	elseif(menus[loadedMenu].footer.justification:upper() == "RIGHT") then
		printRight(menus[loadedMenu].footer.text, height - menus[loadedMenu].footer.spacingFromBottom)

	else
		printCentered(menus[loadedMenu].footer.text, height - menus[loadedMenu].footer.spacingFromBottom)
	end

	-- record hitbox
	menus[loadedMenu].footer.hitbox = {
		xStart = 1, xEnd = width,
		yStart = height - menus[loadedMenu].footer.spacingFromBottom, yEnd = height
	}

	-- draw line
	if(menus[loadedMenu].footer.drawLine) then
		printCentered(string.rep(menus[loadedMenu].footer.lineCharacter, width), height - 1  - menus[loadedMenu].footer.spacingFromBottom - menus[loadedMenu].footer.spacingBetweenLine)
		menus[loadedMenu].footer.hitbox.yStart = height - 1  - menus[loadedMenu].footer.spacingFromBottom - menus[loadedMenu].footer.spacingBetweenLine
	end
end
local function drawMenuItems()
	local yPos = menus[loadedMenu].options.verticalItemSpacing + 1
	
	-- determine start y position based on header if enabled
	if(menus[loadedMenu].options.headerEnabled) then
		yPos = yPos + 1 + menus[loadedMenu].header.spacingFromTop
		if(menus[loadedMenu].header.drawLine) then
			yPos = yPos + 1 + menus[loadedMenu].header.spacingBetweenLine
		end
	end

	local completedDraw = false
	local index = 1
	while not completedDraw do

		completedDraw = true

		-- iterate through all menu items and print the one that is to be displayed at this index
		for item, options in pairs(menus[loadedMenu].items) do
			if(options.index == index) then
				completedDraw = false

				term.setTextColor(options.colour)
	
				local itemText = item
		
				if(index == selectedMenuItemIndex and displayKeyboardSelection) then
					itemText = menus[loadedMenu].options.selectedItemLeftString .. item .. menus[loadedMenu].options.selectedItemRightString
				end
		
				printCentered(itemText, yPos)
		
				-- update hitbox
				menus[loadedMenu].items[item].hitbox = {
					xStart = width / 2 - #itemText / 2, xEnd = (width / 2 - #itemText / 2) + #itemText,
					yStart = yPos, yEnd = yPos
				}		
			end
		end

		yPos = yPos + 1 + menus[loadedMenu].options.verticalItemSpacing
		index = index + 1
	end

end
local function drawCustomPoints()
	for customPoint, options in pairs(menus[loadedMenu].customPoints) do
		term.setTextColor(options.colour)

		local justification = options.justification:upper()
		if(justification == "LEFT") then
			menus[loadedMenu].customPoints[customPoint].hitbox = printLeftAt(customPoint, options.x, options.y)
		elseif(justification == "RIGHT") then
			menus[loadedMenu].customPoints[customPoint].hitbox = printRightAt(customPoint, options.x, options.y)
		else
			menus[loadedMenu].customPoints[customPoint].hitbox = printCenteredAt(customPoint, options.x, options.y)
		end
    end	
end
function draw()
	if(loadedMenu ~= nil) then
		term.setBackgroundColor(menus[loadedMenu].options.backgroundColour)
		term.clear()

		if(menus[loadedMenu].options.headerEnabled) then
			drawHeader()
		end

		if(menus[loadedMenu].options.menuItemsEnabled) then
			drawMenuItems()
		end

		if(menus[loadedMenu].options.customPointsEnabled) then
			drawCustomPoints()
		end

		if(menus[loadedMenu].options.footerEnabled) then
			drawFooter()
		end

		term.setCursorBlink(false)

		return true
	else
		return false
	end
end

-- menu management functions
function load(menu)
	loadedMenu = menu
end
function getLoaded()
	return loadedMenu
end
function unload()
	loadedMenu = nil
	term.clear()
end
function getData()
	return menus[loadedMenu]
end

-- keyboard selection
function getSelectedMenuItem()
	if(loadedMenu ~= nil) then
		for item, options in pairs(menus[loadedMenu].items) do
			if(options.index == selectedMenuItemIndex) then
				return item
			end
		end
	end
end
function incrementSelectedMenuItem(index)
	if(loadedMenu ~= nil) then
		local itemCount = 0
		for item, options in pairs(menus[loadedMenu].items) do
			itemCount = itemCount + 1
        end

		if(selectedMenuItemIndex < itemCount) then
			selectedMenuItemIndex = selectedMenuItemIndex + 1
		draw()
		end
	end
end
function decrementSelectedMenuItem(index)
	if(loadedMenu ~= nil) then

		if(selectedMenuItemIndex > 1) then
			selectedMenuItemIndex = selectedMenuItemIndex - 1
			draw()
		end
	end
end
function showKeyboardSelection()
	displayKeyboardSelection = true
	draw()
end
function hideKeyboardSelection()
	displayKeyboardSelection = false
	draw()
end
function isKeyboardSelectionHidden()
	return not displayKeyboardSelection
end

-- menu creation

-- creates menu with default options
function create(menuID)
	menus[menuID] = {
		options = {
			headerEnabled = false,
			footerEnabled = false,
			menuItemsEnabled = false,
			customPointsEnabled = false,
			backgroundColour = 32768,
			verticalItemSpacing = 1,
			selectedItemLeftString = "> ",
			selectedItemRightString = " <"
		},
		header = {
			text = menuID,
			justification = "CENTER",
			colour = 1,
			drawLine = true,
			lineCharacter = "-",
			spacingBetweenLine = 0,
			spacingFromTop = 0,
			hitbox = nil
		},
		footer = {
			text = "<Exit>",
			justification = "LEFT",
			colour = 1,
			drawLine = true,
			lineCharacter = "-",
			spacingBetweenLine = 0,
			spacingFromBottom = 0,
			hitbox = nil
		},
		items = {},
		customPoints = {}
	}
end

-- update menu.options functions
function enableHeader()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.headerEnabled = true
		return true
	else
		return false
	end
end
function enableFooter()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.footerEnabled = true
		return true
	else
		return false
	end
end
function enableMenuItems()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.menuItemsEnabled = true
		return true
	else
		return false
	end
end
function enableCustomPoints()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.customPointsEnabled = true
		return true
	else
		return false
	end
end
function disableHeader()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.headerEnabled = false
		return true
	else
		return false
	end
end
function disableFooter()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.footerEnabled = false
		return true
	else
		return false
	end
end
function disableMenuItems()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.menuItemsEnabled = false
		return true
	else
		return false
	end
end
function disableCustomPoints()
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.customPointsEnabled = false
		return true
	else
		return false
	end
end
function setBackgroundColour(colour)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.backgroundColour = colour
		return true
	else
		return false
	end
end
function setVerticalItemSpacing(spacing)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.verticalItemSpacing = spacing
		return true
	else
		return false
	end
end
function setSelectedItemLeftString(str)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.selectedItemLeftString = str
		return true
	else
		return false
	end
end
function setSelectedItemRightString(str)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].options.selectedItemRightString = str
		return true
	else
		return false
	end
end

-- update menu.header functions
function setHeaderText(text)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].header.text = text
		return true
	else
		return false
	end
end
function setHeaderJustification(justification)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].header.justification = justification
		return true
	else
		return false
	end
end
function setHeaderColour(colour)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].header.colour = colour
		return true
	else
		return false
	end
end
function setHeaderDrawLine(drawLine)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].header.drawLine = drawLine
		return true
	else
		return false
	end
end
function setHeaderLineCharacter(lineCharacter)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].header.lineCharacter = lineCharacter
		return true
	else
		return false
	end
end
function setHeaderSpacingBetweenLine(spacingBetweenLine)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].header.spacingBetweenLine = spacingBetweenLine
		return true
	else
		return false
	end
end
function setHeaderSpacingFromTop(spacingFromTop)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].header.spacingFromTop = spacingFromTop
		return true
	else
		return false
	end
end

-- update menu.footer functions
function setFooterText(text)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].footer.text = text
		return true
	else
		return false
	end
end
function setFooterJustification(justification)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].footer.justification = justification
		return true
	else
		return false
	end
end
function setFooterColour(colour)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].footer.colour = colour
		return true
	else
		return false
	end
end
function setFooterDrawLine(drawLine)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].footer.drawLine = drawLine
		return true
	else
		return false
	end
end
function setFooterLineCharacter(lineCharacter)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].footer.lineCharacter = lineCharacter
		return true
	else
		return false
	end
end
function setFooterSpacingBetweenLine(spacingBetweenLine)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].footer.spacingBetweenLine = spacingBetweenLine
		return true
	else
		return false
	end
end
function setFooterSpacingFromBottom(spacingFromBottom)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].footer.spacingFromBottom = spacingFromBottom
		return true
	else
		return false
	end
end

-- update menu.items functions
function upsertMenuItem(itemName, colour)
	if(loadedMenu ~= nil) then
		if(colour == nil) then
			colour = 1
		end

		local index = 1
		for item, options in pairs(menus[loadedMenu].items) do
			index = index + 1
		end

		menus[loadedMenu].items[itemName] = {
			index = index,
			colour = colour,
			hitbox = nil
		}
		return true
	else
		return false
	end
end
function removeMenuItem(itemName)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].items[itemName] = nil
		return true
	else
		return false
	end
end

-- update menu.customPoints functions
function upsertCustomPoint(customPoint, xPos, yPos, justification, colour)
	if(loadedMenu ~= nil) then
		if(colour == nil) then
			colour = 1
		end

		if(justification == nil) then
			justification = "CENTER"
		end

		menus[loadedMenu].customPoints[customPoint] = {
			x = xPos,
			y = yPos,
			colour = colour,
			justification = justification,
			hitbox = nil
		}
		return true
	else
		return false
	end
end
function removeCustomPoint(customPoint)
	if(loadedMenu ~= nil) then
		menus[loadedMenu].customPoints[customPoint] = nil
		return true
	else
		return false
	end
end