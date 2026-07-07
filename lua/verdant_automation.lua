local DISCORD_LINK = "https://discord.gg/Gss5AgSkbh"

local function loadRayfield()
	local urls = {
		"https://sirius.menu/rayfield",
		"https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua",
	}
	for _, url in ipairs(urls) do
		local ok, lib = pcall(function()
			local src = game:HttpGet(url, true)
			return loadstring(src)()
		end)
		if ok and lib and type(lib.CreateWindow) == "function" then
			return lib
		end
	end
	error("Failed to load Rayfield. Enable HttpGet on your executor and try again.")
end

local Rayfield = loadRayfield()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local POUR_KEYWORD = "Machine_Cube.018"
local TOKEN_KEYWORD = "Machine_Cube.020"

local function copyDiscord()
	pcall(function()
		if setclipboard then
			setclipboard(DISCORD_LINK)
		elseif toclipboard then
			toclipboard(DISCORD_LINK)
		end
	end)
end

copyDiscord()

local function getHolder()
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return nil end
	local iface = playerGui:FindFirstChild("Interface")
	return iface and iface:FindFirstChild("Holder")
end

local function getRemote(name)
	local folder = ReplicatedStorage:FindFirstChild("VerdantRemotes")
	if not folder then
		folder = ReplicatedStorage:WaitForChild("VerdantRemotes", 10)
	end
	if not folder then return nil end
	return folder:FindFirstChild(name) or folder:WaitForChild(name, 5)
end

local function getCheckpointParts()
	local scripted = workspace:FindFirstChild("Scripted")
	if not scripted then return nil end
	return scripted:FindFirstChild("CheckpointParts")
end

local function findPartIn(parent, keyword)
	if not parent then return nil end
	for _, child in ipairs(parent:GetDescendants()) do
		if child:IsA("BasePart") and child.Name:find(keyword, 1, true) then
			return child
		end
	end
	return nil
end

local function getDrainPrompt(drain)
	if not drain then return nil end
	local ok, prompt = pcall(function()
		return drain
			:WaitForChild("Scripted", 5)
			:WaitForChild("ProximityPosition", 5)
			:WaitForChild("ProximityPrompt", 5)
	end)
	if ok and prompt then return prompt end
	return drain:FindFirstChild("ProximityPrompt", true)
end

local function getAllDrains()
	local drains = {}
	local checkpointParts = getCheckpointParts()
	if not checkpointParts then return drains end

	for _, checkpoint in ipairs(checkpointParts:GetChildren()) do
		local drain = checkpoint:FindFirstChild("Drain")
		if drain then
			local scripted = drain:FindFirstChild("Scripted")
			if scripted then
				table.insert(drains, {
					name = checkpoint.Name,
					drain = drain,
					pourPart = findPartIn(scripted, POUR_KEYWORD),
					tokenPart = findPartIn(scripted, TOKEN_KEYWORD),
					prompt = getDrainPrompt(drain),
				})
			end
		end
	end

	table.sort(drains, function(a, b)
		return (tonumber(a.name) or 0) < (tonumber(b.name) or 0)
	end)

	return drains
end

local function getWaterPart()
	local water = workspace:FindFirstChild("Water")
	if not water then return nil end
	local top = water:FindFirstChild("Top")
	if top and top:IsA("BasePart") then
		return top
	end
	for _, child in ipairs(water:GetDescendants()) do
		if child:IsA("BasePart") then
			return child
		end
	end
	return nil
end

local function getCharacter()
	local char = LocalPlayer.Character
	if not char then
		char = LocalPlayer.CharacterAdded:Wait()
	end
	local hrp = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)
	return char, hrp
end

local function getBucketTool()
	local char = LocalPlayer.Character
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	for _, container in ipairs({ char, backpack }) do
		if container then
			for _, item in ipairs(container:GetChildren()) do
				if item:IsA("Tool") then
					local n = string.lower(item.Name)
					if n:find("bucket") or n:find("pail") then
						return item
					end
				end
			end
		end
	end
	return nil
end

local function equipBucket()
	local char = LocalPlayer.Character
	if not char then return end
	local humanoid = char:FindFirstChild("Humanoid")
	local bucket = getBucketTool()
	if humanoid and bucket then
		pcall(function()
			humanoid:EquipTool(bucket)
		end)
		task.wait(0.2)
	end
end

local function getBucketFill()
	local holder = getHolder()
	local bucketFill = holder and holder:FindFirstChild("BucketFill")
	local bar = bucketFill and bucketFill:FindFirstChild("Bar")

	local progressLabel = bar and bar:FindFirstChild("Progress")
	if progressLabel and progressLabel:IsA("TextLabel") then
		local pct = tostring(progressLabel.Text):match("(%d+)")
		if pct then
			return tonumber(pct)
		end
	end

	local scale = bar and bar:FindFirstChild("Scale")
	if scale and scale:IsA("GuiObject") then
		local barScale = scale.Size.X.Scale
		if barScale > 0 then
			return math.floor(barScale * 100 + 0.5)
		end
	end

	return nil
end

local function getDrownLevel()
	local holder = getHolder()
	local drown = holder and holder:FindFirstChild("Drown")
	if not drown or not drown.Visible then
		return 1
	end
	local bar = drown:FindFirstChild("Bar")
	local scale = bar and bar:FindFirstChild("Scale")
	if scale and scale:IsA("GuiObject") then
		return scale.Size.X.Scale
	end
	return 0
end

local function isDrowning()
	local holder = getHolder()
	local drown = holder and holder:FindFirstChild("Drown")
	if drown and drown.Visible then
		return getDrownLevel() < 0.4
	end
	return false
end

local function teleportToPart(part)
	if not part then return false end
	local _, hrp = getCharacter()
	if not hrp then return false end
	hrp.CFrame = part.CFrame * CFrame.new(0, 5, 0)
	task.wait(0.4)
	return true
end

local function teleportToWater()
	local waterPart = getWaterPart()
	if waterPart then
		return teleportToPart(waterPart)
	end
	return false
end

local function teleportToDrain(drain, keyword)
	local scripted = drain and drain:FindFirstChild("Scripted")
	local part = scripted and findPartIn(scripted, keyword)
	if part then
		return teleportToPart(part)
	end
	local prompt = getDrainPrompt(drain)
	if prompt and prompt.Parent and prompt.Parent:IsA("BasePart") then
		return teleportToPart(prompt.Parent)
	end
	return false
end

local function disableDrowning()
	local remote = getRemote("VDT_Swim.State")
	if remote then
		remote:FireServer(false)
	end
end

local function antiDrown(pourPart)
	disableDrowning()
	if isDrowning() then
		disableDrowning()
		if pourPart then
			teleportToPart(pourPart)
		else
			teleportToWater()
		end
		task.wait(0.5)
	end
end

local function triggerPrompt(prompt)
	if not prompt then return end
	pcall(function()
		if fireproximityprompt then
			fireproximityprompt(prompt, 0)
		end
	end)
	pcall(function()
		prompt:InputHoldBegin()
		task.wait(0.15)
		prompt:InputHoldEnd()
	end)
end

local function fireRemoteRepeated(remoteName, prompt, times)
	local remote = getRemote(remoteName)
	if not remote or not prompt then return false end
	equipBucket()
	triggerPrompt(prompt)
	for _ = 1, times do
		remote:FireServer(prompt)
		task.wait(0.25)
	end
	return true
end

local function fireGetWater()
	local remote = getRemote("VDT_Bucket.Used")
	if remote then
		equipBucket()
		remote:FireServer()
		return true
	end
	return false
end

local function firePourWater(prompt)
	return fireRemoteRepeated("VDT_Bucket.Poured", prompt, 3)
end

local function fireTakeToken(prompt, tokenPart)
	equipBucket()
	if tokenPart then
		teleportToPart(tokenPart)
		task.wait(0.5)
	end
	triggerPrompt(prompt)
	local remote = getRemote("VDT_Tokens.Take")
	if remote and prompt then
		for _ = 1, 5 do
			triggerPrompt(prompt)
			remote:FireServer(prompt)
			task.wait(0.3)
		end
		return true
	end
	return false
end

local function getSkillNodes()
	local nodes = {}
	local seen = {}

	local holder = getHolder()
	local nodesFolder = holder and holder:FindFirstChild("SkillTree")
	nodesFolder = nodesFolder and nodesFolder:FindFirstChild("Main")
	nodesFolder = nodesFolder and nodesFolder:FindFirstChild("Nodes")

	if nodesFolder then
		for _, child in ipairs(nodesFolder:GetChildren()) do
			local x, y = child.Name:match("^Hex_(%-?%d+)_(%-?%d+)$")
			if x and y then
				x, y = tonumber(x), tonumber(y)
				local key = x .. "_" .. y
				if not seen[key] then
					seen[key] = true
					table.insert(nodes, { x = x, y = y })
				end
			end
		end
	end

	if not seen["-1_1"] then
		table.insert(nodes, { x = -1, y = 1 })
	end

	return nodes
end

local function purchaseSkillTree()
	local remote = getRemote("VDT_SkillTree.Purchase")
	if not remote then return false end

	for _, node in ipairs(getSkillNodes()) do
		pcall(function()
			remote:InvokeServer("root", node.x, node.y)
		end)
		task.wait(0.15)
	end
	return true
end

local autoFarm = false
local autoSkillTree = false
local farmRunning = false
local waterSpamDelay = 0.4
local scoopsPerFill = 10
local stepDelay = 1
local bucketLabel = nil

local function updateBucketLabel()
	if bucketLabel then
		local fill = getBucketFill()
		local drown = getDrownLevel()
		bucketLabel:Set("Bucket: " .. (fill and (fill .. "%") or "?") .. " | O2: " .. math.floor(drown * 100) .. "%")
	end
end

local function resetFarmState()
	farmRunning = false
end

local function collectWaterUntilFull(pourPart)
	disableDrowning()
	equipBucket()
	teleportToWater()
	task.wait(stepDelay)

	local tries = 0
	while autoFarm do
		antiDrown(pourPart)
		disableDrowning()
		fireGetWater()
		tries = tries + 1
		task.wait(waterSpamDelay)

		local fill = getBucketFill()
		updateBucketLabel()

		if fill and fill >= 100 then
			return true
		end

		if tries >= scoopsPerFill then
			return true
		end
	end

	return false
end

local function processDrain(drainData)
	if not autoFarm or not drainData.prompt then return end

	if not collectWaterUntilFull(drainData.pourPart) then
		return
	end

	equipBucket()

	if drainData.pourPart then
		teleportToPart(drainData.pourPart)
	else
		teleportToDrain(drainData.drain, POUR_KEYWORD)
	end
	task.wait(stepDelay)
	firePourWater(drainData.prompt)
	task.wait(stepDelay)

	if not autoFarm then return end

	fireTakeToken(drainData.prompt, drainData.tokenPart)
	task.wait(stepDelay)
end

local function runFarmCycle()
	if farmRunning then return end
	farmRunning = true

	pcall(function()
		local drains = getAllDrains()
		if #drains == 0 then return end

		for _, drain in ipairs(drains) do
			if not autoFarm then break end
			processDrain(drain)
		end

		if autoSkillTree then
			purchaseSkillTree()
		end
	end)

	farmRunning = false

	if autoFarm then
		task.wait(stepDelay)
		task.spawn(runFarmCycle)
	end
end

local Window = Rayfield:CreateWindow({
	Name = "Dogge HUB",
	Icon = 0,
	LoadingTitle = "Drain the Lake",
	LoadingSubtitle = "Dogge HUB | by Hitori",
	ShowText = "Dogge HUB",
	Theme = "Default",
	ToggleUIKeybind = "K",
	DisableBuildWarnings = true,
	ConfigurationSaving = {
		Enabled = true,
		FolderName = "DoggeHUB",
		FileName = "DrainTheLake",
	},
	Discord = {
		Enabled = true,
		Invite = "Gss5AgSkbh",
		RememberJoins = true,
	},
})

local MainTab = Window:CreateTab("Main", 4483362458)

MainTab:CreateSection("Credit")
MainTab:CreateLabel("Drain the Lake")
MainTab:CreateLabel("Dogge HUB | Made by Hitori")
MainTab:CreateParagraph({
	Title = "Discord",
	Content = DISCORD_LINK,
})
MainTab:CreateButton({
	Name = "Copy Discord Link",
	Callback = copyDiscord,
})

MainTab:CreateSection("Automation")
bucketLabel = MainTab:CreateLabel("Bucket: ...")

MainTab:CreateToggle({
	Name = "Auto Farm (All Drains)",
	CurrentValue = false,
	Flag = "AutoFarm",
	Callback = function(value)
		autoFarm = value
		if value then
			disableDrowning()
			task.spawn(runFarmCycle)
		else
			resetFarmState()
		end
	end,
})

MainTab:CreateToggle({
	Name = "Auto Upgrade Skill Tree",
	CurrentValue = false,
	Flag = "AutoSkillTree",
	Callback = function(value)
		autoSkillTree = value
	end,
})

MainTab:CreateSection("Settings")

MainTab:CreateSlider({
	Name = "Water collect delay (x0.1s)",
	Range = {2, 20},
	Increment = 1,
	Suffix = "",
	CurrentValue = 4,
	Flag = "WaterSpamDelay",
	Callback = function(value)
		waterSpamDelay = value / 10
	end,
})

MainTab:CreateSlider({
	Name = "Scoops per fill (fallback)",
	Range = {5, 30},
	Increment = 1,
	Suffix = " scoops",
	CurrentValue = 10,
	Flag = "ScoopsPerFill",
	Callback = function(value)
		scoopsPerFill = value
	end,
})

MainTab:CreateSlider({
	Name = "Delay between steps (seconds)",
	Range = {1, 5},
	Increment = 1,
	Suffix = "s",
	CurrentValue = 1,
	Flag = "StepDelay",
	Callback = function(value)
		stepDelay = value
	end,
})

Rayfield:LoadConfiguration()

task.spawn(function()
	while true do
		if autoFarm or autoSkillTree then
			disableDrowning()
		end
		updateBucketLabel()
		task.wait(0.5)
	end
end)

task.spawn(function()
	while true do
		if autoSkillTree then
			purchaseSkillTree()
		end
		task.wait(2)
	end
end)
