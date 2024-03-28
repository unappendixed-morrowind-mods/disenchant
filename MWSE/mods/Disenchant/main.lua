-- Globals: all except meshref and player should be reset to nil after execution
-- of disenchant process.
-- NOTE: Probably not great to have this many globals to juggle.
local meshref = require("Disenchant.meshes")

local MODNAME = "Disenchant"

local log = require("logging.logger").new({
    name = MODNAME,
    logLevel = "WARN",
    logToConsole = false,
    includeTimestamp = true
})

---@class ModConfig
---@field Keybind  mwseKeyCombo | nil
local defaults = {
    AlwaysSucceed = false,
    HealthDamage = true,
    ChanceFloorToggle = true,
    SkillMod = 0,
    ChargeInfluence = 10,
    ChanceFloorVal = 1,
    AllowBuiltin = true,
    Keybind = nil,
}

---@type ModConfig
local config = mwse.loadConfig(MODNAME, defaults)

---@type tes3mobilePlayer
local player = nil

local mesh = nil

local mesh_alt = nil

---@type tes3reference | nil
local target = nil

local cost = nil

---@enum DisenchantFailType
local DisenchantFailTypes = {
    NoEnchant = 1,
    MeshError = 2,
    Unique = 3,
    Magicka = 4,
    Skill = 5,
}

local function init()
    mwse.log("[Disenchant] Initialized")
end

local function negInd(tbl, ind)
    local abs_index = #tbl + ind + 1
    return tbl[abs_index]
end

-- Quickly reset globals defined above.
local function resetGlobals()
    target = nil
    cost = nil
    mesh = nil
    mesh_alt = nil
end

-- pcall the tes3.getObject function to test the ID as using an incorrect ID
-- with it can cause CTDs.
local function isValidId(id)
    local pass = pcall(function() return tes3.getObject(id) end)
    return pass
end

-- Setting MWSE-lua statistics directly is discouraged and causes UI desyncs,
-- so setMagicka and setHealth abstract the correct setter function.
local function setMagicka(value)
    tes3.setStatistic({
        reference = tes3.player,
        current = value,
        name = "magicka"
    })
end

local function setHealth(value)
    tes3.setStatistic({
        reference = tes3.player,
        current = value,
        name = "health"
    })
end

--[[
local function retrieveSoul(value)
    if (player.object.inventory) then end
    if (value <= 30) then
        gem_type = "misc_soulgem_petty"
    end

end
 ]]

-- Places and then deletes an invisible creature underneath the target object
-- to make the fail effect more visually appropriate.
local function spawnCopy()
    if target == nil then
        return
    end

    local rat = tes3.getObject("rat") --[[@as tes3creature]]

    local rat_position = target.position:copy()
    rat_position.z = rat_position.z - 100
    local copy = tes3.createReference({
        object = rat,
        position = rat_position,
        orientation = target.orientation,
        cell =
            target.cell
    })
    copy:disable()
    return copy
end

--- Called by disenchantTry when a failstate is reached. 'type' parameter
--- determines consequences and error handling.
---@param type DisenchantFailType
local function disenchantFail(type)
    tes3.playSound({ sound = "spell failure mysticism" })

    if target == nil then
        return
    end


    -- Unique failstate means that there is no unenchanted version of the
    -- item's mesh in the base game + expansions.
    if (type == DisenchantFailTypes.Unique) then
        tes3.messageBox("This item is more magical than physical. It cannot be disenchanted.")

        -- Player failed skill roll.
        -- TODO: Add more iterations indicating how good the player's chances 
        -- were / how severe the failure was.
    elseif (type == DisenchantFailTypes.Skill) then
        setMagicka(0)
        tes3.messageBox("Your concentation slips and the enchantment remains.")

        -- Player's current magicka was lower than the calculated cost. This
        -- incurs a consequence of health damage equivalent to the difference
        -- between the cost and their current magicka.
    elseif (type == DisenchantFailTypes.Magicka) then
        local health_cost = cost - player.magicka.current
        setMagicka(0)
        tes3.messageBox("Your magicka is insufficient and the soul within overpowers you.")

        if (config ~= nil and config["HealthDamage"]) then
            -- Spells can only be cast at other references, so spawn an
            -- invisible creature beneath the floor so the consequence spell
            -- shoots down and hits the ground.
            local copy = spawnCopy()
            if copy == nil then
                log:error("Failed to copy reference, exiting disenchantFail early.")
                return
            end
            tes3.cast({ reference = target, target = copy, spell = "disenchant_fail" })
            setHealth(player.health.current - health_cost)
            timer.start({
                callback = function()
                    if copy ~= nil then
                        tes3.deleteObject(copy)
                    end
                    -- mwscript.setDelete({reference = copy, delete = true}) -- whole library is deprecated, but there's no other way to do this safely
                end,
                duration = 2
            })
        end

        -- Item has no enchantment. Because there's currently no way to get an
        -- item's current condition, disenchant could be used as a repair
        -- exploit without this check.
    elseif (type == DisenchantFailTypes.NoEnchant) then
        tes3.messageBox('This item is not enchanted.')
        resetGlobals()

        -- The big one, and the only meta error. Shouldn't happen often.
    elseif (type == DisenchantFailTypes.MeshError) then
        tes3.messageBox("Mesh not found. Check MWSE.log for error.")
        local message = string.format("Full mesh: %s\nMesh Substring: %s\nID: %s\n", mesh, mesh_alt, meshref[mesh_alt])
        message = message .. "If you experienced this error with a non-modded item, please report it to the mod author."
        print(message)
    end
    resetGlobals()
end

-- Called by disenchantTry when all conditions are met. Executes disenchanting
-- of item. Any errors caused by this function should ideally be caught in
-- disenchantTry.
local function disenchantSucceed()
    if target == nil then
        return
    end

    if (config ~= nil and config["AlwaysSucceed"] == false) then
        -- Adjust player magicka according to cost.
        setMagicka(player.magicka.current - cost)
    end

    -- Get target object's position, orientation, condition and cell information.
    local pos = target.position:copy()
    local orient = target.orientation:copy()
    local pcell = target.cell

    local condition = nil
    if (target.itemData ~= nil) then
        condition = target.itemData.condition
    end

    if (mesh == nil or mesh_alt == nil) then
        mesh = target.object.mesh
        mesh_alt = negInd(mesh:split([[\]]), -1):lower()
    end

    -- hide and then delete original target
    target:disable()
    local hitsound = tes3.getSound("mysticism area")
    tes3.playSound({ sound = hitsound, volume = 1 })
    timer.delayOneFrame(
        function()
            local obj = target.object
            local ench = obj.enchantment

            tes3.deleteObject(target)
            -- mwscript.setDelete({reference = target, delete = true}) -- For some reason the only way to delete a reference in MWSE-lua
            -- If object's sourceMod is the save file instead of a plugin file,
            -- delete the object and enchantment to reduce save bloat.
            if (target.object.sourceMod == nil) then
                tes3.deleteObject(obj)
                tes3.deleteObject(ench)
            end
            resetGlobals()
        end
    )
    -- get generic version of object and spawn in place of target
    local obj = tes3.getObject(meshref[mesh_alt]) -- Shouldn't be able to crash game due to pcall test in disenchantTry body.
    ---@cast obj tes3weapon | tes3armor | tes3clothing
    local new_ref = tes3.createReference({ object = obj, position = pos, orientation = orient, cell = pcell })
    if (condition ~= nil) then
        tes3.addItemData({ to = new_ref, item = obj })
        new_ref.itemData.condition = condition
    end
end


-- Called by filterSpell. All logic determining whether the target is valid and math to determine success or failure of disenchanting.
local function disenchantTry()
    target = tes3.getPlayerTarget()

    -- Make sure we have a target.
    if (target == nil) then
        return
    end

    -- Check that target is of valid type. Currently only allowing weapons (weapon, armor, clothing)
    if (
            target.object.objectType ~= tes3.objectType.weapon and
            target.object.objectType ~= tes3.objectType.clothing and
            target.object.objectType ~= tes3.objectType.armor
        ) then
        resetGlobals()
        return
    end

    mesh = target.object.mesh
    mesh_alt = negInd(mesh:split([[\]]), -1):lower()

    -- Don't do anything for throwables (knives, stars, darts)
    if (meshref[mesh_alt] == "!throw") then
        resetGlobals()
        return
    end

    if (config ~= nil and config['AllowBuiltin'] == false and target.object.sourceMod ~= nil) then
        tes3.messageBox("You are unfamiliar with this enchantment and cannot attempt to remove it.")
        resetGlobals()
        return
    end

    -- If weapon is unenchanted, go to "no_enchant" failstate
    if (target.object.enchantment == nil) then
        disenchantFail(DisenchantFailTypes.NoEnchant)
        return
    end

    -- Account for left parts. Left parts (gloves, gauntlets, pauldrons) should
    -- end with ".nifl" instead of ".nif"
    if target.object.isLeftPart then
        mesh_alt = mesh_alt .. "l"
    end

    -- If target mesh is not in mesh table, go to "mesh_error" failstate
    if (meshref[mesh_alt] == nil) then
        disenchantFail(DisenchantFailTypes.MeshError)
        return
    end

    -- If target mesh is labeled as '!unique' in mesh table, go to "unique" failstate
    if (meshref[mesh_alt] == "!unique") then
        disenchantFail(DisenchantFailTypes.Unique)
        return

        -- If target mesh is labeled as "!unused" in mesh table, go to "mesh_error" failstate
    elseif (meshref[mesh_alt] == "!unused") then
        disenchantFail(DisenchantFailTypes.MeshError)
        return
        -- If target fails tes3.getObject test, go to "mesh_error" failstate
    elseif (isValidId(meshref[mesh_alt]) == false) then
        disenchantFail(DisenchantFailTypes.MeshError)
        return
    end

    if (config ~= nil and config["AlwaysSucceed"]) then
        disenchantSucceed()
        return
    end
    -- START formula to determine success chance and random roll
    local rand = math.random() * 100
    assert(config)
    local bonus = player.enchant.current + (0.25 * player.intelligence.current) + (0.125 * player.luck.current) -
        (target.object.enchantment.maxCharge / config["ChargeInfluence"]) + config["SkillMod"]
    if (config ~= nil and config["ChanceFloorToggle"]) then
        -- Ensure that bonus is not negative or zero (allow small chance regardless of player skills)
        if (bonus < config["ChanceFloorVal"]) then
            bonus = config["ChanceFloorVal"]
        end
    end

    cost = player.magicka.base - (player.magicka.base * (bonus / 100)) + (target.object.enchantment.maxCharge * 0.1)
    local roll = rand <= bonus
    -- END formula

    -- Skill/magicka tests.
    if (roll == false) then
        disenchantFail(DisenchantFailTypes.Skill)
    elseif (cost >= player.magicka.current) then
        disenchantFail(DisenchantFailTypes.Magicka)
    else
        disenchantSucceed()
    end
end

-- Called by 'spellCast' event listener. Tests for disenchant spell and calls
-- disenchantTry if true.
local function filterSpell(e)
    if ((e.source.id == "disenchant" or e.source.id == "disenchant_dummy") and
            e.caster == tes3.player) then
        disenchantTry()
    end
end


local function registerModConfig()
    EasyMCM = require("easyMCM.EasyMCM")
    local template = EasyMCM.createTemplate(MODNAME)
    local settingsPage = template:createSideBarPage()
    -- do
    local features = settingsPage:createCategory("Toggle Features")
    features:createOnOffButton {
        label = "Always Succeed",
        description = "Disables skill checks and magicka costs for disenchanting.\n\nDefault: Off",
        variable = EasyMCM.createTableVariable {
            id = "AlwaysSucceed",
            table = config
        }
    }
    features:createOnOffButton {
        label = "Allow Builtin Items",
        description = "If this is enabled, the spell will work on both pre-made enchanted items in the game and player enchanted items. If disabled, only custom player items can be disenchanted. This will eliminate the risk of losing a unique enchantment.\n\nDefault: On",
        variable = EasyMCM.createTableVariable {
            id = "AllowBuiltin",
            table = config
        }
    }
    features:createOnOffButton {
        label = "Health Damage",
        description = "Toggle the player taking health damage if they have insufficient magicka to match the item's charge.\n\nDefault: On",
        variable = EasyMCM.createTableVariable {
            id = "HealthDamage",
            table = config
        }
    }
    features:createOnOffButton {
        label = "Minimum Chance",
        description = "Enforce a minimum chance regardless of player's skills and attributes.\n\nDefault: On",
        variable = EasyMCM.createTableVariable {
            id = "ChanceFloorToggle",
            table = config
        }
    }
    settingsPage:createKeyBinder({
        label = "Keyboard Shortcut",
        description = "Set a keyboard shortcut here to cast the disenchant spell at your target.",
        allowCombinations = true,
        variable = EasyMCM.createTableVariable({
            id = "Keybind",
            table = config
        })
    })

    local sliders = settingsPage:createCategory("Balance Tweaks")

    sliders:createSlider({
        label = "Skill Modifier",
        description =
        "This value is added to skill checks. Effectively the same as modifying the enchant skill by the same value. Increase it to apply a flat bonus to skill check.\n\nDefault: 0",
        min = -100,
        max = 300,
        variable = EasyMCM.createTableVariable({
            id = "SkillMod",
            table = config
        })
    })

    sliders:createSlider({
        label = "Item charge influence",
        description =
        "The enchanted item's charge is divided by this value before being subtracted from the player's skill bonus. Higher values reduce the difference in difficulty between low charge and high charge items.\n\nDefault: 10",
        min = 1,
        max = 50,
        variable = EasyMCM.createTableVariable({
            id = "ChargeInfluence",
            table = config
        })
    })

    sliders:createSlider({
        label = "Minimum Chance Amount",
        description =
        "Requires 'Minimum Chance' feature above to be enabled. Chance of success will never be lower than this value.\n\nDefault: 1",
        min = 1,
        max = 100,
        variable = EasyMCM.createTableVariable({
            id = "ChanceFloorVal",
            table = config
        })
    })
    -- end
    features:createKeyBinder({
        label = "Keyboard Shortcut",
        description = "Set a keyboard shortcut here to cast the disenchant spell at your target.",
        allowCombinations = true,
        variable = EasyMCM.createTableVariable({
            id = "Keybind",
            table = config,
            defaultSetting = {
                keyCode = tes3.scanCode.k
            }
        })
    })
    template:saveOnClose(MODNAME, config)
    EasyMCM.register(template)
end


---@param e keyUpEventData
local function triggerDisenchant(e)
    if (config == nil or config.Keybind == nil) then
        return
    end

    if e.keyCode == config.Keybind.keyCode and
        e.isAltDown == config.Keybind.isAltDown and
        e.isSuperDown == config.Keybind.isSuperDown and
        e.isControlDown == config.Keybind.isControlDown and
        e.isShiftDown == config.Keybind.isShiftDown
    then

        local dummy = tes3.getObject("disenchant_dummy") --[[@as tes3spell]]

        if (tes3.getObject("disenchant_dummy") == nil) then
            local realDispel = tes3.getObject("Dispel") --[[@as tes3spell]]
            dummy = realDispel:createCopy({ id = "disenchant_dummy" })
        end

        dummy.effects[1].max = 0
        dummy.effects[1].rangeType = tes3.effectRange.touch

        tes3.cast({
            reference = tes3.player,
            target = tes3.player,
            spell = dummy,
            alwaysSucceeds = true
        })

        timer.start({
            type = timer.simulate,
            duration = 1,
            callback = function() tes3.deleteObject(dummy) end
        })
    end
end

-- Event listeners.
event.register('modConfigReady', registerModConfig)
event.register('spellCast', filterSpell)
event.register('loaded', function(_) player = tes3.mobilePlayer end)
event.register("initialized", init)
event.register(tes3.event.keyUp, triggerDisenchant)
