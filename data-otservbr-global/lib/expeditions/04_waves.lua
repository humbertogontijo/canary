ExpeditionWaves = ExpeditionWaves or {}

-- monsterId -> session key
local monsterOwners = {}

local function attackRangeForCreature(name)
	local mType = Game.getMonsterTypeByName(name)
	if not mType then
		return 1
	end
	local distance = mType:targetDistance()
	if type(distance) ~= "number" or distance < 1 then
		return 1
	end
	return math.floor(distance)
end

local function spawnCenter(session)
	local player = session.playerId and Player(session.playerId) or nil
	if player then
		return player:getPosition()
	end
	return session.instance and session.instance.entry or nil
end

local function preSpawnDurationMs()
	local flashes = ExpeditionConfig.PRE_SPAWN_FLASHES or 3
	local interval = ExpeditionConfig.PRE_SPAWN_INTERVAL_MS or 1400
	return flashes * interval, flashes, interval
end

local function lureCount(session)
	local lureMin = ExpeditionConfig.LURE_MIN or 1
	local lureMax = ExpeditionConfig.LURE_MAX or 8
	local count = math.floor(tonumber(session.lure) or ExpeditionConfig.LURE_DEFAULT or lureMin)
	if count < lureMin then
		count = lureMin
	elseif count > lureMax then
		count = lureMax
	end
	return count
end

local function planWave(session, count)
	local catalog = session.catalog
	local center = spawnCenter(session)
	local planned = {}
	for _ = 1, count do
		local name = catalog.creatures[math.random(1, #catalog.creatures)]
		local range = attackRangeForCreature(name)
		local pos = ExpeditionInstance.randomAttackRangeWalkable(session.instance, center, range)
		if pos then
			planned[#planned + 1] = { name = name, pos = Position(pos.x, pos.y, pos.z) }
		end
	end
	return planned
end

local function materialize(session, planned)
	session.waitingEvent = nil
	session.alive = 0
	session.state = "hunting"

	for _, entry in ipairs(planned) do
		local monster = Game.createMonster(entry.name, entry.pos, true, true)
		if monster then
			-- Never flee (runAwayHealth); ranged targetDistance / distance attacking is unchanged.
			monster:runHealth(0)
			monster:registerEvent("ExpeditionMonsterDeath")
			monsterOwners[monster:getId()] = session.key
			session.alive = session.alive + 1
		else
			logger.warn("[Expedition] failed to create monster '{}' at {}", entry.name, entry.pos)
		end
	end

	if session.alive == 0 then
		-- Retry shortly if spawn failed (tiles not ready yet).
		session.state = "waiting"
		session.waitingEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(session.key)
			if s then
				ExpeditionWaves.spawn(s)
			end
		end, 1500)
	else
		ExpeditionManager.broadcastStatus(session)
	end
end

-- Mirror SpawnMonster::scheduleSpawn: flash CONST_ME_TELEPORT at each tile, then place.
local function schedulePreSpawn(sessionKey, planned, remainingMs, intervalMs)
	local session = ExpeditionManager.getSessionByKey(sessionKey)
	if not session or session.state ~= "waiting" then
		return
	end

	if remainingMs <= 0 then
		materialize(session, planned)
		return
	end

	for _, entry in ipairs(planned) do
		entry.pos:sendMagicEffect(CONST_ME_TELEPORT)
	end

	session.waitingEvent = addEvent(function()
		schedulePreSpawn(sessionKey, planned, remainingMs - intervalMs, intervalMs)
	end, intervalMs)
end

function ExpeditionWaves.spawn(session)
	if not session or not session.instance or not session.catalog then
		return
	end

	if session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end

	if not ExpeditionInstance.hasGround(session.instance.entry) then
		ExpeditionInstance.ensureFloor(session.instance)
	end

	local count = lureCount(session)
	-- Snapshot lure for this wave; mid-wave setLure only affects the next spawn.
	session.waveLure = count
	session.wave = (session.wave or 0) + 1
	session.state = "waiting"
	session.alive = 0

	local planned = planWave(session, count)
	if #planned == 0 then
		session.waitingEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(session.key)
			if s then
				ExpeditionWaves.spawn(s)
			end
		end, 1500)
		ExpeditionManager.broadcastStatus(session)
		return
	end

	ExpeditionManager.broadcastStatus(session)

	local durationMs, _, intervalMs = preSpawnDurationMs()
	schedulePreSpawn(session.key, planned, durationMs, intervalMs)
end

function ExpeditionWaves.onMonsterDeath(creature)
	if not creature then
		return
	end
	local monsterId = creature:getId()
	local key = monsterOwners[monsterId]
	monsterOwners[monsterId] = nil
	if not key then
		return
	end
	local session = ExpeditionManager.getSessionByKey(key)
	if not session then
		return
	end

	session.alive = math.max(0, (session.alive or 1) - 1)
	session.kills = (session.kills or 0) + 1
	ExpeditionManager.broadcastStatus(session)

	if session.alive <= 0 and session.state == "hunting" then
		session.state = "waiting"
		local totalDelay = session.catalog.spawnIntervalMs or ExpeditionConfig.WAVE_RESPAWN_MS
		local preMs = preSpawnDurationMs()
		-- Keep overall respawn cadence: wait, then flash, then place.
		local delay = math.max(0, totalDelay - preMs)
		session.waitingEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(key)
			if s and s.state == "waiting" then
				ExpeditionWaves.spawn(s)
			end
		end, delay)
		ExpeditionManager.broadcastStatus(session)
	end
end

function ExpeditionWaves.clear(session)
	if not session then
		return
	end
	if session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end
	if session.instance and session.instance.zone then
		session.instance.zone:removeMonsters()
	end
	for mid, key in pairs(monsterOwners) do
		if key == session.key then
			monsterOwners[mid] = nil
		end
	end
	session.alive = 0
end
