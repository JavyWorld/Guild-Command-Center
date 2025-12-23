local addonName = ...
local GAT = _G[addonName] or {}
_G[addonName] = GAT

GAT.version = "4.0"
local TARGET_GUILD_NAME = "Nexonir"

function GAT:Print(msg)
    print("|cff00ff00[GAT]|r " .. msg)
end

-- Eventos de init
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GUILD_ROSTER_UPDATE")

local function UpdatePlayerAndGuild()
    local pName, pRealm = UnitFullName("player")
    if pName then
        GAT.fullPlayerName = pName .. "-" .. (pRealm or GetRealmName())
        GAT.shortPlayerName = Ambiguate(GAT.fullPlayerName, "none")
    end
    GAT.guildName = GetGuildInfo("player") or ""
end

function GAT:IsInGuild()
    -- Consultamos el nombre de hermandad en vivo para evitar valores obsoletos
    local current = (GetGuildInfo("player") or GAT.guildName or ""):lower()
    return current ~= "" and current == TARGET_GUILD_NAME:lower()
end

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        GuildActivityTrackerDB = GuildActivityTrackerDB or {}
        GuildActivityTrackerDB.data = GuildActivityTrackerDB.data or {}
        GuildActivityTrackerDB.filters = GuildActivityTrackerDB.filters or {}
        GuildActivityTrackerDB.settings = GuildActivityTrackerDB.settings or {}
        GuildActivityTrackerDB.minimap = GuildActivityTrackerDB.minimap or { angle = 180 }

        GAT.db = GuildActivityTrackerDB

        if GAT.UpgradeDBIfNeeded then
            GAT:UpgradeDBIfNeeded()
        end

        -- EJECUTAR AUTO-ARCHIVE AL CARGAR
        if GAT.RunAutoArchive then
            GAT:RunAutoArchive()
        end

        local count = 0
        if GAT.db.data then for _ in pairs(GAT.db.data) do count = count + 1 end end
        GAT:Print("Cargado. Jugadores registrados: " .. count)
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "GUILD_ROSTER_UPDATE" then
        UpdatePlayerAndGuild()
    end
end)

-- Slash
SLASH_GAT1 = "/gat"
SlashCmdList["GAT"] = function()
    if GAT.ToggleUI then GAT:ToggleUI() end
end

-- Log Out Save
local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function()
    -- Nada especial, SavedVariables se guarda solo, pero podríamos print
end)