local maxMissilesPerShip = 22 -- Total missile inventory per ship
local maxSimultaneousLaunches = 10 -- Max simultaneous launches per ship
local markerPrefix = "NSGT" -- Prefix for map markers (e.g., NSGT1, NSGT2, etc.)
local shipData = { [coalition.side.BLUE] = {}, [coalition.side.RED] = {} } -- Track ships by coalition

-- Function to detect ships capable of firing cruise missiles
local function detectCruiseMissileShips()
    for coalitionID, coalitionName in pairs({ [coalition.side.BLUE] = "BLUE", [coalition.side.RED] = "RED" }) do
        local detectedShips = {}
        local allGroups = coalition.getGroups(coalitionID, Group.Category.NAVAL)

        for _, group in ipairs(allGroups) do
            local groupUnits = group:getUnits()
            for _, unit in ipairs(groupUnits) do
                if unit and unit:isExist() and unit:isActive() then
                    local unitAmmo = unit:getAmmo()
                    if unitAmmo then
                        for _, ammo in ipairs(unitAmmo) do
                            if ammo.desc then
                                local cruiseMissileType = coalitionID == coalition.side.BLUE and "BGM_109" or "3M-54"
                                if ammo.desc.typeName and ammo.desc.typeName:find(cruiseMissileType) then
                                    detectedShips[unit:getName()] = {
                                        name = unit:getName(),
                                        inventory = maxMissilesPerShip,
                                        unit = unit,
                                    }
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        shipData[coalitionID] = detectedShips
    end
end

-- Function to fire cruise missiles from a specific ship
local function fireCruiseMissiles(shipName, coalitionID)
    local shipInfo = shipData[coalitionID][shipName]
    if not shipInfo or not shipInfo.unit or not shipInfo.unit:isExist() then
        trigger.action.outText("Ship " .. shipName .. " is not available for tasking.", 10)
        return
    end

    if shipInfo.inventory <= 0 then
        trigger.action.outText("No missiles remaining on " .. shipName .. ".", 10)
        return
    end

    local markerList = world.getMarkPanels()
    local markers = {}
    for _, markerData in pairs(markerList) do
        local markerName = markerData.text:upper()
        if markerName:match("^" .. markerPrefix .. "%d+$") then -- Match markers with the specified prefix
            table.insert(markers, { id = markerData.idx, pos = markerData.pos })
        end
    end

    if #markers == 0 then
        trigger.action.outText("No valid " .. markerPrefix .. " markers found for " .. shipName .. ".", 10)
        return
    end

    local missilesToFire = math.min(#markers, shipInfo.inventory, maxSimultaneousLaunches)
    shipInfo.inventory = shipInfo.inventory - missilesToFire

    local controller = shipInfo.unit:getController()

    for i = 1, missilesToFire do
        local marker = markers[i]
        local targetPos = marker.pos

        -- Create the fire task
        local fireTask = {
            id = 'FireAtPoint',
            params = {
                x = targetPos.x,
                y = targetPos.z,
                radius = 100,
                expendQty = 1,
                expendQtyEnabled = true,
            },
        }

        -- Push the fire task to the controller
        controller:pushTask(fireTask)
    end

    trigger.action.outText(
        string.format("Ship %s launched %d missiles. %d remaining.", shipName, missilesToFire, shipInfo.inventory),
        10
    )

    -- Remove the markers
    for _, marker in ipairs(markers) do
        trigger.action.removeMark(marker.id)
    end
end

-- Function to check the status of a specific ship
local function checkShipStatus(shipName, coalitionID)
    local shipInfo = shipData[coalitionID][shipName]
    if not shipInfo or not shipInfo.unit or not shipInfo.unit:isExist() then
        trigger.action.outText("Ship " .. shipName .. " is not available for tasking.", 10)
        return
    end

    trigger.action.outText(
        string.format("Ship %s is online. Missile Inventory: %d remaining.", shipName, shipInfo.inventory),
        10
    )
end

-- Function to create F10 menu commands for each coalition
local function createCoalitionMenus()
    for coalitionID, coalitionName in pairs({ [coalition.side.BLUE] = "BLUE", [coalition.side.RED] = "RED" }) do
        -- Root menu for the mod name
        local rootMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Navy Strike Group")

        for shipName, shipInfo in pairs(shipData[coalitionID]) do
            -- Create a submenu for each ship under the coalition root menu
            local shipMenu = missionCommands.addSubMenuForCoalition(coalitionID, shipName, rootMenu)

            -- Add "Check Status" command directly under the ship submenu
            missionCommands.addCommand(
                "Check Status",
                shipMenu,
                function()
                    checkShipStatus(shipName, coalitionID)
                end
            )

            -- Add "Fire Cruise Missiles" command directly under the ship submenu
            missionCommands.addCommand(
                "Fire Cruise Missiles",
                shipMenu,
                function()
                    fireCruiseMissiles(shipName, coalitionID)
                end
            )
        end
    end
end

-- Initialize the mod
do
    detectCruiseMissileShips()
    createCoalitionMenus()
end
