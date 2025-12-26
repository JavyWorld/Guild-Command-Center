local addonName = ...
local GAT = _G[addonName]

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- =========================================================
-- Helpers safe API
-- =========================================================
local function RequestGuildRosterRefresh()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
        return true
    elseif GuildRoster then
        GuildRoster()
        return true
    end
    return false
end

-- =========================================================
-- Cache Online/Offline + Timestamps
-- =========================================================
GAT._onlineCache = GAT._onlineCache or {}

function GAT:RebuildOnlineCache()
    wipe(GAT._onlineCache)
    local n = GetNumGuildMembers()
    for i = 1, n do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            -- Aquí usamos Ambiguate "none" para guardar en caché con formato Nombre-Reino
            -- si el juego lo provee así.
            name = Ambiguate(name, "none") 
            GAT._onlineCache[name] = isOnline
        end
    end
    
    if GAT.db then
        GAT.db.rosterLastUpdateAt = time()
    end
end

function GAT:IsOnline(fullName)
    if not fullName then return false end
    -- Buscamos tal cual (Nombre-Reino)
    if GAT._onlineCache[fullName] ~= nil then return GAT._onlineCache[fullName] end
    -- Fallback: a veces el cache tiene el nombre corto si es del mismo reino
    local short = Ambiguate(fullName, "short")
    return (GAT._onlineCache and GAT._onlineCache[short]) and true or false
end

function GAT:GetRosterLastUpdateAt()
    return (GAT.db and GAT.db.rosterLastUpdateAt) or 0
end

-- =========================================================
-- Sync Helper
-- =========================================================
GAT._pendingRosterSync = false

function GAT:RequestRosterSync()
    GAT._pendingRosterSync = true
    local ok = RequestGuildRosterRefresh()
    if ok then
        if GAT.Print then GAT:Print("Sincronizando con el servidor...") end
    end
end

-- =========================================================
-- Eventos
-- =========================================================
frame:SetScript("OnEvent", function(self, event, msg, sender)
    if not GAT:IsInTargetGuild() then return end
    if event == "PLAYER_ENTERING_WORLD" then
        return
    end

    if event == "GUILD_ROSTER_UPDATE" then
        if GAT.RebuildOnlineCache then GAT:RebuildOnlineCache() end
        
        if GAT.ScanRosterForRanks then GAT:ScanRosterForRanks() end

        if GAT.RefreshUI then GAT:RefreshUI() end
        
        if GAT.MissingWindow and GAT.MissingWindow:IsShown() and GAT.RefreshMissingList then
            GAT:RefreshMissingList()
        end
        return
    end

    if event == "CHAT_MSG_GUILD" then
        if not sender then return end
        
        -- CAMBIO IMPORTANTE: No usamos Ambiguate aquí para recortar.
        -- Pasamos el sender crudo o con 'none' para preservar el reino si viene.
        -- data.lua se encargará de añadir el reino si falta.
        
        if GAT.IsSelf and GAT:IsSelf(sender) then return end
        if not GAT:IsInTargetGuild() then return end
        if GAT.IsFiltered and GAT:IsFiltered(sender) then return end

        if GAT.AddActivity then GAT:AddActivity(sender, msg) end
        if GAT.RefreshUI then GAT:RefreshUI() end
    end
end)
