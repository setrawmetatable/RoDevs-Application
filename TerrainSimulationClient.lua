--[[
	- PartPool: O(1) Memory management for fluid particles.
	- TerrainController: Handles Parallel Luau Actor requests/rendering.
	- FluidEngine: Cellular automata simulation with time-budgeting.
	- InteractionService: Raycasting and user inputs.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- // CONFIGURATION //
local PerlinConfig = require(ReplicatedStorage.Modules.PerlinConfig)

local BLOCK_SIZE = PerlinConfig.BLOCK_SIZE
local CHUNK_WIDTH = PerlinConfig.CHUNK_SIZE * BLOCK_SIZE

local sim_budget = 4
local water_tr = 0.05
local pre_alloc = 500

-- // TYPES //
type BlockData = {
	Instance: BasePart,
	Key: string,
	Chunk: Folder
}

-- // STATE & CACHE //
local Player = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local ChunkFolder = workspace:WaitForChild("Chunks")

-- // Object Pools // --
local PartPool = {}
PartPool.__index = PartPool
PartPool._stack = {} :: {BasePart}

function PartPool.init()
	for i = 1, pre_alloc do
		table.insert(PartPool._stack, PartPool._create())
	end
end

function PartPool._create(): BasePart
	local p = Instance.new("Part")
	p.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	p.Anchored = true
	p.CanCollide = false
	p.Massless = true
	p.Material = Enum.Material.Water
	p.Color = Color3.fromRGB(33, 115, 255)
	p.Transparency = 0.3
	p.Name = "Water"
	p:SetAttribute("Pooled", true)
	return p
end

function PartPool.Get(): BasePart
	local part = table.remove(PartPool._stack)
	if not part then
		part = PartPool._create()
	end
	part.Transparency = 0.3
	part.Parent = ChunkFolder
	return part
end

function PartPool.Return(part: BasePart)
	part.Parent = nil
	part.CFrame = CFrame.new(0, 10000, 0)
	table.insert(PartPool._stack, part)
end

-- // Fluid Engine // --
local FluidEngine = {}
FluidEngine.ActiveWater = {} :: {BasePart}
FluidEngine.BlockMap = {} :: {[string]: boolean}
FluidEngine.Accum = 0

function FluidEngine.GetKey(x: number, y: number, z: number): string
	return string.format("%d,%d,%d", x, y, z)
end

function FluidEngine.Snap(n: number): number
	return math.floor(n / BLOCK_SIZE + 0.5) * BLOCK_SIZE
end

function FluidEngine.RegisterBlock(part: BasePart)
	FluidEngine.BlockMap[part.Name] = true
	if part:GetAttribute("BlockType") == "Water" then
		table.insert(FluidEngine.ActiveWater, part)
	end
end

function FluidEngine.UnregisterBlock(part: BasePart)
	FluidEngine.BlockMap[part.Name] = nil
end

function FluidEngine.SpawnWater(pos: Vector3, parent: Instance)
	local x, y, z = FluidEngine.Snap(pos.X), FluidEngine.Snap(pos.Y), FluidEngine.Snap(pos.Z)
	local key = FluidEngine.GetKey(x, y, z)

	if FluidEngine.BlockMap[key] then return end

	local water = PartPool.Get()
	water.Position = Vector3.new(x, y, z)
	water.Name = key
	water.Parent = parent
	water:SetAttribute("BlockType", "Water")

	FluidEngine.RegisterBlock(water)
end

function FluidEngine.Step(dt: number)
	FluidEngine.Accum += dt
	if FluidEngine.Accum < water_tr then return end
	FluidEngine.Accum -= water_tr

	local startTime = os.clock()
	local activeList = FluidEngine.ActiveWater
	local count = #activeList

	for i = count, 1, -1 do
		-- performance budget
		if (os.clock() - startTime) * 1000 > sim_budget then
			break
		end

		local block = activeList[i]

		-- garbage collection
		if not block or not block.Parent then
			activeList[i] = activeList[#activeList]
			table.remove(activeList)
			continue
		end

		local bp = block.Position
		if bp.Y <= -50 then continue end -- bedrock check

		local x, y, z = FluidEngine.Snap(bp.X), FluidEngine.Snap(bp.Y), FluidEngine.Snap(bp.Z)
		local belowKey = FluidEngine.GetKey(x, y - BLOCK_SIZE, z)

		if not FluidEngine.BlockMap[belowKey] then
			-- spawn water below
			FluidEngine.SpawnWater(Vector3.new(x, y - BLOCK_SIZE, z), block.Parent)
		end
	end
end

-- // Terrain Controller // --
local TerrainController = {}
TerrainController.LoadedChunks = {} :: {[string]: boolean}
TerrainController.ActorIndex = 1
TerrainController.Actors = ReplicatedFirst:WaitForChild("ChunkActors"):GetChildren()

function TerrainController.GetActor(): Actor
	local actor = TerrainController.Actors[TerrainController.ActorIndex]
	TerrainController.ActorIndex = (TerrainController.ActorIndex % #TerrainController.Actors) + 1
	return actor :: Actor
end

function TerrainController.Update(rootPart: BasePart)
	local px = math.floor(rootPart.Position.X / CHUNK_WIDTH)
	local pz = math.floor(rootPart.Position.Z / CHUNK_WIDTH)
	local renderDist = PerlinConfig.RENDER_DIST

	-- 1. Load New Chunks
	for x = -renderDist, renderDist do
		for z = -renderDist, renderDist do
			local cx, cz = px + x, pz + z
			local key = cx .. "," .. cz

			if not TerrainController.LoadedChunks[key] and not ChunkFolder:FindFirstChild(key) then
				TerrainController.LoadedChunks[key] = true
				local actor = TerrainController.GetActor()
				actor:SetAttribute("cx", cx)
				actor:SetAttribute("cz", cz)
				actor:SendMessage("LoadChunk")
			end
		end
	end

	-- 2. Unload Old Chunks
	for _, chunk in ipairs(ChunkFolder:GetChildren()) do
		local coords = string.split(chunk.Name, ",")
		if #coords < 2 then continue end

		local cx, cz = tonumber(coords[1]), tonumber(coords[2])
		if not cx or not cz then continue end

		local dx, dz = cx - px, cz - pz
		if math.abs(dx) > renderDist or math.abs(dz) > renderDist then
			-- Recycle water before destroying chunk
			for _, child in ipairs(chunk:GetDescendants()) do
				if child:IsA("BasePart") and child:GetAttribute("Pooled") then
					FluidEngine.UnregisterBlock(child)
					PartPool.Return(child)
				end
			end

			-- Send Unload to Actor
			local actor = TerrainController.GetActor()
			actor:SetAttribute("ChunkName", chunk.Name)
			actor:SendMessage("UnloadChunk")

			TerrainController.LoadedChunks[chunk.Name] = nil
		end
	end
end

-- // Interaction Service // --
local InteractionService = {}
InteractionService.Highlight = nil

local Mouse = Player:GetMouse()

function InteractionService.Init()
	local hl = Instance.new("Highlight")
	hl.Name = "VoxelSelection"
	hl.FillTransparency = 1
	hl.OutlineTransparency = 0.5
	hl.OutlineColor = Color3.new(0, 0, 0)
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	InteractionService.Highlight = hl
end

function InteractionService.Update()
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {Player.Character}
	params.FilterType = Enum.RaycastFilterType.Exclude

	local ray = Camera:ViewportPointToRay(Mouse.X, Mouse.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 20, params)

	if result and result.Instance:IsDescendantOf(ChunkFolder) then
		InteractionService.Highlight.Parent = result.Instance
	else
		InteractionService.Highlight.Parent = nil
	end
end

print("INITIALIZING TERRAIN SYSTEMS")

PartPool.init()
InteractionService.Init()

-- Listen for incoming chunks (Replication handling)
ChunkFolder.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("BasePart") then
		FluidEngine.RegisterBlock(descendant)
	end
end)

ChunkFolder.DescendantRemoving:Connect(function(descendant)
	if descendant:IsA("BasePart") then
		FluidEngine.UnregisterBlock(descendant)
	end
end)

-- Main Loop
RunService.Heartbeat:Connect(function(dt)
	-- 1. Simulate Fluids
	FluidEngine.Step(dt)

	-- 2. Interaction Visuals
	InteractionService.Update()
end)

-- Async Terrain Loop
task.spawn(function()
	while true do
		if Player.Character and Player.Character:FindFirstChild("HumanoidRootPart") then
			TerrainController.Update(Player.Character.HumanoidRootPart)
		end
		task.wait(0.5)
	end
end)
