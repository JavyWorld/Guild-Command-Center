local addonName = ...
local GAT = _G[addonName]
if not GAT then return end

-- =========================================================
-- Rank Presence Announcer (Nexonir-only)
-- - Prints "Name - Rank" right after the system online/offline line
-- - Rank name is colored by your guild rank palette
-- =========================================================

local function Trim(s)
    if not s then return "" end
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function NormalizeKey(s)
    s = Trim(s):lower()
    -- strip common accents (so "Capitán" matches "capitan")
    s = s:gsub("á", "a"):gsub("é", "e"):gsub("í", "i"):gsub("ó", "o"):gsub("ú", "u"):gsub("ñ", "n")
    return s
end

local RANK_HEX = {
    ["recluta"]   = "9CA3AF",
    ["soldado"]   = "22C55E",
    ["sargento"]  = "16A34A",
    ["reserva"]   = "06B6D4",
    ["teniente"]  = "3B82F6",
    ["capitan"]   = "1D4ED8",
    ["marine"]    = "F97316",
    ["comandante"]= "EF4444",
    ["general"]   = "A855F7",
    ["emperador"] = "D4AF37",
}

local function Color(hex, text)
    if not text then text = "" end
    if not hex or hex == "" then return tostring(text) end
    hex = tostring(hex):gsub("#", "")
    return "|cff" .. hex .. tostring(text) .. "|r"
end

local function ColorRank(rankName)
    local rn = Trim(rankName)
    if rn == "" or rn == "—" then
        return Color("9CA3AF", (rn ~= "" and rn or "—"))
    end
    local key = NormalizeKey(rn)
    local hx = RANK_HEX[key]
    if not hx then
        return Color("9CA3AF", rn) -- fallback grey
    end
    return Color(hx, rn)
end

local function ExtractPlayerName(token)
    token = Trim(token)
    if token == "" then return nil end

    -- If it is a player hyperlink, prefer the raw name from |Hplayer:
    local p = token:match("|Hplayer:([^:|]+)")
    if p and p ~= "" then
        return p
    end

    -- If it's like [Name], take the inside
    local b = token:match("%[([^%]]+)%]")
    if b and b ~= "" then
        return b
    end

    -- Strip color codes / hyperlinks if present
    token = token:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    token = token:gsub("|H.-|h", ""):gsub("|h", "")
    token = Trim(token)

    return (token ~= "" and token or nil)
end


local function ChatOut(line)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    else
        print(line)
    end
end

local ONLINE_PAT  = "^" .. (GUILD_MEMBER_ONLINE  or "%s has come online."):gsub("%%s", "(.+)") .. "$"
local OFFLINE_PAT = "^" .. (GUILD_MEMBER_OFFLINE or "%s has gone offline."):gsub("%%s", "(.+)") .. "$"

local function FindRankByShortName(shortName)
    if not shortName or shortName == "" then return nil end
    if not IsInGuild() then return nil end

    -- 1) Live roster (best)
    local n = GetNumGuildMembers()
    if n and n > 0 then
        for i = 1, n do
            local name, rank = GetGuildRosterInfo(i)
            if name then
                local s = Ambiguate(name, "short")
                if s == shortName then
                    return rank
                end
            end
        end
    end

    -- 2) Fallback: last known rank from our own cached roster DB (if available)
    if GAT.db and GAT.db.roster then
        for fullName, info in pairs(GAT.db.roster) do
            local s = Ambiguate(fullName, "short")
            if s == shortName then
                if type(info) == "table" then
                    return info.rankName or info.rank or info.r
                end
            end
        end
    end

    return nil
end

local function Announce(msg)
    if not GAT:IsInTargetGuild() then return end
    if type(msg) ~= "string" then return end

    local token = msg:match(ONLINE_PAT)
    if not token then token = msg:match(OFFLINE_PAT) end
    if not token then return end

    local rawName = ExtractPlayerName(token)
    if not rawName then return end

    local shortName = Ambiguate(rawName, "short") or rawName

    -- Ask for a roster refresh so rank is up-to-date, then print shortly after.
    if GuildRoster then pcall(GuildRoster) end

    C_Timer.After(0.20, function()
        if not GAT:IsInTargetGuild() then return end
        local rank = FindRankByShortName(shortName) or "—"
        local line = shortName .. " - " .. ColorRank(rank)
        ChatOut(line)
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:SetScript("OnEvent", function(_, _, msg)
    Announce(msg)
end)
