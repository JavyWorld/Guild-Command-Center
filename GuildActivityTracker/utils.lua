local addonName = ...
local GAT = _G[addonName]

-- Validar nombres
function GAT:Normalize(name)
    if not name then return nil end

    if not name:find("-") then
        name = name .. "-" .. GetRealmName()
    end

    return name
end

-- Si el jugador es uno de tus personajes
function GAT:IsSelf(name)
    return name == GAT.fullPlayerName or name == GAT.shortPlayerName
end

-- Si este jugador está filtrado
function GAT:IsFiltered(name)
    return GAT.db.filters[name] == true
end
