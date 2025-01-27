--[[
    DCS Mission Script: Cruise Missile Management with Accurate TTI Tracking
    Description:
        - Detects cruise missile-capable ships for BLUE and RED coalitions.
        - Provides F10 menu commands to fire missiles at designated markers.
        - Tracks each missile's Time to Impact (TTI) based on real-time speed.
        - Displays indexed TTI messages for each missile every 10 seconds.
--]]

-- ============================
-- Configuration Variables
-- ============================

local maxMissilesPerShip = 22          -- Total missile inventory per ship
local maxSimultaneousLaunches = 10     -- Maximum simultaneous launches per ship
local markerPrefix = "NSGT"            -- Prefix for map markers (e.g., NSGT1, NSGT2, etc.)
local ttiUpdateInterval = 10           -- Seconds between TTI updates

-- Define missile types for each coalition
local blueMissiles = { "BGM_109" }     -- List of missile types BLUE coalition can launch
local redMissiles = { "3M-54" }        -- List of missile types RED coalition can launch

-- ============================
-- Data Structures
-- ============================

local shipData = {
    [coalition.side.BLUE] = {},       -- Tracks BLUE coalition ships
    [coalition.side.RED] = {}         -- Tracks RED coalition ships
}

local trackedMissiles = {}            -- Tracks fired missiles, keyed by weapon identifier
local missileIndex = 0                 -- Counter for assigning unique missile IDs

-- ============================
-- Helper Functions
-- ============================

-- Function to detect ships capable of firing cruise missiles
local function detectCruiseMissileShips()
    -- Iterate over each coalition (BLUE and RED)
    for coalitionID, coalitionName in pairs({
        [coalition.side.BLUE] = "BLUE",
        [coalition.side.RED] = "RED"
    }) do
        local detectedShips = {}        -- Temporary table to store detected ships for this coalition
        local allGroups = coalition.getGroups(coalitionID, Group.Category.NAVAL) -- Get all naval groups for the coalition

        -- Iterate through each naval group
        for _, group in ipairs(allGroups) do
            local groupUnits = group:getUnits() -- Get all units in the group

            -- Iterate through each unit in the group
            for _, unit in ipairs(groupUnits) do
                if unit and unit:isExist() and unit:isActive() then -- Ensure the unit exists and is active
                    local unitAmmo = unit:getAmmo() -- Retrieve the unit's ammunition loadout

                    if unitAmmo then
                        -- Check each ammo type the unit has
                        for _, ammo in ipairs(unitAmmo) do
                            if ammo.desc then
                                -- Determine the missile type list based on the coalition
                                local missileTypeList = (coalitionID == coalition.side.BLUE) and blueMissiles or redMissiles
                                
                                -- Check if the ammo type matches any of the coalition's missile types
                                for _, missileType in ipairs(missileTypeList) do
                                    if ammo.desc.typeName and ammo.desc.typeName:find(missileType) then
                                        -- Store ship information if a matching missile type is found
                                        detectedShips[unit:getName()] = {
                                            name = unit:getName(),
                                            inventory = maxMissilesPerShip,
                                            unit = unit,
                                            launchQueue = {} -- Initialize launch queue for target mapping
                                        }
                                        break -- Move to the next unit after detecting a missile type
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Update the main shipData table with detected ships for the current coalition
        shipData[coalitionID] = detectedShips
    end
end

-- Function to check and display the status of a specific ship
local function checkShipStatus(shipName, coalitionID)
    local shipInfo = shipData[coalitionID][shipName]
    if not shipInfo or not shipInfo.unit or not shipInfo.unit:isExist() then
        trigger.action.outText("Ship " .. shipName .. " is not available for tasking.", 10)
        return
    end

    -- Display the ship's online status and remaining missile inventory
    trigger.action.outText(
        string.format("Ship %s is online. Missile Inventory: %d remaining.", shipName, shipInfo.inventory),
        10
    )
end

-- Function to update and display the Time to Impact (TTI) for a missile
local function updateMissileTTI(args, time, unused)
    local weaponKey = args[1] -- Extract weapon identifier from args table
    local missileInfo = trackedMissiles[weaponKey]
    
    if not missileInfo then
        -- Missile tracking info not found; possibly already reached target or destroyed
        return
    end

    local missile = missileInfo.weapon
    local targetPos = missileInfo.targetPos

    -- Ensure the missile exists
    if not missile or not missile:isExist() then
        trigger.action.outText(string.format("Missile %d: No longer exists.", missileInfo.missileID), 10)
        trackedMissiles[weaponKey] = nil
        return
    end

    -- Get missile's current position and velocity
    local missilePos = missile:getPoint()
    local velocity = missile:getVelocity()
    
    if not velocity then
        trigger.action.outText(string.format("Missile %d: Unable to retrieve velocity.", missileInfo.missileID), 10)
        trackedMissiles[weaponKey] = nil
        return
    end

    -- Calculate the direction vector from missile to target
    local direction = {
        x = targetPos.x - missilePos.x,
        y = targetPos.y - missilePos.y,
        z = targetPos.z - missilePos.z
    }
    local distance = math.sqrt(direction.x^2 + direction.y^2 + direction.z^2)

    if distance == 0 then
        -- Missile has reached its target
        trigger.action.outText(string.format("Missile %d: Has reached its target.", missileInfo.missileID), 10)
        trackedMissiles[weaponKey] = nil
        return
    end

    -- Normalize the direction vector
    direction.x = direction.x / distance
    direction.y = direction.y / distance
    direction.z = direction.z / distance

    -- Calculate relative velocity towards target using dot product
    local relativeVelocity = velocity.x * direction.x + velocity.y * direction.y + velocity.z * direction.z

    if relativeVelocity > 0 then
        -- Calculate Time to Impact (TTI)
        local tti = distance / relativeVelocity
        trigger.action.outText(string.format("Missile %d: TTI %.1f seconds", missileInfo.missileID, tti), 10)

        -- Schedule the next TTI update
        timer.scheduleFunction(updateMissileTTI, { weaponKey }, timer.getTime() + ttiUpdateInterval)
    else
        -- Unable to calculate TTI if relative velocity is not positive
        trigger.action.outText(string.format("Missile %d: Unable to calculate TTI.", missileInfo.missileID), 10)
        trackedMissiles[weaponKey] = nil
    end
end

-- Function to start tracking TTI for a specific missile
local function trackMissileTTI(missile, missileID, targetPos)
    local weaponKey = tostring(missile) -- Unique identifier for the weapon

    -- Store missile tracking information
    trackedMissiles[weaponKey] = {
        missileID = missileID,
        weapon = missile,
        targetPos = targetPos
    }

    -- Schedule the first TTI update
    timer.scheduleFunction(updateMissileTTI, { weaponKey }, timer.getTime() + ttiUpdateInterval)
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

    -- Gather all valid markers with the specified prefix
    local markerList = world.getMarkPanels()
    local markers = {}
    for _, markerData in pairs(markerList) do
        local markerName = markerData.text:upper()
        if markerName:match("^" .. markerPrefix .. "%d+$") then -- Match markers like NSGT1, NSGT2, etc.
            table.insert(markers, { id = markerData.idx, pos = markerData.pos })
        end
    end

    if #markers == 0 then
        trigger.action.outText("No valid " .. markerPrefix .. " markers found for " .. shipName .. ".", 10)
        return
    end

    -- Determine the number of missiles to fire based on available markers, inventory, and launch limits
    local missilesToFire = math.min(#markers, shipInfo.inventory, maxSimultaneousLaunches)
    shipInfo.inventory = shipInfo.inventory - missilesToFire

    local controller = shipInfo.unit:getController()

    for i = 1, missilesToFire do
        local marker = markers[i]
        local targetPos = marker.pos

        -- Enqueue target position for this ship to map with missile launches
        table.insert(shipInfo.launchQueue, targetPos)

        -- Create the fire task specifying the target point
        local fireTask = {
            id = 'FireAtPoint',
            params = {
                x = targetPos.x,
                y = targetPos.z, -- Note: In DCS, 'y' in FireAtPoint represents the Z-axis
                radius = 100,     -- Target radius for missile impact
                expendQty = 1,    -- Number of missiles to expend
                expendQtyEnabled = true, -- Enable expend quantity
            },
        }

        -- Push the fire task to the ship's controller to execute the missile launch
        controller:pushTask(fireTask)
    end

    -- Inform the user about the missile launch
    trigger.action.outText(
        string.format("Ship %s launched %d missiles. %d remaining.", shipName, missilesToFire, shipInfo.inventory),
        10
    )

    -- Remove the markers after firing to prevent re-use
    for _, marker in ipairs(markers) do
        trigger.action.removeMark(marker.id)
    end
end

-- ============================
-- Event Handling
-- ============================

-- Event handler to detect missile launches and initiate TTI tracking
local missileEventHandler = {
    onEvent = function(self, event)
        if event.id == world.event.S_EVENT_SHOT then
            local initiator = event.initiator
            local weapon = event.weapon

            -- Ensure the initiator is a valid unit
            if initiator and initiator:getCategory() == Object.Category.UNIT then
                local initiatorName = initiator:getName()
                local coalitionID = initiator:getCoalition()

                -- Check if the initiator is a tracked ship with missile capabilities
                local shipInfo = shipData[coalitionID][initiatorName]
                if shipInfo then
                    -- Assign a unique missile ID
                    missileIndex = missileIndex + 1
                    local missileID = missileIndex

                    -- Dequeue the target position from the ship's launchQueue (Last-In-First-Out)
                    local targetPos = table.remove(shipInfo.launchQueue, #shipInfo.launchQueue)
                    if not targetPos then
                        trigger.action.outText(string.format("Missile %d: No target position found for tracking.", missileID), 10)
                        return
                    end

                    -- Start tracking TTI for the launched missile
                    trackMissileTTI(weapon, missileID, targetPos)

                    -- Display a message about the missile launch
                    trigger.action.outText(
                        string.format("Ship %s fired Missile %d.", initiatorName, missileID),
                        10
                    )
                end
            end
        end
    end
}

-- ============================
-- Menu Creation
-- ============================

-- Function to create F10 menu commands for each coalition and their ships
local function createCoalitionMenus()
    for coalitionID, coalitionName in pairs({
        [coalition.side.BLUE] = "BLUE",
        [coalition.side.RED] = "RED"
    }) do
        -- Create a root submenu for the Navy Strike Group under each coalition
        local rootMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Navy Strike Group")

        -- Iterate through each detected ship in the coalition
        for shipName, shipInfo in pairs(shipData[coalitionID]) do
            -- Create a submenu for each ship under the Navy Strike Group menu
            local shipMenu = missionCommands.addSubMenuForCoalition(coalitionID, shipName, rootMenu)

            -- Add a "Check Status" command to display the ship's status
            missionCommands.addCommand(
                "Check Status",
                shipMenu,
                function()
                    checkShipStatus(shipName, coalitionID)
                end
            )

            -- Add a "Fire Cruise Missiles" command to initiate missile launches
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

-- ============================
-- Main Initialization Function
-- ============================

-- Main function to initialize the mission script
local function main()
    detectCruiseMissileShips()      -- Detect all cruise missile-capable ships at mission start
    createCoalitionMenus()          -- Create F10 menu commands for user interaction
    world.addEventHandler(missileEventHandler) -- Register the missile event handler to listen for missile launch events
end

-- ============================
-- Script Entry Point
-- ============================

-- Execute the main initialization function
main()
