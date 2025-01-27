--[[
    DCS Mission Script: Optimized Cruise Missile Management with Accurate TTI Tracking
    Description:
        - Detects cruise missile-capable ships for BLUE and RED coalitions.
        - Provides F10 menu commands to fire missiles at designated markers.
        - Tracks each missile's Time to Impact (TTI) based on real-time speed.
        - Displays indexed TTI messages for each missile every 10 seconds to the respective coalition.
    Optimizations:
        - Improved performance by minimizing redundant operations.
        - Enhanced maintainability through modular functions and clear structure.
        - Simplified logic by using separate variables and missile type lists.
        - Renamed event handler for better clarity.
        - Updated missile launch radius to 1 for precise targeting.
        - Renamed the main initialization function from init() to main().
--]]

-- =======================
-- Configuration Variables
-- =======================

-- Missile Inventory and Launch Settings
local MAX_MISSILES_PER_SHIP = 22          -- Total missile inventory per ship
local MAX_SIMULTANEOUS_LAUNCHES = 10      -- Max simultaneous launches per ship

-- Marker Settings
local MARKER_PREFIX = "NSGT"              -- Prefix for map markers (e.g., NSGT1, NSGT2, etc.)

-- TTI Tracking
local TTI_UPDATE_INTERVAL = 10            -- Seconds between TTI updates

-- Missile Types per Coalition
local BLUE_MISSILE_TYPES = { "BGM_109" }  -- Actual missile types for BLUE coalition
local RED_MISSILE_TYPES = { "3M-54" }     -- Actual missile types for RED coalition

-- Message Settings
local MESSAGE_DURATION = 10               -- Duration for outTextForCoalition messages

-- =======================
-- Data Structures
-- =======================

local shipData = { [coalition.side.BLUE] = {}, [coalition.side.RED] = {} } -- Track ships by coalition
local trackedMissiles = {} -- Table to track fired missiles, keyed by weapon identifier
local missileIndex = 0     -- Counter for indexing missiles

-- =======================
-- Utility Functions
-- =======================

-- Utility to send messages to a specific coalition
local function sendCoalitionMessage(coalitionID, message)
    if coalitionID and message then
        trigger.action.outTextForCoalition(coalitionID, message, MESSAGE_DURATION)
    end
end

-- Utility to retrieve valid markers based on prefix
local function getValidMarkers()
    local markers = {}
    local markerList = world.getMarkPanels()
    local prefixPattern = "^" .. MARKER_PREFIX .. "%d+$"

    for _, markerData in pairs(markerList) do
        if markerData.text and markerData.text:upper():match(prefixPattern) then
            table.insert(markers, { id = markerData.idx, pos = markerData.pos })
        end
    end

    return markers
end

-- Utility to calculate distance between two points
local function calculateDistance(pos1, pos2)
    local dx = pos2.x - pos1.x
    local dy = pos2.y - pos1.y
    local dz = pos2.z - pos1.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- =======================
-- Core Functionalities
-- =======================

-- Function to detect cruise missile-capable ships
local function detectCruiseMissileShips()
    local missileTypes = {
        [coalition.side.BLUE] = BLUE_MISSILE_TYPES,
        [coalition.side.RED] = RED_MISSILE_TYPES
    }

    for coalitionID, types in pairs(missileTypes) do
        local detectedShips = {}
        local navalGroups = coalition.getGroups(coalitionID, Group.Category.NAVAL)

        for _, group in ipairs(navalGroups) do
            for _, unit in ipairs(group:getUnits()) do
                if unit and unit:isExist() and unit:isActive() then
                    local unitAmmo = unit:getAmmo()
                    if unitAmmo then
                        for _, ammo in ipairs(unitAmmo) do
                            if ammo.desc and ammo.desc.typeName then
                                for _, missileType in ipairs(types) do
                                    if ammo.desc.typeName:find(missileType) then
                                        local unitName = unit:getName()
                                        if not detectedShips[unitName] then
                                            detectedShips[unitName] = {
                                                name = unitName,
                                                inventory = MAX_MISSILES_PER_SHIP,
                                                unit = unit,
                                                launchQueue = {} -- Initialize launch queue for target mapping
                                            }
                                        end
                                        break -- Found a matching missile type, no need to check further
                                    end
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

-- Function to check the status of a specific ship
local function checkShipStatus(shipName, coalitionID)
    local shipInfo = shipData[coalitionID][shipName]
    if not shipInfo or not shipInfo.unit or not shipInfo.unit:isExist() then
        sendCoalitionMessage(coalitionID, "Ship " .. shipName .. " is not available for tasking.")
        return
    end

    local statusMessage = string.format("Ship %s is online. Missile Inventory: %d remaining.", shipName, shipInfo.inventory)
    sendCoalitionMessage(coalitionID, statusMessage)
end

-- Function to track TTI for a specific missile
local function trackMissileTTI(weapon, missileID, targetPos, coalitionID)
    local weaponKey = tostring(weapon) -- Unique identifier for the weapon

    -- Store missile tracking information, including coalitionID
    trackedMissiles[weaponKey] = {
        missileID = missileID,
        weapon = weapon,
        targetPos = targetPos,
        coalitionID = coalitionID
    }

    -- Schedule the first TTI update
    timer.scheduleFunction(updateMissileTTI, { weaponKey }, timer.getTime() + TTI_UPDATE_INTERVAL)
end

-- Global Function to update TTI for missiles
function updateMissileTTI(args, time, unused)
    local weaponKey = args[1]
    local missileInfo = trackedMissiles[weaponKey]

    if not missileInfo then return end -- Missile tracking info not found

    local missile = missileInfo.weapon
    local targetPos = missileInfo.targetPos
    local coalitionID = missileInfo.coalitionID

    if not (missile and missile:isExist()) then
        sendCoalitionMessage(coalitionID, string.format("Missile %d: No longer exists.", missileInfo.missileID))
        trackedMissiles[weaponKey] = nil
        return
    end

    local missilePos = missile:getPoint()
    local velocity = missile:getVelocity()

    if not velocity then
        sendCoalitionMessage(coalitionID, string.format("Missile %d: Unable to retrieve velocity.", missileInfo.missileID))
        trackedMissiles[weaponKey] = nil
        return
    end

    local distance = calculateDistance(missilePos, targetPos)

    if distance == 0 then
        sendCoalitionMessage(coalitionID, string.format("Missile %d: Has reached its target.", missileInfo.missileID))
        trackedMissiles[weaponKey] = nil
        return
    end

    -- Calculate relative velocity towards target
    local direction = {
        x = (targetPos.x - missilePos.x) / distance,
        y = (targetPos.y - missilePos.y) / distance,
        z = (targetPos.z - missilePos.z) / distance
    }
    local relativeVelocity = velocity.x * direction.x + velocity.y * direction.y + velocity.z * direction.z

    if relativeVelocity > 0 then
        local tti = distance / relativeVelocity
        sendCoalitionMessage(coalitionID, string.format("Missile %d: TTI %.1f seconds", missileInfo.missileID, tti))

        -- Schedule the next TTI update
        timer.scheduleFunction(updateMissileTTI, { weaponKey }, timer.getTime() + TTI_UPDATE_INTERVAL)
    else
        sendCoalitionMessage(coalitionID, string.format("Missile %d: Unable to calculate TTI.", missileInfo.missileID))
        trackedMissiles[weaponKey] = nil
    end
end

-- Function to fire cruise missiles from a specific ship
local function fireCruiseMissiles(shipName, coalitionID)
    local shipInfo = shipData[coalitionID][shipName]
    if not shipInfo or not shipInfo.unit or not shipInfo.unit:isExist() then
        sendCoalitionMessage(coalitionID, "Ship " .. shipName .. " is not available for tasking.")
        return
    end

    if shipInfo.inventory <= 0 then
        sendCoalitionMessage(coalitionID, "No missiles remaining on " .. shipName .. ".")
        return
    end

    local markers = getValidMarkers()

    if #markers == 0 then
        sendCoalitionMessage(coalitionID, "No valid " .. MARKER_PREFIX .. " markers found for " .. shipName .. ".")
        return
    end

    -- Determine number of missiles to fire
    local missilesToFire = math.min(#markers, shipInfo.inventory, MAX_SIMULTANEOUS_LAUNCHES)
    shipInfo.inventory = shipInfo.inventory - missilesToFire

    local controller = shipInfo.unit:getController()
    local launchQueue = shipInfo.launchQueue

    for i = 1, missilesToFire do
        local marker = markers[i]
        local targetPos = marker.pos

        -- Enqueue target position for tracking
        table.insert(launchQueue, targetPos)

        -- Create and push the fire task with updated radius
        controller:pushTask({
            id = 'FireAtPoint',
            params = {
                x = targetPos.x,
                y = targetPos.z, -- In DCS, 'y' in FireAtPoint corresponds to the Z-axis
                radius = 1,       -- Updated radius for precise targeting
                expendQty = 1,
                expendQtyEnabled = true,
            },
        })
    end

    -- Inform the coalition about the launch
    sendCoalitionMessage(coalitionID, string.format("Ship %s launched %d missiles. %d remaining.", shipName, missilesToFire, shipInfo.inventory))

    -- Remove the markers after firing
    for i = 1, missilesToFire do
        trigger.action.removeMark(markers[i].id)
    end
end

-- =======================
-- Event Handlers
-- =======================

-- Event Handler to detect missile launches
local function handleMissileLaunchEvent(event)
    if event.id ~= world.event.S_EVENT_SHOT then return end

    local initiator = event.initiator
    local weapon = event.weapon

    if not (initiator and initiator:getCategory() == Object.Category.UNIT) then return end

    local initiatorName = initiator:getName()
    local coalitionID = initiator:getCoalition()

    local shipInfo = shipData[coalitionID][initiatorName]
    if not shipInfo then return end -- Initiator is not a tracked ship

    -- Assign a unique missile ID
    missileIndex = missileIndex + 1
    local missileID = missileIndex

    -- Dequeue the target position from the ship's launchQueue (LIFO)
    local targetPos = table.remove(shipInfo.launchQueue, #shipInfo.launchQueue)
    if not targetPos then
        sendCoalitionMessage(coalitionID, string.format("Missile %d: No target position found for tracking.", missileID))
        return
    end

    -- Track TTI for the missile
    trackMissileTTI(weapon, missileID, targetPos, coalitionID)

    -- Display a message about the launch
    sendCoalitionMessage(coalitionID, string.format("Ship %s fired Missile %d.", initiatorName, missileID))
end

-- Register the Event Handler
world.addEventHandler({ handleMissileLaunchEvent = handleMissileLaunchEvent })

-- =======================
-- F10 Menu Commands
-- =======================

-- Function to create F10 menu commands for each coalition
local function createCoalitionMenus()
    local missileTypes = {
        [coalition.side.BLUE] = BLUE_MISSILE_TYPES,
        [coalition.side.RED] = RED_MISSILE_TYPES
    }

    for coalitionID, _ in pairs(missileTypes) do
        -- Root menu for the mod
        local rootMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Navy Strike Group")

        for shipName, _ in pairs(shipData[coalitionID]) do
            -- Create a submenu for each ship under the coalition root menu
            local shipMenu = missionCommands.addSubMenuForCoalition(coalitionID, shipName, rootMenu)

            -- Add "Check Status" command
            missionCommands.addCommand(
                "Check Status",
                shipMenu,
                function() checkShipStatus(shipName, coalitionID) end
            )

            -- Add "Fire Cruise Missiles" command
            missionCommands.addCommand(
                "Fire Cruise Missiles",
                shipMenu,
                function() fireCruiseMissiles(shipName, coalitionID) end
            )
        end
    end
end

-- =======================
-- Initialization
-- =======================

-- Initialize the Mod
local function main()
    detectCruiseMissileShips()
    createCoalitionMenus()
end

main()
