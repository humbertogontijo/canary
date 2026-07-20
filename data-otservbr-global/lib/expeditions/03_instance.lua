ExpeditionInstance = {}

local freeSlots = {}
local usedSlots = {}

local function ensureSlots()
	if #freeSlots > 0 then
		return
	end
	for i = 0, ExpeditionConfig.MAX_SLOTS - 1 do
		if not usedSlots[i] then
			freeSlots[#freeSlots + 1] = i
		end
	end
end

function ExpeditionInstance.resetSlots()
	freeSlots = {}
	usedSlots = {}
	ensureSlots()
end

ensureSlots()

-- Grid of private slots far apart (SLOT_SIZE >> client viewport).
local function slotOrigin(slot)
	local cols = 8
	local col = slot % cols
	local row = math.floor(slot / cols)
	local size = ExpeditionConfig.SLOT_SIZE
	return Position(ExpeditionConfig.INSTANCE_BASE_X + col * size, ExpeditionConfig.INSTANCE_BASE_Y + row * size, ExpeditionConfig.INSTANCE_Z)
end

function ExpeditionInstance.allocate()
	ensureSlots()
	local slot = table.remove(freeSlots, 1)
	if slot == nil then
		return nil
	end
	usedSlots[slot] = true
	return slot, slotOrigin(slot)
end

function ExpeditionInstance.free(slot)
	if slot == nil or not usedSlots[slot] then
		return
	end
	usedSlots[slot] = nil
	freeSlots[#freeSlots + 1] = slot
end

function ExpeditionInstance.origin(slot)
	return slotOrigin(slot)
end

function ExpeditionInstance.isInReservedArea(pos)
	local size = ExpeditionConfig.SLOT_SIZE
	local cols = 8
	local rows = math.ceil(ExpeditionConfig.MAX_SLOTS / cols)
	local maxX = ExpeditionConfig.INSTANCE_BASE_X + cols * size
	local maxY = ExpeditionConfig.INSTANCE_BASE_Y + rows * size
	return pos.z == ExpeditionConfig.INSTANCE_Z and pos.x >= ExpeditionConfig.INSTANCE_BASE_X and pos.x < maxX and pos.y >= ExpeditionConfig.INSTANCE_BASE_Y and pos.y < maxY
end

local function stampBorder(fromPos, width, height)
	local wallId = ExpeditionConfig.BORDER_ITEM_ID
	local z = fromPos.z
	for x = fromPos.x, fromPos.x + width - 1 do
		for _, y in ipairs({ fromPos.y, fromPos.y + height - 1 }) do
			local tile = Tile(Position(x, y, z)) or Game.createTile(Position(x, y, z), true)
			if tile then
				Game.createItem(wallId, 1, Position(x, y, z))
			end
		end
	end
	for y = fromPos.y, fromPos.y + height - 1 do
		for _, x in ipairs({ fromPos.x, fromPos.x + width - 1 }) do
			local tile = Tile(Position(x, y, z)) or Game.createTile(Position(x, y, z), true)
			if tile then
				Game.createItem(wallId, 1, Position(x, y, z))
			end
		end
	end
end

function ExpeditionInstance.build(slot, region, seed)
	local manifest = ExpeditionConfig.loadManifest(region)
	if not manifest or not manifest.chunks or #manifest.chunks == 0 then
		return nil, "missing expedition chunk manifest for " .. tostring(region)
	end

	local origin = slotOrigin(slot)
	local mapW = ExpeditionConfig.MAP_WIDTH
	local mapH = ExpeditionConfig.MAP_HEIGHT
	local chunkWidth = manifest.chunkWidth or manifest.chunkSize or mapW
	local chunkHeight = manifest.chunkHeight or manifest.chunkSize or mapH
	local byLocal = {}
	local maxLX, maxLY = 0, 0
	for _, chunk in ipairs(manifest.chunks) do
		byLocal[chunk.localX .. "," .. chunk.localY] = chunk
		if chunk.localX > maxLX then
			maxLX = chunk.localX
		end
		if chunk.localY > maxLY then
			maxLY = chunk.localY
		end
	end

	-- Deterministic layout: stamp all available chunks in grid order (seed reserved for future variants).
	math.randomseed(seed or os.time())
	local dir = ExpeditionConfig.chunkDir(region)
	for ly = 0, maxLY do
		for lx = 0, maxLX do
			local chunk = byLocal[lx .. "," .. ly]
			if chunk then
				local path = dir .. "/" .. chunk.file
				-- Chunk OTBMs are authored at z=0; offset z places them on the instance floor.
				local stampAt = Position(origin.x + 1 + lx * chunkWidth, origin.y + 1 + ly * chunkHeight, origin.z)
				Game.loadMapChunk(path, stampAt, false)
			end
		end
	end

	-- Instance size is always the client viewport (+ 1-tile border), not the chunk grid.
	local width = mapW + 2
	local height = mapH + 2
	stampBorder(origin, width, height)

	local zoneName = "expedition-slot-" .. slot
	local zone = Zone(zoneName)
	zone:addArea(origin, Position(origin.x + width - 1, origin.y + height - 1, origin.z))

	-- Player stands at the viewport center and never walks.
	local entry = Position(origin.x + 1 + math.floor(mapW / 2), origin.y + 1 + math.floor(mapH / 2), origin.z)
	local centerChunk = byLocal[math.floor(maxLX / 2) .. "," .. math.floor(maxLY / 2)]
	if centerChunk and centerChunk.walkableEntries and centerChunk.walkableEntries[1] then
		local we = centerChunk.walkableEntries[1]
		local wx = origin.x + 1 + centerChunk.localX * chunkWidth + we.x
		local wy = origin.y + 1 + centerChunk.localY * chunkHeight + we.y
		-- Prefer chunk entry only when it lands inside the viewport floor.
		if wx > origin.x and wx < origin.x + width - 1 and wy > origin.y and wy < origin.y + height - 1 then
			entry = Position(wx, wy, origin.z)
		end
	end

	return {
		slot = slot,
		origin = origin,
		width = width,
		height = height,
		mapWidth = mapW,
		mapHeight = mapH,
		zone = zone,
		zoneName = zoneName,
		entry = entry,
		region = region,
	}
end

-- Sync grass fill when async loadMapChunk has not materialized tiles yet.
function ExpeditionInstance.ensureFloor(instance)
	if not instance then
		return 0
	end
	local groundId = ExpeditionConfig.FALLBACK_GROUND_ID or 4526
	local origin = instance.origin
	local painted = 0
	for x = origin.x + 1, origin.x + instance.width - 2 do
		for y = origin.y + 1, origin.y + instance.height - 2 do
			local pos = Position(x, y, origin.z)
			local tile = Tile(pos)
			if not tile or not tile:getGround() then
				if not tile then
					tile = Game.createTile(pos, true)
				end
				if tile then
					Game.createItem(groundId, 1, pos)
					painted = painted + 1
				end
			end
		end
	end
	return painted
end

function ExpeditionInstance.hasGround(pos)
	local tile = Tile(pos)
	return tile and tile:getGround() ~= nil
end

function ExpeditionInstance.teardown(instance)
	if not instance then
		return
	end
	if instance.zone then
		instance.zone:removeMonsters()
		local positions = instance.zone:getPositions()
		for _, pos in ipairs(positions) do
			local tile = Tile(pos)
			if tile then
				local items = tile:getItems()
				if items then
					for _, item in ipairs(items) do
						item:remove()
					end
				end
				local ground = tile:getGround()
				if ground then
					ground:remove()
				end
			end
		end
	end
	ExpeditionInstance.free(instance.slot)
end

local function isWalkable(pos)
	local tile = Tile(pos)
	return tile and tile:getGround() and not tile:hasFlag(TILESTATE_BLOCKSOLID)
end

function ExpeditionInstance.randomWalkable(instance)
	if not instance then
		return nil
	end
	local origin = instance.origin
	for _ = 1, 40 do
		local x = math.random(origin.x + 2, origin.x + instance.width - 3)
		local y = math.random(origin.y + 2, origin.y + instance.height - 3)
		local pos = Position(x, y, origin.z)
		if isWalkable(pos) then
			return pos
		end
	end
	return instance.entry
end

local function collectRingWalkable(center, radius, instance)
	local origin = instance.origin
	local minX, maxX = origin.x + 2, origin.x + instance.width - 3
	local minY, maxY = origin.y + 2, origin.y + instance.height - 3
	local candidates = {}
	for dx = -radius, radius do
		for dy = -radius, radius do
			-- Chebyshev ring at exact attack range (Tibia distance).
			if math.max(math.abs(dx), math.abs(dy)) == radius then
				local x, y = center.x + dx, center.y + dy
				if x >= minX and x <= maxX and y >= minY and y <= maxY then
					local pos = Position(x, y, center.z)
					if isWalkable(pos) then
						candidates[#candidates + 1] = pos
					end
				end
			end
		end
	end
	return candidates
end

-- Spawn on the ring around the player at the creature's attack range
-- (melee targetDistance=1 → 1-tile radius, ranged=3 → 3-tile radius, …).
function ExpeditionInstance.randomAttackRangeWalkable(instance, center, radius)
	if not instance or not center then
		return nil
	end
	radius = math.max(1, tonumber(radius) or 1)

	local candidates = collectRingWalkable(center, radius, instance)
	if #candidates > 0 then
		return candidates[math.random(1, #candidates)]
	end

	-- Prefer a nearby ring if the exact range is blocked / out of bounds.
	for delta = 1, 3 do
		for _, r in ipairs({ radius - delta, radius + delta }) do
			if r >= 1 then
				candidates = collectRingWalkable(center, r, instance)
				if #candidates > 0 then
					return candidates[math.random(1, #candidates)]
				end
			end
		end
	end

	return ExpeditionInstance.randomWalkable(instance)
end
