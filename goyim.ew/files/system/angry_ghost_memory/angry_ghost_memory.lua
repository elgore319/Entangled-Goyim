local rpc = net.new_rpc_namespace()
local ghost = {}

function rpc.send_ghost_data(ghosts_memory)
    for i, entity in ipairs(EntityGetAllChildren(ctx.rpc_player_data.entity, "angry_ghost") or {}) do
        if ghosts_memory[i] ~= nil then
            local memory = EntityGetFirstComponentIncludingDisabled(
                entity,
                "VariableStorageComponent",
                "angry_ghost_projectile_memory"
            )
            if memory ~= nil then
                ComponentSetValue2(memory, "value_string", ghosts_memory[i][1])
            end
        else
            EntityKill(entity)
        end
    end
end

function ghost.on_world_update()
    if GameGetFrameNum() % 10 ~= 6 then
        return
    end
    local ghosts_memory = {}
    for _, entity in ipairs(EntityGetAllChildren(ctx.my_player.entity, "angry_ghost") or {}) do
        local memory = EntityGetFirstComponentIncludingDisabled(
            entity,
            "VariableStorageComponent",
            "angry_ghost_projectile_memory"
        )
        table.insert(ghosts_memory, { memory and ComponentGetValue2(memory, "value_string") or "" })
    end
    if #ghosts_memory ~= 0 then
        rpc.send_ghost_data(ghosts_memory)
    end
end

return ghost
