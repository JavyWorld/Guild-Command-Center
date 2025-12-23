local addonName = ...
local GAT = _G[addonName]

-- =========================================================
-- Helpers de Texto y Fecha
-- =========================================================

-- Obtiene el reino actual sin espacios (formato estándar de addons)
local function GetMyRealm()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName():gsub(" ", "")) or ""
end

-- Convierte SIEMPRE el nombre a formato "Nombre-Reino"
local function GetCanonicalName(name)
    if not name or name == "" then return nil end
    if name:find("-") then
        return name -- Ya tiene reino
    end
    -- Si no tiene reino, le pegamos el nuestro
    return name .. "-" .. GetMyRealm()
end

local function ConvertLastSeenToAmPm(s)
    if type(s) ~= "string" or s == "" then return s end
    if s:find(" AM", 1, true) or s:find(" PM", 1, true) then return s end

    local y, m, d, hh, mm = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
    if not y then return s end

    local H = tonumber(hh)
    local M = tonumber(mm)
    if not H or not M then return s end

    local ampm = "AM"
    local h12 = H
    if H == 0 then h12 = 12; ampm = "AM"
    elseif H == 12 then h12 = 12; ampm = "PM"
    elseif H > 12 then h12 = H - 12; ampm = "PM"
    else h12 = H; ampm = "AM" end

    return string.format("%s-%s-%s %02d:%02d %s", y, m, d, h12, M, ampm)
end

local function ParseLastSeenToTS(s)
    if type(s) ~= "string" or s == "" then return 0 end
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local y, m, d, hh, mm, ap = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d?):(%d%d)%s*(AM|PM)$")
    if y then
        local H = tonumber(hh); if ap == "AM" and H == 12 then H = 0 end; if ap == "PM" and H ~= 12 then H = H + 12 end
        return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = H, min = tonumber(mm), sec = 0 })
    end
    local y2, m2, d2, HH, MM = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
    if y2 then
        return time({ year = tonumber(y2), month = tonumber(m2), day = tonumber(d2), hour = tonumber(HH), min = tonumber(MM), sec = 0 })
    end
    return 0
end

local function DateKeyToTS(dateStr)
    if not dateStr then return 0 end
    local y, m, d = dateStr:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if y then
        return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
    end
    return 0
end

-- Helper interno para fusionar datos de 'source' en 'dest'
local function MergeEntry(dest, source)
    if not dest or not source then return end
    
    dest.total = (dest.total or 0) + (source.total or 0)
    
    dest.daily = dest.daily or {}
    if source.daily then
        for day, count in pairs(source.daily) do
            dest.daily[day] = (dest.daily[day] or 0) + count
        end
    end
    
    -- Nos quedamos con la fecha más reciente
    local destTS = dest.lastSeenTS or 0
    local sourceTS = source.lastSeenTS or 0
    if sourceTS > destTS then
        dest.lastSeen = source.lastSeen
        dest.lastSeenTS = source.lastSeenTS
        dest.lastMessage = source.lastMessage
    end
    
    -- Preservar rango
    if (not dest.rankName or dest.rankName == "—") and (source.rankName and source.rankName ~= "—") then
        dest.rankName = source.rankName
        dest.rankIndex = source.rankIndex
    end
end

-- =========================================================
-- Gestión de DB
-- =========================================================
function GAT:EnsureSortDefaults()
    GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
    _G.GuildActivityTrackerDB = GAT.db
    GAT.db.settings = GAT.db.settings or {}

    if GAT.db.settings.sortMode == nil then GAT.db.settings.sortMode = "count" end 
    if GAT.db.settings.sortDir == nil then GAT.db.settings.sortDir = "desc" end   
    
    if GAT.db.settings.enableAutoArchive == nil then GAT.db.settings.enableAutoArchive = false end
    if GAT.db.settings.autoArchiveDays == nil or GAT.db.settings.autoArchiveDays < 7 then 
        GAT.db.settings.autoArchiveDays = 30 
    end
end

function GAT:UpgradeDBIfNeeded()
    GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
    _G.GuildActivityTrackerDB = GAT.db
    GAT.db.data = GAT.db.data or {}
    GAT:EnsureSortDefaults()

    -- 1. Migración de estructura
    for name, value in pairs(GAT.db.data) do
        if type(value) == "number" then
            GAT.db.data[name] = { total = value, lastSeen = "", lastSeenTS = 0, lastMessage = "", daily = {}, rankIndex = 99, rankName = "—" }
        elseif type(value) == "table" then
            value.total = value.total or 0
            value.lastSeen = value.lastSeen or ""
            value.daily = value.daily or {}
            value.rankIndex = value.rankIndex or 99
            value.rankName = value.rankName or "—"
            if type(value.lastSeenTS) ~= "number" then
                value.lastSeenTS = ParseLastSeenToTS(value.lastSeen or "")
            end
            value.lastSeen = ConvertLastSeenToAmPm(value.lastSeen)
        end
    end

    -- 2. LIMPIEZA DE DUPLICADOS (La Gran Unificación)
    -- Recorremos la DB buscando claves que NO tengan guion (nombres cortos)
    -- y las fusionamos con su versión con guion (nombre-reino).
    local myRealm = GetMyRealm()
    local mergedCount = 0

    for name, entry in pairs(GAT.db.data) do
        -- Si el nombre NO tiene guion...
        if not name:find("-") then
            -- Construimos el nombre completo teórico
            local fullName = name .. "-" .. myRealm
            
            -- Si ya existe la entrada completa, fusionamos ESTA (corta) dentro de la COMPLETA
            if GAT.db.data[fullName] then
                MergeEntry(GAT.db.data[fullName], entry)
                GAT.db.data[name] = nil -- Borramos la corta
                mergedCount = mergedCount + 1
            else
                -- Si NO existe la completa, simplemente RENOMBRAMOS esta corta a completa
                GAT.db.data[fullName] = entry
                GAT.db.data[name] = nil
                -- No cuenta como merge, es un rename, pero limpia la lista
            end
        end
    end
    
    if mergedCount > 0 and GAT.Print then
        GAT:Print("Mantenimiento: Se fusionaron " .. mergedCount .. " entradas duplicadas.")
    end
end

-- =========================================================
-- Lógica Principal
-- =========================================================

function GAT:ScanRosterForRanks()
    if not GAT.IsInGuild or not GAT:IsInGuild() then return end
    GAT.db = GAT.db or {}
    GAT.db.data = GAT.db.data or {}

    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local fullName, rankName, rankIndex = GetGuildRosterInfo(i)
        
        if not rankName and rankIndex then
            rankName = GuildControlGetRankName(rankIndex + 1)
        end
        if not rankName or rankName == "" then rankName = "Miembro" end

        if fullName then
            -- Normalizamos SIEMPRE a Nombre-Reino para buscar en DB
            local normalizedName = GetCanonicalName(fullName)
            
            if normalizedName and GAT.db.data[normalizedName] then
                GAT.db.data[normalizedName].rankName = rankName
                GAT.db.data[normalizedName].rankIndex = rankIndex
            end
        end
    end
end

function GAT:AddActivity(player, msg)
    if not player then return end
    
    GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
    GAT.db.data = GAT.db.data or {}

    -- NORMALIZACIÓN ESTRICTA: Siempre convertimos a Nombre-Reino
    local fullPlayerName = GetCanonicalName(player)
    
    -- Por si acaso, revisamos si existe una entrada "corta" vieja y la absorbemos ahora mismo
    local shortName = Ambiguate(player, "short")
    if shortName ~= fullPlayerName and GAT.db.data[shortName] then
        -- Si no existe la larga, la creamos con los datos de la corta
        if not GAT.db.data[fullPlayerName] then
            GAT.db.data[fullPlayerName] = GAT.db.data[shortName]
        else
            -- Si existen ambas, fusionamos
            MergeEntry(GAT.db.data[fullPlayerName], GAT.db.data[shortName])
        end
        GAT.db.data[shortName] = nil
    end

    -- A partir de aquí, solo trabajamos con la clave completa
    if type(GAT.db.data[fullPlayerName]) ~= "table" then
        local oldVal = (type(GAT.db.data[fullPlayerName]) == "number") and GAT.db.data[fullPlayerName] or 0
        GAT.db.data[fullPlayerName] = { total = oldVal, lastSeen = "", lastSeenTS = 0, lastMessage = "", daily = {}, rankIndex = 99, rankName = "—" }
    end

    local entry = GAT.db.data[fullPlayerName]
    local today = date("%Y-%m-%d")

    entry.total = (entry.total or 0) + 1
    entry.lastSeen = date("%Y-%m-%d %I:%M %p") 
    entry.lastSeenTS = time() 
    entry.lastMessage = msg or entry.lastMessage or ""
    entry.daily[today] = (entry.daily[today] or 0) + 1
end

function GAT:GetSortedActivity()
    GAT:EnsureSortDefaults()

    local out = {}
    for name, entry in pairs(GAT.db.data or {}) do
        if type(entry) == "number" then
            entry = { total = entry, lastSeen = "", lastSeenTS = 0, rankIndex = 99, rankName = "—" }
        end

        local ts = entry.lastSeenTS
        if type(ts) ~= "number" then ts = ParseLastSeenToTS(entry.lastSeen or "") end

        table.insert(out, {
            name = name,
            count = entry.total or 0,
            lastSeen = entry.lastSeen or "",
            lastSeenTS = ts or 0,
            rankIndex = entry.rankIndex or 99,
            rankName = entry.rankName or "—"
        })
    end

    local mode = GAT.db.settings.sortMode or "count"
    local dir  = GAT.db.settings.sortDir  or "desc"

    local function nameKey(n) return string.lower(tostring(n or "")) end
    
    local function getOnlineVal(n)
        if GAT.IsOnline and GAT:IsOnline(n) then return 1 else return 0 end
    end

    local function cmp(a, b)
        if mode == "online" then
            local ao = getOnlineVal(a.name)
            local bo = getOnlineVal(b.name)
            if ao ~= bo then
                if dir == "asc" then return ao < bo else return ao > bo end
            end
            if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
            return nameKey(a.name) < nameKey(b.name)

        elseif mode == "rank" then
            if a.rankIndex ~= b.rankIndex then
                if dir == "asc" then return a.rankIndex > b.rankIndex
                else return a.rankIndex < b.rankIndex end
            end
            local ao = getOnlineVal(a.name)
            local bo = getOnlineVal(b.name)
            if ao ~= bo then return ao > bo end
            return nameKey(a.name) < nameKey(b.name)

        elseif mode == "recent" then
            local av = a.lastSeenTS or 0
            local bv = b.lastSeenTS or 0
            if av ~= bv then
                if dir == "asc" then return av < bv end 
                return av > bv 
            end
            if a.count ~= b.count then return a.count > b.count end
            return nameKey(a.name) < nameKey(b.name)

        else 
            local ac = a.count or 0
            local bc = b.count or 0
            if ac ~= bc then
                if dir == "asc" then return ac < bc end
                return ac > bc
            end
            local av = a.lastSeenTS or 0
            local bv = b.lastSeenTS or 0
            if av ~= bv then return av > bv end
            return nameKey(a.name) < nameKey(b.name)
        end
    end

    table.sort(out, cmp)
    return out
end

function GAT:GetPlayerData(name)
    local d = (GAT.db.data or {})[name]
    if type(d) == "table" then return d end
    return nil
end

function GAT:ResetData()
    if self.db and self.db.data then wipe(self.db.data) end
end

function GAT:ResetPlayer(name)
    if GAT.db and GAT.db.data then GAT.db.data[name] = nil end
end

-- =========================================================
-- AUTO ARCHIVE (Rolling Window)
-- =========================================================
function GAT:RunAutoArchive()
    if not GAT.db or not GAT.db.settings or not GAT.db.settings.enableAutoArchive then
        return
    end

    local days = math.max(7, GAT.db.settings.autoArchiveDays or 30)
    local cutoff = time() - (days * 24 * 3600)
    
    local removedDays = 0
    local recalcPlayers = 0
    local deletedPlayers = 0

    if GAT.db.data then
        for name, entry in pairs(GAT.db.data) do
            if entry.daily and type(entry.daily) == "table" then
                local newTotal = 0
                local changed = false

                for dateStr, dailyCount in pairs(entry.daily) do
                    local ts = DateKeyToTS(dateStr)
                    if ts > 0 and ts < cutoff then
                        entry.daily[dateStr] = nil
                        removedDays = removedDays + 1
                        changed = true
                    else
                        newTotal = newTotal + dailyCount
                    end
                end

                if newTotal == 0 then
                    GAT.db.data[name] = nil
                    deletedPlayers = deletedPlayers + 1
                else
                    entry.total = newTotal
                    if changed then recalcPlayers = recalcPlayers + 1 end
                end
            end
        end
    end

    if deletedPlayers > 0 or removedDays > 0 then
        if GAT.Print then 
            GAT:Print("Limpieza: Se borraron " .. deletedPlayers .. " jugadores inactivos y " .. removedDays .. " días antiguos.") 
        end
    end
end