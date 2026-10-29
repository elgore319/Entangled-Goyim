-- Keeps a backup of the local player's wands, items, spells, perks, gold and
-- HP, so a crash can't silently wipe them.
--
-- Noita only writes the player to its save at certain points, so after a
-- crash "Continue" can load the world but a brand-new starting character.
-- This system writes its own backup while the player is alive: soon after the
-- inventory changes, and when perks, gold or HP change (checked every 10 s).
-- When the player spawns into the same run (same host, run number and world
-- seed) looking like a fresh character while the backup shows real
-- progress, it offers to restore the backup. Nothing is restored without the
-- player choosing it.
--
-- The backup is deleted when the player dies, so dying and rejoining can't
-- bring items back.

local bitser = dofile_once("mods/goyim.ew/files/lib/bitser.lua")
local seed_sync = dofile_once("mods/goyim.ew/files/system/seed_sync/seed_sync.lua")
local perk_fns = dofile_once("mods/goyim.ew/files/core/perk_fns.lua")

local module = {}

local BACKUP_PATH = "mods/goyim.ew/ew_crash_backup.bin"
-- How often perks, gold and HP are checked for changes. Items are captured
-- whenever the mod already sends the inventory to other players.
local BACKUP_INTERVAL_FRAMES = 60 * 10
-- Frames to wait after spawning before comparing, so the loaded inventory,
-- perks and gold are in place.
local CHECK_DELAY_FRAMES = 60
-- Inventory changes are written at most this often. Writing the file is
-- done on the game thread, so writing on every change (buying, picking up
-- and sorting spells in a holy mountain) caused small hitches.
local INVENTORY_WRITE_INTERVAL_FRAMES = 60 * 2

local gui = GuiCreate()

-- Backups only start once the restore decision is made, so a fresh
-- character never overwrites the backup it might need.
local backups_enabled = false
local check_frame = nil
local offered = nil
local last_backup_frame = 0
local last_inventory_write_frame = -INVENTORY_WRITE_INTERVAL_FRAMES
-- The inventory changed since the last backup and is waiting to be written.
local inventory_dirty = false
-- The latest serialized inventory, captured when the mod sends it to the
-- other players, so backups don't serialize items a second time.
local latest_items = nil
local latest_spells = nil
local last_written = nil
-- Set once the backup has been deleted for this death, so it isn't deleted
-- again every frame.
local backup_cleared = false

local function run_key()
    return table.concat({
        tostring(ctx.host_id),
        tostring(ctx.proxy_opt.world_num),
        tostring(StatsGetValue("world_seed")),
    }, ":")
end

local function read_backup()
    local file = io.open(BACKUP_PATH, "rb")
    if file == nil then
        return nil
    end
    local data = file:read("*a")
    file:close()
    if data == nil or data == "" then
        return nil
    end
    local ok, backup = pcall(bitser.loads, data)
    if not ok or type(backup) ~= "table" or backup.run == nil then
        return nil
    end
    return backup
end

local function write_backup(backup)
    -- Write to a temp file first so a crash mid-write can't leave a broken
    -- backup in place of a good one.
    local tmp = BACKUP_PATH .. ".tmp"
    local file = io.open(tmp, "wb")
    if file == nil then
        return
    end
    file:write(bitser.dumps(backup))
    file:close()
    os.remove(BACKUP_PATH)
    os.rename(tmp, BACKUP_PATH)
end

local function delete_backup()
    os.remove(BACKUP_PATH)
    -- Forget what was written, so the next backup is written in full.
    last_written = nil
end

local function player_can_be_backed_up()
    local player = ctx.my_player
    return player ~= nil
        and player.entity ~= nil
        and EntityGetIsAlive(player.entity)
        and not ctx.run_ended
        and not GameHasFlagRun("ew_flag_notplayer_active")
        and not EntityHasTag(player.entity, "polymorphed")
        and not EntityHasTag(player.entity, "polymorphed_player")
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

-- A character that has just started: no perks, no gold, no spare spells.
local function looks_fresh(state)
    return count(state.perks) == 0 and (state.money or 0) == 0 and count(state.spells) == 0
end

local function has_progress(backup, current)
    return count(backup.perks) > 0
        or (backup.money or 0) > 0
        or count(backup.spells) > 0
        or (backup.max_hp ~= nil and current.max_hp ~= nil and backup.max_hp > current.max_hp)
end

local function cheap_state()
    local player = ctx.my_player
    local state = { perks = perk_fns.get_my_perks() }
    local wallet = EntityGetFirstComponentIncludingDisabled(player.entity, "WalletComponent")
    if wallet ~= nil then
        state.money = ComponentGetValue2(wallet, "money")
    end
    if ctx.proxy_opt.game_mode ~= "shared_health" then
        local damage = EntityGetFirstComponentIncludingDisabled(player.entity, "DamageModelComponent")
        if damage ~= nil then
            state.hp = ComponentGetValue2(damage, "hp")
            state.max_hp = ComponentGetValue2(damage, "max_hp")
        end
    end
    return state
end

local function take_backup()
    if latest_items == nil or not player_can_be_backed_up() then
        return
    end
    local ok, state = pcall(cheap_state)
    if not ok then
        return
    end
    state.items = latest_items
    state.spells = latest_spells
    state.run = run_key()
    local encoded = bitser.dumps(state)
    if encoded == last_written then
        return
    end
    last_written = encoded
    state.saved_at = os.time()
    write_backup(state)
end

-- Called with the inventory the mod just sent to the other players.
function module.on_inventory_sent(items, spells)
    latest_items = items
    if spells ~= nil then
        latest_spells = spells
    end
    inventory_dirty = true
end

function module.on_local_player_spawn()
    backups_enabled = false
    offered = nil
    check_frame = GameGetFrameNum() + CHECK_DELAY_FRAMES
end

local function decide_on_spawn()
    check_frame = nil
    local backup = read_backup()
    if backup == nil or backup.run ~= run_key() or not player_can_be_backed_up() then
        -- No backup for this run (new run, new world, or first time).
        backups_enabled = true
        return
    end
    local ok, current = pcall(seed_sync.collect_player_state)
    if ok and looks_fresh(current) and has_progress(backup, current) then
        offered = backup
        GamePrint("It looks like your items were lost, probably after a crash. You can restore them.")
    else
        backups_enabled = true
    end
end

local function draw_offer()
    GuiStartFrame(gui)
    GuiZSet(gui, -100)
    local w, h = GuiGetScreenDimensions(gui)
    local function centered_text(y, text)
        local tw = GuiGetTextDimensions(gui, text)
        GuiText(gui, (w - tw) / 2, y, text)
    end
    local function centered_button(id, y, text)
        local tw = GuiGetTextDimensions(gui, text)
        return GuiButton(gui, id, (w - tw) / 2, y, text)
    end
    local y = h * 0.3
    centered_text(y, "Your wands and items from this run were lost, probably after a crash.")
    centered_text(y + 12, "A backup from " .. os.date("%H:%M", offered.saved_at or os.time()) .. " was found.")
    if centered_button(1, y + 32, "[ Restore my items ]") then
        local backup = offered
        offered = nil
        local restored, err = pcall(seed_sync.restore_player_state, backup)
        if restored then
            GamePrint("Your items were restored.")
        else
            print("Crash recovery: restore failed: " .. tostring(err))
            GamePrint("Restoring your items failed. The backup was kept.")
        end
        -- Wait before backing up again so the restored items are in place.
        last_backup_frame = GameGetFrameNum()
        backups_enabled = restored
    end
    if centered_button(2, y + 48, "[ Keep my current character ]") then
        offered = nil
        backups_enabled = true
        last_backup_frame = GameGetFrameNum()
    end
end

function module.on_world_update()
    if check_frame ~= nil and GameGetFrameNum() >= check_frame then
        decide_on_spawn()
    end
    if offered ~= nil then
        draw_offer()
        return
    end
    if GameHasFlagRun("ew_flag_notplayer_active") then
        -- Dead in local health mode: the backup must not bring items back.
        if not backup_cleared then
            backup_cleared = true
            delete_backup()
        end
        return
    end
    backup_cleared = false
    if not backups_enabled then
        return
    end
    local frame = GameGetFrameNum()
    if inventory_dirty and frame - last_inventory_write_frame >= INVENTORY_WRITE_INTERVAL_FRAMES then
        inventory_dirty = false
        last_inventory_write_frame = frame
        take_backup()
    elseif frame - last_backup_frame >= BACKUP_INTERVAL_FRAMES then
        last_backup_frame = frame
        take_backup()
    end
end

function module.on_player_died()
    backups_enabled = false
    inventory_dirty = false
    delete_backup()
end

return module
