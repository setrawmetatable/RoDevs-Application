-- // Services //
-- Standard Roblox services required for replication, players, and localization.
local LocalizationService = game:GetService("LocalizationService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- // Variables //

-- Remote Events/Functions for Server-Client communication
local RemotesFolder : Folder = ReplicatedStorage:WaitForChild("Remotes")
local CombatRemote : RemoteEvent = RemotesFolder:WaitForChild("Combat") -- Handles firing, hitting, reloading
local CombatModules : Folder = ReplicatedStorage:WaitForChild("CombatModules") -- Stores configuration data for each weapon

local EquipRemote : RemoteFunction = RemotesFolder:WaitForChild("EquipTool") -- Validates equipping
local unEquipRemote : RemoteEvent = RemotesFolder:WaitForChild("unEquipTool") -- Validates unequipping

local WeaponModels = ReplicatedStorage:WaitForChild("WeaponModels") -- Storage for visual weapon models

-- External Module for handling Sound Effects
local SFXService = require(ReplicatedStorage.Modules.Services.SFXService)

-- // Handler Definition //

local CombatHandler = {}
local PlayerDataTable = {} -- Stores server-side state for every player (Ammo, Cooldowns, Reloading status)

-- // Functions //

-- initializes a new session entry for a player when their character loads
function CombatHandler.new(character : Model)
	local Player = Players:GetPlayerFromCharacter(character)
	PlayerDataTable[Player.Name] = {
		LastHit = 0,         -- Timestamp of the last attack (for cooldowns)
		BulletData = {},     -- Stores active bullets for server-side validation
		Reloading = false,   -- Is the player currently reloading?
		ReloadTrack = nil,   -- The AnimationTrack for reloading
		CurrentTool = nil    -- Name of the currently equipped tool
	}
end

-- Helper function to find the visual model of the weapon inside the character
-- (Distinguishes between the logic Tool object and the visual Model)
function CombatHandler:FindWeaponModel(character : Model, toolname : string)
	local found = nil

	for i,basepart : BasePart in pairs(character:GetChildren()) do
		if basepart.Name == toolname and not basepart:IsA("Tool") then
			found = basepart
			break
		end
	end

	return found
end

-- The main event handler for combat interactions (Firing, Hitting, Reloading, Healing)
function CombatHandler:OnEvent(player : Player, hitpart : BasePart, hit : BasePart, direction : Vector3, origin : Vector3)
	-- Validate Character existence
	local character : Model = player.Character
	if not character then return end

	local hum : Humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	local root : BasePart = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	-- // BONUS: Reload Request //
	-- If the first argument is the string "Reload", trigger the reload sequence
	if hitpart == "Reload" then
		return CombatHandler:Reload(player, character)
	end

	-- // BONUS: Medkit Logic //
	-- Checks if the player is holding a Medkit and handles healing
	local tool = character:FindFirstChildOfClass("Tool")
	if not tool then
		return warn("Tool not found in " .. player.Name)
	end

	if tool.Name == "Medkit" then
		local mode = hitpart -- Mode 1 usually implies healing others
		local humanoidtoheal = hit

		if mode == 1 and humanoidtoheal and humanoidtoheal:IsA("Humanoid") then
			humanoidtoheal.Health += 25 -- Heal target
		else
			hum.Health += 25 -- Heal self
		end

		tool:Destroy() -- Consumable item, destroy after use

		return warn("Medkit used! for " .. player.Name)
	end

	-- // Ranged/Melee Logic //

	-- Fetch weapon configuration data
	local tooldata = CombatModules:FindFirstChild(tool.Name .. "Data")
	if not tooldata then
		return warn("Tool Data not found in " .. tool.Name)
	end

	-- Verify the visual model exists
	local toolmodel = CombatHandler:FindWeaponModel(character, tool.Name)
	if not toolmodel then
		return warn("Weapon Model not found in " .. player.Name)
	end

	-- Verify player session data exists
	local playerData = PlayerDataTable[player.Name]
	if not playerData then
		return player:Kick("No data found") -- Kick player if data is missing (Security risk)
	end

	tooldata = require(tooldata)

	-- // FIRE LOGIC (Initial Shot) //
	if hitpart == "Fire" then
		-- Anti-Cheat #1: Max Distance Check
		-- Ensure the bullet isn't spawning too far away from the player's root part
		local distancefromcharacter = (origin - root.Position).Magnitude
		if distancefromcharacter > 7.5 then
			return warn("Origin too far from character?")
		end

		-- Anti-Cheat #2: Line of Sight (LOS) Check
		-- Ensure the bullet isn't spawning through a wall
		local ray = Ray.new(root.Position, (origin - root.Position).Unit * distancefromcharacter)
		local result, position = workspace:FindPartOnRayWithIgnoreList(ray, {character})
		if result then
			return warn("Origin LOS #1, registration failed.")
		end

		-- #3: Ammo Deduction and ID Verification
		if CombatHandler:DeductAmmo(tooldata, tool, toolmodel, hitpart, player) == "End" then return end

		local GUID : string = hit -- Expecting a unique ID for the bullet
		if typeof(GUID) ~= "string" then
			return warn("Bullet ID needs to be a string!")
		end

		local existing = playerData.BulletData[GUID]
		if existing then
			return warn("Bullet ID already exists! you can't duplicate it cheater!")
		end

		-- Register the bullet in server memory
		playerData.BulletData[GUID] = {
			Direction = direction,
			Origin = origin,
			firetick = tick(),
			weaponData = tooldata
		}

		-- Replicate the visual bullet to all OTHER clients
		for _,otherplayer in Players:GetPlayers() do
			if otherplayer ~= player then
				CombatRemote:FireClient(otherplayer, "ReplicateBullet", origin, direction, tooldata.Speed, character, GUID)
			end
		end

		return warn("Fired bullet registry set, bullet data is ", playerData.BulletData[GUID])
	end

	-- // HIT LOGIC (Projectile Hit) //

	-- Ensure the hit target is a valid enemy
	local enemy : Model = hitpart.Parent
	local enemyroot : BasePart = enemy:FindFirstChild("HumanoidRootPart")
	local enemyhum : Humanoid = enemy:FindFirstChildOfClass("Humanoid")
	if not enemyhum or not enemyroot then return end

	-- Prevent damaging enemies during cutscenes (Invincibility)
	if enemy:GetAttribute("Cutscene") == true then
		return warn("Enemy is in cutscene! for " .. player.Name)
	end

	-- // MAIN COMBAT LOGIC //

	-- #0: Projectile Validation (Anti-Cheat)
	if tooldata.DamageBoost then -- Checks if it is a ranged weapon
		local BulletID : string = direction -- In hit logic, 'direction' variable is used to pass Bullet ID
		local BulletData = playerData.BulletData[BulletID]
		if not BulletData then
			return warn("BulletData missing, registration failed for bullet! from " .. player.Name)
		end

		-- Tell other clients to delete the visual bullet now that it hit something
		for _,otherplayer in Players:GetPlayers() do
			if otherplayer ~= player then
				CombatRemote:FireClient(otherplayer, "DeleteBullet", BulletID)
			end
		end

		-- Calculate expected position vs actual position
		local Speed = tooldata.Speed
		local Origin = BulletData.Origin
		local Direction = BulletData.Direction
		local FireTick = BulletData.firetick

		local bullettime = tick() - FireTick
		local distancetraveled = Speed * bullettime
		local location = Origin + (Direction * distancetraveled)

		local maxOffsetDistance = 10
		local distance = (location - enemyroot.Position).Magnitude

		warn(bullettime, distance, maxOffsetDistance)

		-- If the hit location is too far from where the server calculated the bullet should be
		if distance > maxOffsetDistance then
			return warn("Bullet Registry failed, distance exceeds threshold!")
		end
	end

	-- #1: Equipment Check
	if not playerData.CurrentTool then
		return warn("Player doesn't have a tool equipped! from " .. player.Name)
	end

	-- #2: Melee Reach / Hit Distance Check
	local Distance : number = (enemyroot.Position - root.Position).Magnitude
	if Distance > tooldata.Reach then
		return warn("Too far to hit! from " .. player.Name)
	end

	-- #3: Cooldown Check (FireRate)
	local lasthittick = playerData.LastHit
	local weaponcooldown = tooldata.Cooldown or tooldata.FireRate
	if tick() - lasthittick < weaponcooldown then return end
	playerData.LastHit = tick()

	-- #4: Apply Damage
	local oldhealth = enemyhum.Health
	local damage = tooldata.Damage

	-- Headshot Multiplier (3x damage)
	if tooldata.DamageBoost and hit == enemy.Head then
		damage *= 3
	end
	enemyhum:TakeDamage(damage)

	-- #5: Play Impact Sounds
	if enemyhum.Health > 0 or oldhealth <= 0 then
		if hit == enemy.Head then
			SFXService:PlaySFX(enemyroot.Position, "Headshot")
		else
			SFXService:PlaySFX(enemyroot.Position, tool.Name .. "_Impact")
		end
	else
		-- Kill sound
		SFXService:PlaySFX(enemyroot.Position, "Zamn")
	end

	-- #6: BONUS Durability System
	local current = tool:GetAttribute("Uses") or 0
	tool:SetAttribute("Uses", current + 1)

	if CombatHandler:IsMaxUses(tooldata, tool) then
		CombatHandler:BreakTool(tool, toolmodel)
	end

	-- #7: BONUS Physics/Ragdoll on hit
	CombatHandler:AddRagdollTime(enemy, root, tooldata)
end

-- Manages ammo attributes on the tool and replicates muzzle flash
function CombatHandler:DeductAmmo(tooldata : table, tool : Tool, toolmodel : Model, hitpart : BasePart, player : Player)
	if tooldata.DamageBoost then -- Only run for ranged weapons
		local maxAmmo = tooldata.maxAmmo

		local CurrentAmmo = tool:GetAttribute("Ammo")
		-- Initialize ammo if it doesn't exist
		if not CurrentAmmo then tool:SetAttribute("Ammo", maxAmmo) CurrentAmmo = maxAmmo end

		if CurrentAmmo <= 0 then return "End" end -- Out of ammo

		CurrentAmmo -= 1
		tool:SetAttribute("Ammo", CurrentAmmo)

		-- Replicate Muzzle Flash to other players
		for _,otherplayer : Player in pairs(Players:GetPlayers()) do
			if otherplayer ~= player then
				CombatRemote:FireClient(otherplayer, "Flash", toolmodel)
			end
		end
	end

	-- If this is a Melee swing (hitpart is nil/false), track "Misses" stat
	if not hitpart then
		local Misses = tool:GetAttribute("Misses") or 0
		tool:SetAttribute("Misses", Misses + 1)
		return
	end
end

-- Handles reloading logic, including animations and syncing sound effects to animation markers
function CombatHandler:Reload(player : Player, character : Model)
	local Humanoid : Humanoid = character.Humanoid

	local playerData = PlayerDataTable[player.Name]
	if not playerData then
		return player:Kick("No data found")
	end

	-- Cancel Reload Logic
	-- If already reloading, this block stops it and disconnects all events to prevent memory leaks
	if playerData.Reloading == true then
		playerData.ReloadTrack:Stop(0.25)
		playerData.ToolCheck:Disconnect()
		playerData.TemporaryConnection:Disconnect()
		playerData.Temp1:Disconnect()
		playerData.Temp2:Disconnect()
		playerData.Temp3:Disconnect()
		playerData.Temp4:Disconnect()
		playerData.Reloading = false

		CombatRemote:FireClient(player, "Reloaded")

		return
	end

	-- Standard Validation checks
	local tool : Tool = character:FindFirstChildOfClass("Tool")
	if not tool then
		return warn("Failed to find tool! Can't reload. for " .. player.Name)
	end

	local tooldata = CombatModules:FindFirstChild(tool.Name .. "Data")
	if not tooldata then
		return warn("Tool Data not found in " .. tool.Name)
	end

	tooldata = require(tooldata)

	local WeaponModel = self:FindWeaponModel(character, tool.Name)
	if not WeaponModel then
		return warn("No WeaponModel found! Can't reload. for " .. player.Name)
	end

	-- Find a part to play sound from
	local BasePart = WeaponModel:FindFirstChildOfClass("MeshPart") or WeaponModel:FindFirstChildOfClass("Part")
	if not BasePart then
		return warn("Unable to find any parts inside of weapon model? for " .. player.Name .. " " .. tool.Name)
	end

	-- Prevent reloading if ammo is already full
	if not tool:GetAttribute("Ammo") or tool:GetAttribute("Ammo") >= tooldata.maxAmmo then
		return warn("Ammo is already max or more! Cannot reload. for " .. player.Name)
	end

	-- Play Reload Animation
	local ReloadTrack = Humanoid.Animator:LoadAnimation(tooldata.Tracks.Reload)
	ReloadTrack:Play(0.25)

	playerData.ReloadTrack = ReloadTrack
	playerData.Reloading = true

	-- Success: When animation finishes, refill ammo
	playerData.TemporaryConnection = ReloadTrack.Ended:Connect(function()
		playerData.Reloading = false
		tool:SetAttribute("Ammo", tooldata.maxAmmo)
		CombatRemote:FireClient(player, "Reloaded")
	end)

	-- Play Sounds at specific frames (Markers) in the animation
	playerData.Temp1 = ReloadTrack:GetMarkerReachedSignal("MagOut"):Connect(function()
		SFXService:PlaySFX(BasePart.Position, "MagOut")
	end)

	playerData.Temp2 = ReloadTrack:GetMarkerReachedSignal("MagIn"):Connect(function()
		SFXService:PlaySFX(BasePart.Position, "MagIn")
	end)

	playerData.Temp3 = ReloadTrack:GetMarkerReachedSignal("MagFall"):Connect(function()
		SFXService:PlaySFX(BasePart.Position, "MagFall")
	end)

	playerData.Temp4 = ReloadTrack:GetMarkerReachedSignal("M3"):Connect(function()
		SFXService:PlaySFX(BasePart.Position, "M3")
	end)

	-- Interrupt: If player unequips tool during reload, cancel everything
	playerData.ToolCheck = character.ChildRemoved:Connect(function(child)
		if child == tool then
			playerData.ReloadTrack:Stop(0.25)
			playerData.ToolCheck:Disconnect()
			playerData.TemporaryConnection:Disconnect()
			playerData.Temp1:Disconnect()
			playerData.Temp2:Disconnect()
			playerData.Temp3:Disconnect()
			playerData.Temp4:Disconnect()
			playerData.Reloading = false

			CombatRemote:FireClient(player, "Reloaded")
		end
	end)

	CombatRemote:FireClient(player, "Reloading")
end

-- Visual effect for when a tool breaks (Max uses reached)
function CombatHandler:BreakTool(tool : Tool, toolmodel : Model)
	tool:Destroy()

	-- Create a fake physical version of the tool to fall to the ground
	local FakeWeaponModel = toolmodel:Clone()
	FakeWeaponModel.Parent = workspace
	FakeWeaponModel.CanCollide = true
	FakeWeaponModel.CanTouch = false
	FakeWeaponModel.Anchored = false

	SFXService:PlaySFX(FakeWeaponModel.Position, tool.Name .. "_Break")

	-- Cleanup debris after 5 seconds
	task.delay(5, function()
		FakeWeaponModel:Destroy()
	end)
end

-- Checks if the tool has exceeded its durability limit
function CombatHandler:IsMaxUses(tooldata : table, tool : Tool)
	local MaxUses = tooldata.MaxUses
	local Uses = tool:GetAttribute("Uses") or 0

	return MaxUses and Uses >= MaxUses
end

-- Applies knockback physics to the enemy
function CombatHandler:AddRagdollTime(enemy : Model, root : BasePart, tooldata : table)
	local ragdollTime = enemy:FindFirstChild("ragdollTime")
	if not ragdollTime then
		warn("Ragdoll Time is not found in enemy! for " .. enemy.Name)
		return
	end

	-- Delay slightly to sync with potential impact animations
	task.delay(0.05, function()
		local KnockbackPower = tooldata.KnockbackPower
		local lookvector = root.CFrame.LookVector
		enemy.HumanoidRootPart.Velocity = lookvector * KnockbackPower -- Apply velocity
	end)

	ragdollTime.Value = tooldata.RagdollAddition -- Trigger Ragdoll script (external)
end

-- Server-side equip logic (Replaces standard Roblox Handle welding)
function CombatHandler:OnEquip(player : Player, toolname : string)
	-- #1 Find Weapon (Check Backpack or Character)
	local toolinplayer = player.Backpack:FindFirstChild(toolname) or tostring(player.Character:FindFirstChildOfClass("Tool")) == toolname
	if not toolinplayer then
		return warn("Tool not found in " .. player.Name)
	end

	-- #BONUS check if player is RAGDOLLED (Prevent equipping while stunned)
	local char = player.Character
	if not char then
		return warn("No character? Can't equip... duh. for " .. player.Name)
	end

	local ragdollBool : NumberValue = char:FindFirstChild("ragdollBool")
	if not ragdollBool then
		return warn("No ragdoll system found in player! Can't equip. for " .. player.Name)
	end 

	if ragdollBool.Value == true then
		return warn("Player is ragdolled, can't equip tools. for " .. player.Name)
	end

	-- #2 Check if player is multi-equipping (already has a tool)
	local playerData = PlayerDataTable[player.Name]
	if not playerData then
		return player:Kick("No data found")
	end

	if playerData.CurrentTool then
		return warn(player.Name .. " already has a tool equipped.")
	end

	-- #3 Check for tool data
	local tooldata = CombatModules:FindFirstChild(toolname .. "Data")
	if not tooldata then
		return warn("Tool Data not found in " .. toolname)
	end

	tooldata = require(tooldata)

	-- #4 Weld the tool using Motor6D (Allows for animation)
	local TargetPart : BasePart = player.Character[tooldata.TargetPart] -- usually "RightArm"

	local WeaponModel = WeaponModels:FindFirstChild(toolname)
	if not WeaponModel then
		return warn("Weapon model not found! for " .. toolname)
	end

	local WeaponModelTemplate = WeaponModel:Clone()
	WeaponModelTemplate.Parent = WeaponModels -- ? This seems to parent back to storage, might want workspace/character?

	-- Logic for handling Model vs single MeshPart structures
	if WeaponModel:IsA("Model") then
		WeaponModel.Parent = player.Character
		WeaponModel = WeaponModel:FindFirstChild("Bodyu") or WeaponModel:FindFirstChild("RootPart") or WeaponModel:FindFirstChild("WeldPart")
	else
		WeaponModel.CFrame = TargetPart.CFrame
		WeaponModel.Parent = player.Character
	end

	-- Create the joint
	local new6d = Instance.new("Motor6D", TargetPart)
	new6d.Part0 = TargetPart
	new6d.Part1 = WeaponModel

	new6d.C0 = tooldata.Offset -- Base offset

	if tooldata.Offset2 then
		new6d.C1 = tooldata.Offset2 -- Secondary offset
	end

	-- #5 Set State
	playerData.CurrentTool = toolname

	-- #6 BONUS Play equip sound
	SFXService:PlaySFX(WeaponModel.Position, toolname .. "_Equip")

	return WeaponModel
end

-- Server-side unequip logic
function CombatHandler:unEquip(player)
	local playerData = PlayerDataTable[player.Name]
	if not playerData then
		return player:Kick("No data found")
	end

	if not playerData.CurrentTool then
		return warn("No equipped tool data found in playerData! There is nothing to unEquip. for " .. player.Name)
	end

	local char = player.Character
	if not char then return end

	-- Find and destroy the visual model
	local tool = self:FindWeaponModel(char, playerData.CurrentTool)
	if not tool then
		return warn("Failed to unequip! No weaponmodel found. for " .. playerData.CurrentTool)
	end

	tool:Destroy()
	playerData.CurrentTool = nil

	print("A") -- Debug print
end

-- // Remote Connections //

-- Connect main combat loop
CombatRemote.OnServerEvent:Connect(function(...)
	CombatHandler:OnEvent(...)
end)

-- Connect Equip Request
EquipRemote.OnServerInvoke = function(player, toolname)
	return CombatHandler:OnEquip(player, toolname)
end

-- Connect Unequip Request
unEquipRemote.OnServerEvent:Connect(function(player)
	CombatHandler:unEquip(player)
end)

-- Connect Swing Sound (Melee)
EquipRemote.Parent.Swing.OnServerEvent:Connect(function(player : Player)
	local char = player.Character
	if not char then return end

	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then return end

	-- Play swing sound
	SFXService:PlaySFX(root.Position, tool.Name .. "_Swing")
end)

return CombatHandler
