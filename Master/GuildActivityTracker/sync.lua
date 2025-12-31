local addonName = ...
local GAT = _G[addonName]
if not GAT then return end

-- =============================================================================
-- Constantes
-- =============================================================================
local PREFIX = GAT.ADDON_PREFIX or "GATSYNC"
local HEARTBEAT_INTERVAL = 5
local ROLE_TICK_INTERVAL = 3
local MASTER_TIMEOUT = 20
local FLUSH_INTERVAL = 8
local SEND_INTERVAL = 2
local MAX_FRAGMENT = 220
local SNAPSHOT_STATS_WINDOW = 7 * 24 * 3600

local COLOR_GREEN = "22C55E"
local COLOR_RED = "EF4444"
local COLOR_YELLOW = "FACC15"
local COLOR_BLUE = "3B82F6"
local COLOR_WHITE = "FFFFFF"

local R = {
    initialized = false,
    role = "idle",
    peers = {},
    incoming = {},
}

-- =============================================================================
-- Helpers de DB/estado
-- =============================================================================
local function ensureSyncDB()
    return GAT:EnsureSyncDB()
end

local function isInGuildScope()
    return GAT:IsInTargetGuild()
end

local function now()
    return GAT:Now()
end

local function hasValues(tbl)
    if not tbl then return false end
    for _ in pairs(tbl) do return true end
    return false
end

-- =============================================================================
-- Mensajería anti-spam
-- =============================================================================
function GAT:SysMsg(key, text, colorHex, sessionScoped)
    local sd = ensureSyncDB()
    local cacheKey = sessionScoped and "_sessionPrint" or "printCache"
    sd[cacheKey] = sd[cacheKey] or {}
    local cache = sd[cacheKey]
    if cache[key] == text then return end
    cache[key] = text
    if colorHex then
        text = self:Color(colorHex, text)
    end
    self:Print(text)
end

local function resetSessionCache()
    local sd = ensureSyncDB()
    sd._sessionPrint = {}
    sd.sessionNonce = now()
end

-- =============================================================================
-- Serialización simple (payloads pequeños + chunking)
-- =============================================================================
local function encodeDaily(daily)
    if not daily then return "" end
    local parts = {}
    for day, cnt in pairs(daily) do
        parts[#parts + 1] = day .. ":" .. tostring(cnt)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function decodeDaily(s)
    local out = {}
    if not s or s == "" then return out end
    for token in s:gmatch("([^|]+)") do
        local d, c = token:match("^(%d%d%d%d%-%d%d%-%d%d):(%d+)$")
        if d and c then out[d] = tonumber(c) or 0 end
    end
    return out
end

local function encodeDelta(delta)
    local parts = {}
    if delta.activity then
        for name, data in pairs(delta.activity) do
            local seg = table.concat({
                "A",
                name,
                tostring(data.inc or 0),
                tostring(data.lastSeenTS or 0),
                encodeDaily(data.daily)
            }, ",")
            parts[#parts + 1] = seg
        end
    end
    if delta.stats then
        for ts, cnt in pairs(delta.stats) do
            parts[#parts + 1] = table.concat({ "S", tostring(ts), tostring(cnt) }, ",")
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function decodeDelta(payload)
    local delta = { activity = {}, stats = {} }
    if not payload or payload == "" then return delta end
    for token in payload:gmatch("([^;]+)") do
        local tag = token:sub(1, 1)
        if tag == "A" then
            local _, name, inc, ts, daily = token:match("^(A),([^,]+),([^,]*),([^,]*),(.*)$")
            if name then
                delta.activity[name] = {
                    inc = tonumber(inc) or 0,
                    lastSeenTS = tonumber(ts) or 0,
                    daily = decodeDaily(daily)
                }
            end
        elseif tag == "S" then
            local _, ts, cnt = token:match("^(S),([^,]+),([^,]+)$")
            if ts then delta.stats[tonumber(ts) or 0] = tonumber(cnt) or 0 end
        end
    end
    return delta
end

local function encodeSnapshot()
    local db = GAT.db or {}
    local parts = {}
    for name, entry in pairs(db.data or {}) do
        if type(entry) == "table" then
            parts[#parts + 1] = table.concat({
                "F",
                name,
                tostring(entry.total or 0),
                tostring(entry.lastSeenTS or 0),
                tostring(entry.rankIndex or ""),
                tostring(entry.rankName or ""),
                encodeDaily(entry.daily or {})
            }, ",")
        end
    end

    local cutoff = now() - SNAPSHOT_STATS_WINDOW
    for ts, cnt in pairs(db.stats or {}) do
        if ts >= cutoff then
            parts[#parts + 1] = table.concat({ "S", tostring(ts), tostring(cnt) }, ",")
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function decodeSnapshot(payload)
    local snap = { activity = {}, stats = {} }
    if not payload or payload == "" then return snap end
    for token in payload:gmatch("([^;]+)") do
        local tag = token:sub(1, 1)
        if tag == "F" then
            local _, name, total, ts, rankIdx, rankName, daily = token:match("^(F),([^,]+),([^,]*),([^,]*),([^,]*),([^,]*),(.*)$")
            if name then
                snap.activity[name] = {
                    total = tonumber(total) or 0,
                    lastSeenTS = tonumber(ts) or 0,
                    rankIndex = tonumber(rankIdx),
                    rankName = rankName ~= "" and rankName or nil,
                    daily = decodeDaily(daily)
                }
            end
        elseif tag == "S" then
            local _, ts, cnt = token:match("^(S),([^,]+),([^,]+)$")
            if ts then snap.stats[tonumber(ts) or 0] = tonumber(cnt) or 0 end
        end
    end
    return snap
end

local function sendAddonMessage(channel, target, msg)
    if not isInGuildScope() then return end
    C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, target)
end

local function chunkAndSend(msgType, session, fromId, seq, payload, channel, target)
    local totalParts = math.max(1, math.ceil(#payload / MAX_FRAGMENT))
    for idx = 1, totalParts do
        local startIdx = (idx - 1) * MAX_FRAGMENT + 1
        local partPayload = payload:sub(startIdx, startIdx + MAX_FRAGMENT - 1)
        local msg = string.format("T=%s|sid=%s|from=%s|seq=%s|part=%d/%d|data=%s", msgType, session, fromId, seq, idx, totalParts, partPayload)
        sendAddonMessage(channel, target, msg)
    end
end

-- =============================================================================
-- Roles y presencia
-- =============================================================================
local function markPeer(sender, payload)
    local sd = ensureSyncDB()
    sd.peers = sd.peers or {}
    local peer = sd.peers[payload.from] or {}
    peer.name = payload.name or sender
    peer.isMaster = payload.master == "1"
    peer.lastSeen = now()
    sd.peers[payload.from] = peer
end

local function computeRole()
    local sd = ensureSyncDB()
    local masterOnline = GAT:IsMasterBuild()
    local masterPeerId
    local nowt = now()
    for cid, peer in pairs(sd.peers or {}) do
        if peer.isMaster and (nowt - (peer.lastSeen or 0) < MASTER_TIMEOUT) then
            masterOnline = true
            masterPeerId = cid
            break
        end
    end

    local collectorId
    if not masterOnline then
        local candidates = {}
        candidates[#candidates + 1] = sd.clientId
        for cid, peer in pairs(sd.peers or {}) do
            if nowt - (peer.lastSeen or 0) < MASTER_TIMEOUT then
                candidates[#candidates + 1] = cid
            end
        end
        table.sort(candidates)
        collectorId = candidates[1]
    end

    local prevRole = R.role
    R.masterOnline = masterOnline
    R.masterPeerId = masterPeerId
    R.role = (masterOnline and GAT:IsMasterBuild()) and "master"
        or (not masterOnline and sd.clientId == collectorId) and "collector"
        or "idle"

    if prevRole ~= R.role then
        if R.role == "master" then
            GAT:SysMsg("role_state", "GM online: recopilando y sincronizando.", COLOR_BLUE, true)
        elseif R.role == "collector" then
            GAT:SysMsg("role_state", "Ayudante: GM offline • recopilando datos.", COLOR_GREEN, true)
        elseif masterOnline then
            GAT:SysMsg("role_state", "Ayudante: GM online • idle.", COLOR_YELLOW, true)
        else
            GAT:SysMsg("role_state", "Ayudante: GM offline • otro recopila.", COLOR_YELLOW, true)
        end
    end
end

-- =============================================================================
-- Deltas y backlog
-- =============================================================================
function GAT:Sync_RecordDelta_Activity(name, inc, lastSeenTS, dailyKey)
    if not isInGuildScope() then return end
    local sd = ensureSyncDB()
    sd.pending = sd.pending or { activity = {}, stats = {} }
    local a = sd.pending.activity[name] or { inc = 0, lastSeenTS = 0, daily = {} }
    a.inc = (a.inc or 0) + (inc or 0)
    a.lastSeenTS = math.max(a.lastSeenTS or 0, lastSeenTS or 0)
    if dailyKey then
        a.daily[dailyKey] = (a.daily[dailyKey] or 0) + (inc or 0)
    end
    sd.pending.activity[name] = a
end

function GAT:Sync_RecordDelta_Stats(ts, onlineCount)
    if not isInGuildScope() then return end
    local sd = ensureSyncDB()
    sd.pending = sd.pending or { activity = {}, stats = {} }
    sd.pending.stats = sd.pending.stats or {}
    sd.pending.stats[ts] = onlineCount
end

local function queueBacklog(delta)
    local sd = ensureSyncDB()
    sd.pendingSeq = sd.pendingSeq or 1
    local seq = sd.pendingSeq
    sd.pendingSeq = seq + 1
    sd.pendingBacklog[seq] = delta
end

local function flushPending()
    if not isInGuildScope() then return end
    local sd = ensureSyncDB()
    sd.pending = sd.pending or { activity = {}, stats = {} }
    sd.pendingSeq = sd.pendingSeq or 1

    local hasPending = hasValues(sd.pending.activity) or hasValues(sd.pending.stats)
    if not hasPending then return end

    if R.role == "collector" and not R.masterOnline then
        queueBacklog(sd.pending)
        sd.pending = { activity = {}, stats = {} }
    elseif R.role == "master" then
        local payload = encodeDelta(sd.pending)
        chunkAndSend("U", sd.sessionNonce or now(), sd.clientId, sd.pendingSeq or 0, payload, "GUILD")
        sd.pendingSeq = sd.pendingSeq + 1
        sd.pending = { activity = {}, stats = {} }
    end
end

local function applyDelta(delta)
    if not delta then return end
    for name, data in pairs(delta.activity or {}) do
        GAT:MergeEntry(name, {
            total = data.inc or 0,
            lastSeenTS = data.lastSeenTS,
            daily = data.daily
        }, "delta")
    end
    if delta.stats and GAT.db then
        GAT.db.stats = GAT.db.stats or {}
        for ts, cnt in pairs(delta.stats) do
            if not GAT.db.stats[ts] then
                GAT.db.stats[ts] = cnt
            end
        end
    end
end

-- =============================================================================
-- Envío / recepción de backlog
-- =============================================================================
local function markAck(originId, seq)
    local sd = ensureSyncDB()
    sd.pendingBacklog[seq] = nil
end

local function sendOneBacklog()
    if not R.masterOnline or GAT:IsMasterBuild() then return end
    local sd = ensureSyncDB()
    local masterPeer = (sd.peers or {})[R.masterPeerId]
    if not masterPeer or not masterPeer.name then return end
    local seq
    for s in pairs(sd.pendingBacklog or {}) do
        seq = s
        break
    end
    if not seq then return end
    local payload = encodeDelta(sd.pendingBacklog[seq])
    chunkAndSend("BACK", sd.sessionNonce or now(), sd.clientId, seq, payload, "WHISPER", masterPeer.name)
    GAT:SysMsg("tx_state", "Sync en progreso: enviando backlog al GM.", COLOR_YELLOW, false)
end

-- =============================================================================
-- Snapshots
-- =============================================================================
local function applySnapshot(snap)
    if not snap then return end
    for name, entry in pairs(snap.activity or {}) do
        GAT:MergeEntry(name, entry, "snapshot")
    end
    if snap.stats and GAT.db then
        GAT.db.stats = GAT.db.stats or {}
        for ts, cnt in pairs(snap.stats) do
            GAT.db.stats[ts] = cnt
        end
    end
    if GAT.RefreshUI then GAT:RefreshUI() end
end

local function sendSnapshot(target)
    if not target then return end
    local sd = ensureSyncDB()
    sd.peers = sd.peers or {}

    -- Marca "último sync enviado" para UI del GM
    for _, peer in pairs(sd.peers) do
        if peer and (peer.name == target or peer.lastSender == target) then
            peer.lastSyncToPeer = now()
        end
    end

    local payload = encodeSnapshot()
    chunkAndSend("SNAP", sd.sessionNonce or now(), sd.clientId, sd.pendingSeq or 0, payload, "WHISPER", target)
    sd.pendingSeq = sd.pendingSeq + 1
end
function GAT:Sync_Manual()
    if not isInGuildScope() then
        self:SysMsg("manual_sync_guild", "No estás en la guild objetivo.", COLOR_RED, true)
        return
    end
    local sd = ensureSyncDB()
    if self:IsMasterBuild() then
        local any = false
        for _, peer in pairs(sd.peers or {}) do
            if peer.name and (now() - (peer.lastSeen or 0) < MASTER_TIMEOUT) and not peer.isMaster then
                sendSnapshot(peer.name)
                any = true
            end
        end
        self:SysMsg("manual_sync_master", any and "Sync enviado a ayudantes online." or "No hay ayudantes online.", any and COLOR_GREEN or COLOR_YELLOW, false)
        return
    end

    if not R.masterOnline or not R.masterPeerId then
        self:SysMsg("manual_sync_nomaster", "GM no está conectado.", COLOR_RED, true)
        return
    end

    local masterPeer = (sd.peers or {})[R.masterPeerId]
    if masterPeer and masterPeer.name then
        local msg = string.format("T=REQSNAP|from=%s", sd.clientId)
        sendAddonMessage("WHISPER", masterPeer.name, msg)
        self:SysMsg("manual_sync_request", "Solicitando sync al GM...", COLOR_BLUE, false)
    end
end

function GAT:Sync_GetHelpersForUI()
    local sd = ensureSyncDB()
    local list = {}
    local nowt = now()

    local function ago(ts)
        if not ts or ts <= 0 then return "—" end
        local d = nowt - ts
        if d < 0 then d = 0 end
        if d < 60 then return string.format("%ds", d) end
        if d < 3600 then return string.format("%dm", math.floor(d / 60)) end
        return string.format("%dh", math.floor(d / 3600))
    end

    for cid, peer in pairs(sd.peers or {}) do
        if not peer.isMaster then
            local online = (peer.lastSeen and (nowt - peer.lastSeen) < MASTER_TIMEOUT) or false

            local lastSeenAbs = peer.lastSeen and date("%Y-%m-%d %H:%M:%S", peer.lastSeen) or "—"
            local lastSeenRel = ago(peer.lastSeen)

            local lastTo = peer.lastSyncToPeer or 0           -- último SNAP que el GM le envió
            local lastFrom = peer.lastSyncFromPeer or 0       -- última data recibida del ayudante
            local lastAny = math.max(lastTo, lastFrom)

            local syncLine = "Últ.Sync: " .. ago(lastAny)
            local stateLine = online and GAT:Color(COLOR_GREEN, "ONLINE") or GAT:Color(COLOR_RED, "OFFLINE")
            local roleLine = peer.isCollector and "Recolector" or "Ayudante"

            table.insert(list, {
                name = peer.name or cid,                                   -- último personaje visto
                count = stateLine,                                         -- columna Count => estado
                lastSeen = lastSeenAbs .. " (" .. lastSeenRel .. ")",      -- columna Última vez
                lastSeenTS = peer.lastSeen or 0,
                rankIndex = 99,
                rankName = roleLine .. " • " .. syncLine
            })
        end
    end

    table.sort(list, function(a, b) return (a.lastSeenTS or 0) > (b.lastSeenTS or 0) end)
    return list
end
    end
    table.sort(list, function(a, b) return (a.lastSeenTS or 0) > (b.lastSeenTS or 0) end)
    return list
end

function GAT:Sync_BroadcastDelete(name)
    if not self:IsMasterBuild() or not name then return end
    local msg = string.format("T=DEL|name=%s", name)
    sendAddonMessage("GUILD", nil, msg)
end

-- =============================================================================
-- Roles públicos
-- =============================================================================
function GAT:Sync_ShouldCollectChat()
    if not isInGuildScope() then return false end

    -- ✅ MASTER SIEMPRE recopila (nunca dejamos que un estado raro apague el tracking).
    if self:IsMasterBuild() then
        return true
    end

    -- Ayudantes: si el GM está online, solo 1 recopila (según rol). Si no, el recolector.
    if R.masterOnline then
        return false
    end
    return R.role == "collector"
end

function GAT:Sync_ShouldCollectStats()
    return self:Sync_ShouldCollectChat()
end


-- =============================================================================
-- Mensajes entrantes
-- =============================================================================
local function parseLine(msg)
    local meta = {}

    -- ✅ framing robusto: si viene data=, todo lo que esté después puede contener "|"
    local head, data = msg:match("^(.-)|data=(.*)$")
    local src = head or msg

    for token in src:gmatch("[^|]+") do
        local k, v = token:match("([^=]+)=(.*)")
        if k and v then meta[k] = v end
    end

    if data ~= nil then
        meta.data = data
    end

    return meta
end
    end
    return out
end

local function handleComplete(payload, meta, sender)
    local t = meta.T

    local function touchSyncFromPeer()
        local sd = ensureSyncDB()
        if not meta.from then return end
        sd.peers = sd.peers or {}
        local peer = sd.peers[meta.from]
        if peer then
            peer.lastSyncFromPeer = now()
            peer.name = peer.name or sender
            peer.lastSender = sender
        end
    end

    if t == "HB" then
        markPeer(sender, meta)
        return
    end

    if t == "U" then
        local delta = decodeDelta(payload or "")
        applyDelta(delta)
        touchSyncFromPeer()

        if GAT:IsMasterBuild() then
            local key = "rx_u_" .. tostring(meta.from or sender)
            GAT:SysMsg(key, ("Recibiendo data del ayudante: %s"):format(sender), COLOR_BLUE, false)
        end
        return
    end

    if t == "BACK" then
        local delta = decodeDelta(payload or "")
        applyDelta(delta)
        touchSyncFromPeer()

        -- ACK
        local msg = string.format("T=ACK|from=%s|seq=%s", ensureSyncDB().clientId or "0", tostring(meta.seq or "0"))
        sendAddonMessage("WHISPER", sender, msg)

        if GAT:IsMasterBuild() then
            GAT:SysMsg("rx_back_" .. tostring(meta.from or sender),
                ("Backlog recibido de %s (seq %s)."):format(sender, tostring(meta.seq or "0")),
                COLOR_GREEN, true)
        end
        return
    end

    if t == "SNAP" then
        local snap = decodeSnapshot(payload or "")
        applySnapshot(snap)

        if not GAT:IsMasterBuild() then
            local sd = ensureSyncDB()
            sd._lastSnapshotFromMaster = now()
            GAT:SysMsg("rx_snap", "Snapshot recibido del GM. Data sincronizada.", COLOR_GREEN, true)
        end
        return
    end

    if t == "REQSNAP" then
        if GAT:IsMasterBuild() then
            sendSnapshot(sender)
            GAT:SysMsg("tx_snap_to_" .. sender, ("Enviando snapshot a %s..."):format(sender), COLOR_BLUE, false)
        end
        return
    end
end
        return
    end
    if typ == "BACK" then
        if not GAT:IsMasterBuild() then return end
        local delta = decodeDelta(payload)
        local sd = ensureSyncDB()
        local lastSeq = (sd.lastAppliedSeqByPeer or {})[meta.from] or 0
        local seqNum = tonumber(meta.seq) or 0
        if seqNum > lastSeq then
            applyDelta(delta)
            sd.lastAppliedSeqByPeer[meta.from] = seqNum
            chunkAndSend("ACK", sd.sessionNonce or now(), sd.clientId, seqNum, "", "WHISPER", sender)
            GAT:SysMsg("rx_backlog", "Sync recibido de ayudante.", COLOR_GREEN, false)
            sendSnapshot(sender)
        else
            chunkAndSend("ACK", sd.sessionNonce or now(), sd.clientId, seqNum, "", "WHISPER", sender)
        end
        return
    end
    if typ == "SNAP" then
        local snap = decodeSnapshot(payload)
        applySnapshot(snap)
        GAT:SysMsg("snap_ok", "Sync aplicado.", COLOR_GREEN, false)
        return
    end
end

local function handleFragment(sender, attrs)
    local partStr = attrs.part or "1/1"
    local cur, total = partStr:match("^(%d+)%/(%d+)$")
    cur, total = tonumber(cur) or 1, tonumber(total) or 1
    local key = table.concat({ attrs.sid or "0", attrs.seq or "0", attrs.from or sender, attrs.T }, ":")
    R.incoming[key] = R.incoming[key] or { total = total, parts = {}, meta = attrs, sender = sender }
    local bucket = R.incoming[key]
    bucket.total = total
    bucket.parts[cur] = attrs.data or ""
    local complete = true
    for i = 1, bucket.total do
        if not bucket.parts[i] then complete = false break end
    end
    if complete then
        local payload = table.concat(bucket.parts, "")
        R.incoming[key] = nil
        handleComplete(payload, bucket.meta, sender)
    end
end

local function onAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX then return end
    local attrs = parseLine(message)
    if attrs.T == "HB" then
        markPeer(sender, attrs)
        computeRole()
        return
    end

    if attrs.T == "DEL" then
        if GAT.db and GAT.db.data then
            GAT.db.data[attrs.name] = nil
            if GAT.RefreshUI then GAT:RefreshUI() end
        end
        return
    end

    if attrs.T == "REQSNAP" then
        if GAT:IsMasterBuild() then
            sendSnapshot(sender)
        end
        return
    end

    if attrs.T == "ACK" then
        markAck(sender, tonumber(attrs.seq) or 0)
        GAT:SysMsg("tx_state", "Backlog confirmado por GM.", COLOR_GREEN, false)
        return
    end

    if attrs.part then
        handleFragment(sender, attrs)
    end
end

-- =============================================================================
-- Heartbeat y tickers
-- =============================================================================
local function sendHeartbeat()
    if not isInGuildScope() then return end
    local sd = ensureSyncDB()

    local role = "idle"
    if GAT:IsMasterBuild() then role = "master"
    elseif R.role == "collector" then role = "collector"
    end

    local msg = string.format("T=HB|from=%s|master=%s|role=%s|name=%s",
        sd.clientId,
        GAT:IsMasterBuild() and "1" or "0",
        role,
        GAT.fullPlayerName or ""
    )
    sendAddonMessage("GUILD", nil, msg)
end
    local sd = ensureSyncDB()
    local msg = string.format("T=HB|from=%s|master=%s|name=%s", sd.clientId, GAT:IsMasterBuild() and "1" or "0", GAT.fullPlayerName or "")
    sendAddonMessage("GUILD", nil, msg)
end

local function updateHelpersMessage()
    local sd = ensureSyncDB()
    local nowt = now()

    sd._onlineHelpers = sd._onlineHelpers or {}
    local prevSet = sd._onlineHelpers

    local curSet = {}
    local helpers = {}

    for cid, peer in pairs(sd.peers or {}) do
        if not peer.isMaster and (nowt - (peer.lastSeen or 0) < MASTER_TIMEOUT) then
            curSet[cid] = peer.name or cid
            helpers[#helpers + 1] = peer.name or cid
        end
    end

    table.sort(helpers)
    local curCount = #helpers
    local prevCount = sd._helpersCount or 0

    if GAT:IsMasterBuild() then
        for cid, nm in pairs(curSet) do
            if not prevSet[cid] then
                GAT:SysMsg("helper_join_" .. cid, ("Ayudante conectado: %s (Total: %d)"):format(nm, curCount), COLOR_GREEN, true)
            end
        end
        for cid, nm in pairs(prevSet) do
            if not curSet[cid] then
                GAT:SysMsg("helper_left_" .. cid, ("Ayudante desconectado: %s (Total: %d)"):format(nm, curCount), COLOR_RED, true)
            end
        end
    end

    if curCount ~= prevCount then
        local color = COLOR_WHITE
        if curCount > prevCount then color = COLOR_GREEN elseif curCount < prevCount then color = COLOR_RED end
        local msg = "Ayudantes online: " .. GAT:Color(color, tostring(curCount))
        if curCount > 0 then
            msg = msg .. " [" .. table.concat(helpers, ", ") .. "]"
        end
        GAT:SysMsg("helpers_count", msg, COLOR_WHITE, true)
    end

    sd._helpersCount = curCount
    sd._onlineHelpers = curSet
end
    end
    table.sort(helpers)
    local prev = sd._helpersCount or 0
    local color = COLOR_WHITE
    if #helpers > prev then color = COLOR_GREEN elseif #helpers < prev then color = COLOR_RED end
    sd._helpersCount = #helpers
    local msg = "Ayudantes online: " .. GAT:Color(color, tostring(#helpers))
    if #helpers > 0 then
        msg = msg .. " " .. GAT:Color(COLOR_WHITE, "(" .. table.concat(helpers, ", ") .. ")")
    end
    GAT:SysMsg("helpers_online", msg, nil, false)
end

function GAT:Sync_Init()
    if R.initialized then return end
    if not isInGuildScope() then return end
    R.initialized = true
    local sd = ensureSyncDB()
    sd.sessionNonce = sd.sessionNonce or now()
    resetSessionCache()

    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    computeRole()
    self:SysMsg("session_start", "Sync listo. Estado inicial anunciado.", COLOR_BLUE, true)

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local ok, err = pcall(onAddonMessage, ...)
        if not ok then
            GAT:SysMsg("sync_runtime_error", "SYNC ERROR: " .. tostring(err), COLOR_RED, true)
        end
    end
end)
    C_Timer.NewTicker(HEARTBEAT_INTERVAL, function()
        sendHeartbeat()
    end)

    C_Timer.NewTicker(ROLE_TICK_INTERVAL, function()
        computeRole()
        updateHelpersMessage()
    end)

    C_Timer.NewTicker(FLUSH_INTERVAL, function()
        computeRole()
        flushPending()
    end)

    C_Timer.NewTicker(SEND_INTERVAL, function()
        computeRole()
        sendOneBacklog()
    end)
end
