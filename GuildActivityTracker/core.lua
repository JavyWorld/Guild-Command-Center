local addonName = ...
local GAT = _G[addonName] or {}
_G[addonName] = GAT

-- =============================================================================
-- Constantes y helpers base
-- =============================================================================
GAT.VERSION = "4.0"
GAT.ADDON_PREFIX = "GATSYNC"
GAT.TARGET_GUILD = "Nexonir"

function GAT:Color(hex, text)
    if not text then return "" end
    hex = tostring(hex or "FFFFFF"):gsub("#", "")
    return "|cff" .. hex .. tostring(text) .. "|r"
end

function GAT:Print(msg)
    print("|cff00ff00[GAT]|r " .. tostring(msg))
end

function GAT:Now()
    return time()
end

function GAT:IsMasterBuild()
    return self.IS_MASTER_BUILD == true
end

function GAT:IsInTargetGuild()
    local guildName = (GetGuildInfo("player") or ""):lower()
    return guildName ~= "" and guildName == (self.TARGET_GUILD or ""):lower()
end

-- =============================================================================
-- Init + eventos
-- =============================================================================
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")

local function initDB()
    GuildActivityTrackerDB = GuildActivityTrackerDB or {}
    GuildActivityTrackerDB.data = GuildActivityTrackerDB.data or {}
    GuildActivityTrackerDB.stats = GuildActivityTrackerDB.stats or {}
    GuildActivityTrackerDB.filters = GuildActivityTrackerDB.filters or {}
    GuildActivityTrackerDB.settings = GuildActivityTrackerDB.settings or {}
    GuildActivityTrackerDB.minimap = GuildActivityTrackerDB.minimap or { angle = 180 }
    GAT.db = GuildActivityTrackerDB

    if GAT.UpgradeDBIfNeeded then
        GAT:UpgradeDBIfNeeded()
    end
end

local function updatePlayerNames()
    local pName, pRealm = UnitFullName("player")
    if pName then
        GAT.fullPlayerName = pName .. "-" .. (pRealm or GetRealmName() or "")
        GAT.shortPlayerName = Ambiguate(GAT.fullPlayerName, "short")
    end
end

local function printGuildWarning()
    if GAT.guildNoticeShown then return end
    if not GAT:IsInTargetGuild() then
        GAT.guildNoticeShown = true
        GAT:Print("Solo se recopila datos para la guild " .. (GAT.TARGET_GUILD or ""))
    end
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        initDB()
        updatePlayerNames()
        printGuildWarning()
        local count = 0
        for _ in pairs(GuildActivityTrackerDB.data) do count = count + 1 end
        GAT:Print("Cargado. Jugadores registrados: " .. count)
    elseif event == "PLAYER_LOGIN" then
        updatePlayerNames()
        if GAT.Sync_Init then
            GAT:Sync_Init()
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "GUILD_ROSTER_UPDATE" then
        updatePlayerNames()
        printGuildWarning()
    end
end)

-- Slash
SLASH_GAT1 = "/gat"
SlashCmdList["GAT"] = function()
    if GAT.ToggleUI then
        GAT:ToggleUI()
    end
end
