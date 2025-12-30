local addonName = ...
local GAT = _G[addonName]
if not GAT then return end

-- =============================================================================
-- GAT Sync (robusto)
--   - Elección de líder (GM/Master o Helper Collector)
--   - Replicación por deltas en GUILD
--   - Backlog hacia el Master cuando vuelve online
--   - Snapshot completo por WHISPER para corregir desync
--   - Logs útiles (sin spam repetido)
-- =============================================================================

local PREFIX = GAT.ADDON_PREFIX or "GATSYNC"

-- Tuning (conservador para no chocar con límites/throttle de AddonMessage)
local HEARTBEAT_INTERVAL = 5
local ROLE_TICK_INTERVAL  = 3
local MASTER_TIMEOUT      = 22

local FLUSH_INTERVAL      = 6     -- flush de deltas del líder
local OUTBOX_INTERVAL     = 0.25  -- envío 1 msg cada tick (evita throttle)
local BACKLOG_RETRY_SEC   = 6

-- Límite práctico (max 255). Dejamos margen por seguridad.
local MAX_MSG_LEN         = 240

-- Stats incluidos en snapshots (últimos 7 días)
local SNAPSHOT_STATS_WINDOW = 7 * 24 * 3600

-- =============================================================================
-- Utilidades
-- =============================================================================
local function ensureSyncDB()
    return GAT:EnsureSyncDB()
end

local function now()
    return GAT:Now()
end

local function isInGuildScope()
    return GAT:IsInTargetGuild()
end

local function safeCall(tag, fn)
    local ok, err = pcall(fn)
    if not ok then
        GAT:SysMsg("sync_err_" .. tostring(tag), "Sync error (" .. tostring(tag) .. "): " .. tostring(err), true)
    end
end

local function safeSend(channel, target, msg)
    if not isInGuildScope() then return end
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    local ok = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel, target)
    return ok
end

-- URL-ish encoding para campos (evita romper separadores internos)
local function pctEncode(str)
    str = tostring(str or "")
    return (str:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function pctDecode(str)
    str = tostring(str or "")
    return (str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function parseLine(msg)
    local out = {}
    for chunk in tostring(msg or ""):gmatch("[^|]+") do
        local k, v = chunk:match("^(.-)=(.*)$")
        if k then out[k] = v end
    end
    return out
end

local function hasValues(tbl)
    if not tbl then return false end
    for _ in pairs(tbl) do return true end
    return false
end

local function queueOutbox(channel, target, msg)
    local sd = ensureSyncDB()
    sd.outbox = sd.outbox or {}
    sd.outboxHead = sd.outboxHead or 1
    sd.outboxTail = (sd.outboxTail or 0) + 1
    sd.outbox[sd.outboxTail] = { ch = channel, t = target, msg = msg }
end

local function outboxSize()
    local sd = ensureSyncDB()
    local h = sd.outboxHead or 1
    local t = sd.outboxTail or 0
    if t < h then return 0 end
    return (t - h + 1)
end

local function pumpOutbox()
    local sd = ensureSyncDB()
    local h = sd.outboxHead or 1
    local t = sd.outboxTail or 0
    if t < h then return end

    local item = sd.outbox[h]
    sd.outbox[h] = nil
    sd.outboxHead = h + 1

    if item and item.msg then
        safeSend(item.ch, item.t, item.msg)
    end
end

-- =============================================================================
-- Logs (anti-spam, pero visibles cuando cambian)
-- =============================================================================
function GAT:SysMsg(key, text, sessionScoped)
    local sd = ensureSyncDB()
    sd.printCache = sd.printCache or {}
    sd._sessionPrint = sd._sessionPrint or {}

    local cache = sessionScoped and sd._sessionPrint or sd.printCache
    if cache[key] == text then return end
    cache[key] = text
    self:Print(text)
end

local function resetSessionCache()
    local sd = ensureSyncDB()
    sd._sessionPrint = {}
end

local function bumpRev()
    local sd = ensureSyncDB()
    sd.rev = tonumber(sd.rev or 0) + 1
end

-- =============================================================================
-- Serialización (delta / snapshot)
-- =============================================================================
local function encodeDaily(daily)
    if not daily then return "" end
    local parts = {}
    for day, cnt in pairs(daily) do
        parts[#parts + 1] = day .. ":" .. tostring(cnt or 0)
    end
    table.sort(parts)
    -- Se encodea como CAMPO (pctEncode), así que "|" no rompe el mensaje.
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

local function splitN(s, sep, n)
    local out = {}
    local cur = 1
    for i = 1, n - 1 do
        local p = s:find(sep, cur, true)
        if not p then break end
        out[i] = s:sub(cur, p - 1)
        cur = p + #sep
    end
    out[#out + 1] = s:sub(cur)
    return out
end

-- Delta payload:
-- Sections: "A:<...>;... \n S:<...>;..."
-- Activity token fields (7):
--   nameEnc,total,lastSeenTS,rankIndex,rankNameEnc,lastMessageEnc,dailyEnc
local function encodeDelta(delta)
    delta = delta or {}
    local aParts = {}
    if delta.activity then
        for name, e in pairs(delta.activity) do
            local dailyStr = encodeDaily(e.daily or {})
            aParts[#aParts + 1] = table.concat({
                pctEncode(name or ""),
                tostring(e.total or 0),
                tostring(e.lastSeenTS or 0),
                tostring(e.rankIndex or 99),
                pctEncode(e.rankName or ""),
                pctEncode(e.lastMessage or ""),
                pctEncode(dailyStr)
            }, ",")
        end
    end
    local sParts = {}
    if delta.stats then
        for ts, cnt in pairs(delta.stats) do
            sParts[#sParts + 1] = tostring(ts) .. "," .. tostring(cnt or 0)
        end
    end
    table.sort(aParts)
    table.sort(sParts)
    return "A:" .. table.concat(aParts, ";") .. "\nS:" .. table.concat(sParts, ";")
end

local function decodeDelta(payload)
    payload = tostring(payload or "")
    local out = { activity = {}, stats = {} }

    local aLine = payload:match("A:(.-)\nS:") or payload:match("^A:(.*)$") or ""
    local sLine = payload:match("\nS:(.*)$") or ""

    if aLine ~= "" then
        for token in aLine:gmatch("([^;]+)") do
            local parts = splitN(token, ",", 7)
            if #parts >= 7 then
                local name = pctDecode(parts[1] or "")
                if name and name ~= "" then
                    local total      = tonumber(parts[2] or 0) or 0
                    local lastSeenTS = tonumber(parts[3] or 0) or 0
                    local rankIndex  = tonumber(parts[4] or 99) or 99
                    local rankName   = pctDecode(parts[5] or "")
                    local lastMsg    = pctDecode(parts[6] or "")
                    local dailyStr   = pctDecode(parts[7] or "")
                    out.activity[name] = {
                        total = total,
                        lastSeenTS = lastSeenTS,
                        rankIndex = rankIndex,
                        rankName = rankName or "",
                        lastMessage = lastMsg or "",
                        daily = decodeDaily(dailyStr)
                    }
                end
            end
        end
    end

    if sLine ~= "" then
        for token in sLine:gmatch("([^;]+)") do
            local ts, cnt = token:match("^(%d+),(%d+)$")
            if ts and cnt then
                out.stats[tonumber(ts)] = tonumber(cnt) or 0
            end
        end
    end

    return out
end

local function encodeSnapshot()
    GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
    local db = GAT.db

    local aParts = {}
    for name, entry in pairs(db.data or {}) do
        if type(entry) == "number" then
            entry = { total = entry, lastSeenTS = 0, rankIndex = 99, rankName = "—", lastMessage = "", daily = {} }
        end
        local dailyStr = encodeDaily(entry.daily or {})
        aParts[#aParts + 1] = table.concat({
            pctEncode(name or ""),
            tostring(entry.total or 0),
            tostring(entry.lastSeenTS or 0),
            tostring(entry.rankIndex or 99),
            pctEncode(entry.rankName or ""),
            pctEncode(entry.lastMessage or ""),
            pctEncode(dailyStr)
        }, ",")
    end
    table.sort(aParts)

    local sParts = {}
    local cutoff = now() - SNAPSHOT_STATS_WINDOW
    for ts, cnt in pairs(db.stats or {}) do
        if tonumber(ts) and tonumber(ts) >= cutoff then
            sParts[#sParts + 1] = tostring(ts) .. "," .. tostring(cnt or 0)
        end
    end
    table.sort(sParts)

    return "A:" .. table.concat(aParts, ";") .. "\nS:" .. table.concat(sParts, ";")
end

local function applyDelta(delta)
    if not delta then return end
    GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
    GAT.db.data = GAT.db.data or {}
    GAT.db.stats = GAT.db.stats or {}

    if delta.activity then
        for name, e in pairs(delta.activity) do
            if GAT.MergeEntry then
                GAT:MergeEntry(name, e, "delta")
            else
                local cur = GAT.db.data[name] or { total = 0, lastSeenTS = 0, daily = {} }
                cur.total = (cur.total or 0) + (e.total or 0)
                if e.lastSeenTS and e.lastSeenTS > (cur.lastSeenTS or 0) then
                    cur.lastSeenTS = e.lastSeenTS
                    cur.lastSeen = date("%Y-%m-%d %I:%M %p", e.lastSeenTS)
                    cur.lastMessage = e.lastMessage or cur.lastMessage
                end
                cur.daily = cur.daily or {}
                if e.daily then
                    for d, c in pairs(e.daily) do
                        cur.daily[d] = (cur.daily[d] or 0) + (c or 0)
                    end
                end
                cur.rankName = cur.rankName or e.rankName
                cur.rankIndex = cur.rankIndex or e.rankIndex
                GAT.db.data[name] = cur
            end
        end
    end

    if delta.stats then
        for ts, cnt in pairs(delta.stats) do
            if ts and cnt then
                GAT.db.stats[ts] = cnt
            end
        end
    end

    bumpRev()
end

local function applySnapshot(payload)
    local snap = decodeDelta(payload) -- mismo formato A/S
    GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
    local db = GAT.db
    db.data = db.data or {}
    db.stats = db.stats or {}

    wipe(db.data)
    wipe(db.stats)

    if snap.activity then
        for name, e in pairs(snap.activity) do
            db.data[name] = {
                total = e.total or 0,
                lastSeenTS = e.lastSeenTS or 0,
                lastSeen = (e.lastSeenTS and e.lastSeenTS > 0) and date("%Y-%m-%d %I:%M %p", e.lastSeenTS) or "",
                lastMessage = e.lastMessage or "",
                daily = e.daily or {},
                rankIndex = e.rankIndex or 99,
                rankName = (e.rankName and e.rankName ~= "") and e.rankName or "—"
            }
        end
    end

    if snap.stats then
        for ts, cnt in pairs(snap.stats) do
            db.stats[ts] = cnt
        end
    end

    bumpRev()
    if GAT.RefreshUI then GAT:RefreshUI() end
end

-- =============================================================================
-- Fragmentación / envío (outbox + tamaños seguros)
-- =============================================================================
local function computeHeader(msgType, sid, fromId, seq, part, total, extra)
    local header = string.format("T=%s|sid=%s|from=%s|seq=%s|part=%d/%d",
        msgType, sid, fromId, seq, part, total
    )
    if extra and extra.rev  then header = header .. "|rev=" .. tostring(extra.rev) end
    if extra and extra.to   then header = header .. "|to=" .. tostring(extra.to) end
    if extra and extra.bseq then header = header .. "|bseq=" .. tostring(extra.bseq) end
    header = header .. "|data="
    return header
end

local function computeMaxPayload(header)
    local maxPayload = MAX_MSG_LEN - #header
    if maxPayload < 40 then maxPayload = 40 end
    return maxPayload
end

local function enqueuePayloadMessage(msgType, payloadRaw, channel, target, extra)
    local sd = ensureSyncDB()
    sd.msgSeq = (sd.msgSeq or 0) + 1
    local seq = sd.msgSeq

    sd.sidCounter = (sd.sidCounter or 0) + 1
    local sid = tostring(sd.sessionNonce or 0) .. "-" .. tostring(sd.sidCounter)

    -- Importante: payload NO puede contener "|" (rompe parseLine). Usamos pctEncode por campo.
    local payload = tostring(payloadRaw or "")
    if payload:find("|", 1, true) then
        payload = payload:gsub("|", "%%7C") -- seguro extra
    end

    local guess = 1
    for _ = 1, 4 do
        local header = computeHeader(msgType, sid, sd.clientId, seq, guess, guess, extra)
        local maxPayload = computeMaxPayload(header)
        local total = math.max(1, math.ceil(#payload / maxPayload))
        if total == guess then break end
        guess = total
    end
    local totalParts = guess

    if msgType == "SNAP" then
        GAT:SysMsg("sync_tx_snap_" .. tostring(target or "guild"), string.format("Sync: enviando snapshot → %s (%d partes)", tostring(target or "GUILD"), totalParts), true)
    elseif msgType == "U" then
        GAT:SysMsg("sync_tx_u", string.format("Sync: publicando delta (%d partes) | Q:%d", totalParts, outboxSize()), true)
    elseif msgType == "BACK" then
        GAT:SysMsg("sync_tx_back_" .. tostring(target or "?"), string.format("Sync: enviando backlog → %s (%d partes)", tostring(target or "?"), totalParts), true)
    end

    for part = 1, totalParts do
        local header = computeHeader(msgType, sid, sd.clientId, seq, part, totalParts, extra)
        local maxPayload = computeMaxPayload(header)
        local startIdx = (part - 1) * maxPayload + 1
        local frag = payload:sub(startIdx, startIdx + maxPayload - 1)
        queueOutbox(channel, target, header .. frag)
    end

    return sid, seq, totalParts
end

-- =============================================================================
-- Peers / roles
-- =============================================================================
local function markPeer(sender, payload)
    local sd = ensureSyncDB()
    sd.peers = sd.peers or {}
    local cid = payload.from
    if not cid or cid == "" then return end

    local isNew = (sd.peers[cid] == nil)
    local peer = sd.peers[cid] or {}

    peer.sender = sender or peer.sender
    local pname = payload.name
    if pname == "" then pname = nil end
    peer.name   = pname or peer.name or sender
    peer.isMaster = payload.master == "1"
    peer.rev = tonumber(payload.rev or peer.rev or 0) or 0
    peer.lastSeen = now()

    sd.peers[cid] = peer

    -- Auto-snapshot: si soy Master build y aparece un helper nuevo, le empujo snapshot.
    if isNew and GAT:IsMasterBuild() then
        sd._autoSnapSent = sd._autoSnapSent or {}
        if not sd._autoSnapSent[cid] then
            sd._autoSnapSent[cid] = now()
            C_Timer.After(3, function()
                if GAT.Sync_SendSnapshotTo then
                    GAT:Sync_SendSnapshotTo(peer.sender or peer.name)
                end
            end)
        end
    end
end

local function prunePeers()
    local sd = ensureSyncDB()
    local t = now()
    for cid, peer in pairs(sd.peers or {}) do
        if peer.lastSeen and (t - peer.lastSeen) > (MASTER_TIMEOUT * 3) then
            sd.peers[cid] = nil
        end
    end
end

local function computeRole()
    local sd = ensureSyncDB()
    prunePeers()

    local t = now()

    local masterOnline = GAT:IsMasterBuild()
    local masterPeerId = nil
    if not masterOnline then
        for cid, peer in pairs(sd.peers or {}) do
            if peer.isMaster and peer.lastSeen and (t - peer.lastSeen) <= MASTER_TIMEOUT then
                masterOnline = true
                masterPeerId = cid
                break
            end
        end
    end
    sd.masterOnline = masterOnline
    sd.masterPeerId = masterPeerId

    -- Presence transitions (informative)
    if sd._prevMasterOnline ~= nil and sd._prevMasterOnline ~= masterOnline then
        if masterOnline then
            GAT:Print("Sync: GM detectado (ONLINE).")
        else
            GAT:Print("Sync: GM no detectado (OFFLINE).")
        end
    end
    sd._prevMasterOnline = masterOnline

    -- Si el ayudante tocó Sync ANTES de ver el heartbeat del GM, auto-solicita snapshot cuando el GM aparezca.
    if (not GAT:IsMasterBuild()) and masterOnline and sd._manualSyncWantedAt and (t - sd._manualSyncWantedAt) <= 30 then
        local master = (sd.peers or {})[sd.masterPeerId or ""]
        if master and master.sender then
            local req = string.format("T=REQSNAP|from=%s", tostring(sd.clientId))
            queueOutbox("WHISPER", master.sender, req)
            GAT:Print("Sync: GM detectado. Solicitando snapshot al GM...")
        end
        sd._manualSyncWantedAt = nil
    end

    local newRole = sd.role or "idle"

    if masterOnline then
        newRole = GAT:IsMasterBuild() and "master" or "idle"
    else
        local candidates = { sd.clientId }
        for cid, peer in pairs(sd.peers or {}) do
            if not peer.isMaster and peer.lastSeen and (t - peer.lastSeen) <= MASTER_TIMEOUT then
                candidates[#candidates + 1] = cid
            end
        end
        table.sort(candidates)
        newRole = (candidates[1] == sd.clientId) and "collector" or "idle"
    end

    if newRole ~= sd.role then
        sd.role = newRole
        resetSessionCache()
        GAT:Print("Sync: rol = " .. tostring(newRole) .. (sd.masterOnline and " (GM online)" or " (GM OFF)"))
    end

    return newRole
end

local function getMasterPeer()
    local sd = ensureSyncDB()
    if not sd.masterPeerId then return nil end
    return (sd.peers or {})[sd.masterPeerId]
end

-- =============================================================================
-- Incoming fragments
-- =============================================================================
local function ensureIncoming()
    local sd = ensureSyncDB()
    sd.incoming = sd.incoming or {}
    return sd.incoming
end

local function incomingKey(meta)
    return tostring(meta.sid or "") .. ":" .. tostring(meta.seq or "") .. ":" .. tostring(meta.from or "") .. ":" .. tostring(meta.T or "")
end

local function cleanupIncoming()
    local sd = ensureSyncDB()
    local inc = ensureIncoming()
    local t = now()
    for k, bucket in pairs(inc) do
        if bucket.lastAt and (t - bucket.lastAt) > 25 then
            inc[k] = nil
            GAT:SysMsg("sync_rx_timeout_" .. k, "Sync: transferencia incompleta (timeout). Reintenta /gat → Sync.", true)
        end
    end
end

local function handleComplete(msgType, payload, meta, sender)
    local sd = ensureSyncDB()

    if msgType == "U" then
        if meta.from == sd.clientId then return end
        local delta = decodeDelta(payload)
        applyDelta(delta)
        return
    end

    if msgType == "BACK" then
        if not GAT:IsMasterBuild() then return end
        if meta.from == sd.clientId then return end
        local delta = decodeDelta(payload)
        applyDelta(delta)

        local bseq = tonumber(meta.bseq or "")
        local ack = string.format("T=ACK|from=%s|bseq=%s", tostring(sd.clientId), tostring(bseq or ""))
        queueOutbox("WHISPER", sender, ack)
        GAT:SysMsg("sync_back_applied_" .. tostring(sender), "Sync: backlog aplicado desde " .. tostring(sender), true)
        return
    end

    if msgType == "SNAP" then
        applySnapshot(payload)
        sd.lastSnapshotAppliedAt = now()
        GAT:SysMsg("sync_rx_snap", "Sync: snapshot aplicado ✔", true)

        local master = getMasterPeer()
        if master and master.sender then
            local okMsg = string.format("T=SNAPOK|from=%s|ts=%d|rev=%s", tostring(sd.clientId), now(), tostring(sd.rev or 0))
            queueOutbox("WHISPER", master.sender, okMsg)
        end
        return
    end
end

local function onFragment(meta, sender)
    local inc = ensureIncoming()
    local key = incomingKey(meta)

    local bucket = inc[key] or { parts = {}, got = 0, total = 0 }
    bucket.lastAt = now()

    local p, total = tostring(meta.part or ""):match("^(%d+)%/(%d+)$")
    local part = tonumber(p)
    local tot  = tonumber(total)

    if not part or not tot then return end
    bucket.total = (bucket.total > 0) and bucket.total or tot

    if not bucket.parts[part] then
        bucket.parts[part] = meta.data or ""
        bucket.got = bucket.got + 1
    end

    inc[key] = bucket

    if bucket.got >= bucket.total then
        local merged = table.concat(bucket.parts, "")
        inc[key] = nil
        handleComplete(meta.T, merged, meta, sender)
    else
        if meta.T == "SNAP" and bucket.got == 1 then
            GAT:SysMsg("sync_rx_snap_begin", string.format("Sync: recibiendo snapshot (%d partes) ...", bucket.total), true)
        end
    end
end

-- =============================================================================
-- Envíos: Heartbeat / deltas / backlog / snapshot / delete
-- =============================================================================
local function sendHeartbeat()
    local sd = ensureSyncDB()
    local msg = string.format("T=HB|from=%s|master=%s|rev=%s|name=%s",
        tostring(sd.clientId),
        GAT:IsMasterBuild() and "1" or "0",
        tostring(sd.rev or 0),
        tostring(GAT.fullPlayerName or "")
    )
    queueOutbox("GUILD", nil, msg)
end

local function flushPending()
    local sd = ensureSyncDB()
    if not sd.pending then return end
    if not hasValues(sd.pending.activity) and not hasValues(sd.pending.stats) then return end

    local role = sd.role or "idle"
    if role ~= "master" and role ~= "collector" then
        return
    end

    local delta = { activity = sd.pending.activity or {}, stats = sd.pending.stats or {} }
    local payload = encodeDelta(delta)

    enqueuePayloadMessage("U", payload, "GUILD", nil, { rev = sd.rev or 0 })

    if role == "collector" and not sd.masterOnline then
        sd.backlog = sd.backlog or {}
        sd.backlogSeq = (sd.backlogSeq or 0) + 1
        sd.backlog[sd.backlogSeq] = payload
    end

    sd.pending.activity = {}
    sd.pending.stats = {}
end

local function trySendBacklog()
    local sd = ensureSyncDB()
    if GAT:IsMasterBuild() then return end
    if not sd.masterOnline then return end
    if not sd.backlog or not hasValues(sd.backlog) then return end

    local master = getMasterPeer()
    if not master or not master.sender then return end

    if sd.backlogInFlight then
        if (now() - (sd.backlogInFlightAt or 0)) > BACKLOG_RETRY_SEC then
            local bseq = sd.backlogInFlight
            local payload = sd.backlog[bseq]
            if payload then
                enqueuePayloadMessage("BACK", payload, "WHISPER", master.sender, { rev = sd.rev or 0, bseq = bseq })
                sd.backlogInFlightAt = now()
                GAT:SysMsg("sync_back_retry", "Sync: reintentando backlog (bseq " .. tostring(bseq) .. ")", true)
            else
                sd.backlogInFlight = nil
            end
        end
        return
    end

    local minSeq = nil
    for bseq in pairs(sd.backlog) do
        if not minSeq or bseq < minSeq then minSeq = bseq end
    end
    if not minSeq then return end

    sd.backlogInFlight = minSeq
    sd.backlogInFlightAt = now()
    enqueuePayloadMessage("BACK", sd.backlog[minSeq], "WHISPER", master.sender, { rev = sd.rev or 0, bseq = minSeq })
end

function GAT:Sync_SendSnapshotTo(target)
    if not target or target == "" then return end
    if not self:IsMasterBuild() then return end

    local sd = ensureSyncDB()
    local payload = encodeSnapshot()
    enqueuePayloadMessage("SNAP", payload, "WHISPER", target, { rev = sd.rev or 0, to = target })
end

function GAT:Sync_BroadcastDelete(name)
    if not name or name == "" then return end
    local sd = ensureSyncDB()
    local msg = string.format("T=DEL|from=%s|name=%s", tostring(sd.clientId), pctEncode(name))
    queueOutbox("GUILD", nil, msg)
end

-- =============================================================================
-- API usada por data.lua / stats.lua
-- =============================================================================
function GAT:Sync_RecordDelta_Activity(fullName, inc, lastSeenTS, dayKey)
    local sd = ensureSyncDB()
    sd.pending = sd.pending or { activity = {}, stats = {} }
    sd.pending.activity = sd.pending.activity or {}

    local e = sd.pending.activity[fullName] or { total = 0, lastSeenTS = 0, daily = {} }
    e.total = (e.total or 0) + (inc or 0)
    e.lastSeenTS = math.max(e.lastSeenTS or 0, tonumber(lastSeenTS or 0) or 0)

    -- If we have a local DB entry, preserve its rank/lastMessage when appropriate
    if GAT.db and GAT.db.data and GAT.db.data[fullName] then
        e.rankIndex = e.rankIndex or GAT.db.data[fullName].rankIndex
        e.rankName  = e.rankName  or GAT.db.data[fullName].rankName
        e.lastMessage = e.lastMessage or GAT.db.data[fullName].lastMessage
    end

    e.daily = e.daily or {}
    if dayKey then
        e.daily[dayKey] = (e.daily[dayKey] or 0) + (inc or 0)
    end

    sd.pending.activity[fullName] = e
end

function GAT:Sync_RecordDelta_Stats(ts, onlineCount)
    local sd = ensureSyncDB()
    sd.pending = sd.pending or { activity = {}, stats = {} }
    sd.pending.stats = sd.pending.stats or {}
    if ts then
        sd.pending.stats[tonumber(ts)] = tonumber(onlineCount) or 0
    end
end

function GAT:Sync_ShouldCollectChat()
    local sd = ensureSyncDB()
    local r = sd.role or "idle"
    return (r == "master" or r == "collector")
end

function GAT:Sync_ShouldCollectStats()
    local sd = ensureSyncDB()
    local r = sd.role or "idle"
    return (r == "master" or r == "collector")
end

-- =============================================================================
-- Manual sync (botón)
-- =============================================================================
function GAT:Sync_Manual()
    local sd = ensureSyncDB()
    if self:IsMasterBuild() then
        local count = 0
        for _, peer in pairs(sd.peers or {}) do
            if peer and not peer.isMaster and peer.sender then
                count = count + 1
                self:Sync_SendSnapshotTo(peer.sender)
            end
        end
        self:Print("Sync manual: enviando snapshot a " .. tostring(count) .. " ayudantes.")
    else
        local master = getMasterPeer()
        if not master or not master.sender then
            sd._manualSyncWantedAt = now()
            self:Print("Sync: no veo al GM aún (esperando heartbeat). Si el GM está online, espera unos segundos y vuelve a tocar Sync.")
            return
        end
        local req = string.format("T=REQSNAP|from=%s", tostring(sd.clientId))
        queueOutbox("WHISPER", master.sender, req)
        self:Print("Sync: solicitando snapshot al GM...")
    end
end

-- =============================================================================
-- Estado para UI
-- =============================================================================
function GAT:Sync_GetHelpersForUI()
    local sd = ensureSyncDB()
    local t = now()
    local out = {}
    for cid, peer in pairs(sd.peers or {}) do
        out[#out + 1] = {
            clientId = cid,
            name = peer.name or peer.sender or "?",
            sender = peer.sender or peer.name or "?",
            isMaster = peer.isMaster == true,
            lastSeenAgo = peer.lastSeen and (t - peer.lastSeen) or 9999,
            rev = peer.rev or 0,
            lastSyncTS = peer.lastSyncTS or 0,
        }
    end
    table.sort(out, function(a,b)
        if a.isMaster ~= b.isMaster then return a.isMaster end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

function GAT:Sync_GetStatusLine()
    local sd = ensureSyncDB()
    local role = sd.role or "idle"
    local mo = sd.masterOnline and "GM:ON" or "GM:OFF"
    local q = outboxSize()
    local rev = sd.rev or 0
    return string.format("Sync:%s %s rev:%d Q:%d", role, mo, rev, q)
end

-- =============================================================================
-- Event loop
-- =============================================================================
local f
local hbTicker, roleTicker, flushTicker, outTicker, cleanupTicker

local function onAddonMessage(prefix, msg, channel, sender)
    local ok, err = pcall(function()
    if prefix ~= PREFIX then return end
    if not msg or msg == "" then return end

    local meta = parseLine(msg)
    local t = meta.T

    if t == "HB" then
        markPeer(sender, meta)
        return
    end

    if t == "REQSNAP" then
        if GAT:IsMasterBuild() then
            GAT:SysMsg("sync_req_from_" .. tostring(sender), "Sync: snapshot solicitado por " .. tostring(sender), true)
            GAT:Sync_SendSnapshotTo(sender)
        end
        return
    end

    if t == "ACK" then
        local sd = ensureSyncDB()
        local bseq = tonumber(meta.bseq or "")
        if bseq and sd.backlogInFlight and tonumber(sd.backlogInFlight) == bseq then
            sd.backlog[bseq] = nil
            sd.backlogInFlight = nil
            sd.backlogInFlightAt = nil
            GAT:SysMsg("sync_back_ack", "Sync: backlog ACK ✔ (bseq " .. tostring(bseq) .. ")", true)
        end
        return
    end

    if t == "SNAPOK" and GAT:IsMasterBuild() then
        local sd = ensureSyncDB()
        if meta.from and sd.peers and sd.peers[meta.from] then
            sd.peers[meta.from].lastSyncTS = tonumber(meta.ts or 0) or 0
            sd.peers[meta.from].rev = tonumber(meta.rev or sd.peers[meta.from].rev or 0) or 0
        end
        return
    end

    if t == "DEL" then
        local name = pctDecode(meta.name or "")
        if name and name ~= "" and GAT.db and GAT.db.data then
            GAT.db.data[name] = nil
            if GAT.RefreshUI then GAT:RefreshUI() end
            GAT:SysMsg("sync_del_" .. name, "Sync: eliminado " .. tostring(name), true)
        end
        return
    end

    if t == "U" or t == "BACK" or t == "SNAP" then
        onFragment(meta, sender)
        return
    end
    end)
    if not ok then
        GAT:SysMsg("sync_err_msg", "Sync error (msg): " .. tostring(err), true)
    end
end

-- =============================================================================
-- Init
-- =============================================================================
function GAT:Sync_Init()
    local sd = ensureSyncDB()

    sd.sessionNonce = sd.sessionNonce or now()
    sd.rev = tonumber(sd.rev or 0) or 0
    sd.pending = sd.pending or { activity = {}, stats = {} }
    sd.peers = sd.peers or {}
    sd.backlog = sd.backlog or {}

    if sd._syncInitialized then return end
    sd._syncInitialized = true

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end

    f = f or CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            onAddonMessage(...)
        elseif event == "PLAYER_ENTERING_WORLD" then
            sd._enterWorldCount = (sd._enterWorldCount or 0) + 1
            resetSessionCache()
            self:SysMsg("sync_enter_world", "Sync: activo (loading #" .. tostring(sd._enterWorldCount) .. ") | " .. (self.Sync_GetStatusLine and self:Sync_GetStatusLine() or ""), true)

            -- Auto-sync inicial: si soy helper y veo al GM, pido snapshot (una vez por sesión/cooldown)
            local role = computeRole()
            if not self:IsMasterBuild() and role == "idle" and sd.masterOnline then
                sd._autoReqAt = sd._autoReqAt or 0
                if (now() - sd._autoReqAt) > 30 and (sd.lastSnapshotAppliedAt or 0) == 0 then
                    sd._autoReqAt = now()
                    local master = getMasterPeer()
                    if master and master.sender then
                        local req = string.format("T=REQSNAP|from=%s", tostring(sd.clientId))
                        queueOutbox("WHISPER", master.sender, req)
                        self:SysMsg("sync_auto_req", "Sync: auto-solicitando snapshot al GM...", true)
                    end
                end
            end
        end
    end)

    hbTicker = hbTicker or C_Timer.NewTicker(HEARTBEAT_INTERVAL, function()
        safeCall("hb", function()
            computeRole()
            sendHeartbeat()
        end)
    end)

    roleTicker = roleTicker or C_Timer.NewTicker(ROLE_TICK_INTERVAL, function()
        safeCall("role", function()
            computeRole()
            trySendBacklog()
        end)
    end)

    flushTicker = flushTicker or C_Timer.NewTicker(FLUSH_INTERVAL, function()
        safeCall("flush", function()
            computeRole()
            flushPending()
        end)
    end)

    outTicker = outTicker or C_Timer.NewTicker(OUTBOX_INTERVAL, function()
        safeCall("out", function()
            pumpOutbox()
        end)
    end)

    cleanupTicker = cleanupTicker or C_Timer.NewTicker(3, function()
        safeCall("cleanup", function()
            cleanupIncoming()
        end)
    end)

    self:SysMsg("sync_init", "Sync: inicializado | " .. (self.Sync_GetStatusLine and self:Sync_GetStatusLine() or ""), true)
end
