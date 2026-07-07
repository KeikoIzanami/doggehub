-- Place router example (Roblox Studio)
-- Put this as a LocalScript in StarterPlayerScripts (recommended),
-- and create ModuleScripts in ReplicatedStorage/Loaders/.
--
-- Requirements:
-- - Game Settings -> Security -> Allow HTTP Requests = ON
--
-- gamelist.json example:
-- {
--   "games": [
--     { "placeId": 138381251771774, "name": "Drain the Lake", "module": "DrainTheLake" },
--     { "placeId": 0, "name": "Default", "module": "Default" }
--   ]
-- }

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GAMELIST_URL = "https://your-domain.com/gamelist.json" -- TODO: change this

local LoadersFolder = ReplicatedStorage:WaitForChild("Loaders")

local function fetchGameList()
	local body = HttpService:GetAsync(GAMELIST_URL, true)
	return HttpService:JSONDecode(body)
end

local function resolveModuleName(gamelist, placeId)
	if type(gamelist) ~= "table" or type(gamelist.games) ~= "table" then
		return "Default"
	end

	for _, g in ipairs(gamelist.games) do
		if type(g) == "table" and g.placeId == placeId and type(g.module) == "string" then
			return g.module
		end
	end

	return "Default"
end

local moduleName = "Default"
do
	local ok, gamelist = pcall(fetchGameList)
	if ok then
		moduleName = resolveModuleName(gamelist, game.PlaceId)
	end
end

local loader = LoadersFolder:WaitForChild(moduleName)
require(loader).Init()

