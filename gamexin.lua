if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DISCORD_LINK = "https://discord.gg/Gss5AgSkbh"
local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

pcall(function()
	if setclipboard then
		setclipboard(DISCORD_LINK)
	elseif toclipboard then
		toclipboard(DISCORD_LINK)
	end
end)

-- ===================== FLUENT =====================
local function loadFluent()
	local urls = {
		"https://github.com/StyearX/Fluent-Modded/releases/download/Fluent/FluentPro",
		"https://raw.githubusercontent.com/StyearX/Fluent-modded/main/build/Fluent.lua",
	}
	for _, url in ipairs(urls) do
		local ok, lib = pcall(function()
			return loadstring(game:HttpGet(url))()
		end)
		if ok and type(lib) == "table" and type(lib.CreateWindow) == "function" then
			return lib
		end
	end
	return nil
end

local Fluent = loadFluent()
if not Fluent then
	warn("[MacroAEX] Failed to load Fluent")
	return
end

pcall(function()
	if Fluent.SetErrorHandler then
		Fluent:SetErrorHandler(function() end)
	end
end)

-- ===================== STATE =====================
local MACRO_FOLDER = "DoggeHUB/Macros"

local isRecording = false
local isPlaying = false
local isReplaying = false -- đang phát lại (tránh hook ghi trùng)
local autoPlay = false
local playSpeed = 1
local loopDelay = 0.5
local resumeStartDelay = 4 -- chờ (giây) sau khi vào trận rồi mới Auto Play (để StartGame không fire sớm)

local remoteFilter = {}
local remoteFilterActive = false

-- Replica ID (số đầu trong ReplicaSignal) đổi mỗi phiên → tự học & remap khi phát
local liveSignalId = {} -- "RemoteName::FuncName" -> replica id hiện tại (học từ game)
local autoRemapId = true
local playIdRemap = {} -- oldId -> newId (dựng lúc bắt đầu play)

-- Unit ID ("399"...) do server cấp sau khi đặt unit → bắt id mới sau mỗi PlaceGameUnit
local autoRemapUnit = true
local unitIdRemap = {} -- oldUnitId -> newUnitId (dựng khi play)
local placeOldIds = {} -- frameIndex của PlaceGameUnit -> oldUnitId tương ứng
local unitsContainer = nil

local currentFrames = {} -- action frames theo timeline
local recordStartClock = 0
local configName = "" -- tên config đặt trước khi record
local selectedMacro = nil
local selectedMacroPlace = nil -- PlaceId đích của macro đang chọn (để xử lý teleport)
local macroList = {}
local lastStatus = "Idle"
local lastActionText = "-"

local function setStatus(text)
	lastStatus = text
end

-- ===================== FILE HELPERS =====================
local hasFS = (writefile ~= nil) and (readfile ~= nil) and (listfiles ~= nil)

local function ensureFolder()
	pcall(function()
		if not isfolder then
			return
		end
		if not isfolder("DoggeHUB") then
			makefolder("DoggeHUB")
		end
		if not isfolder(MACRO_FOLDER) then
			makefolder(MACRO_FOLDER)
		end
	end)
end

local function macroPath(name)
	return MACRO_FOLDER .. "/" .. name .. ".json"
end

local function sanitizeName(name)
	name = tostring(name or ""):gsub("[^%w%-_ ]", "")
	name = name:gsub("%s+", "_")
	if name == "" then
		name = "macro_" .. os.date("%H%M%S")
	end
	return name
end

local function refreshMacroList()
	macroList = {}
	if not hasFS then
		return macroList
	end
	ensureFolder()
	pcall(function()
		for _, file in ipairs(listfiles(MACRO_FOLDER)) do
			local name = file:match("([^/\\]+)%.json$")
			if name then
				table.insert(macroList, name)
			end
		end
	end)
	table.sort(macroList)
	return macroList
end

local function saveMacro(name, frames)
	if not hasFS then
		return false, "Executor không hỗ trợ writefile"
	end
	ensureFolder()
	local ok, err = pcall(function()
		local data = {
			place = game.PlaceId,
			count = #frames,
			frames = frames,
		}
		writefile(macroPath(name), HttpService:JSONEncode(data))
	end)
	return ok, err
end

local function loadMacro(name)
	if not hasFS then
		return nil
	end
	local frames = nil
	local ok = pcall(function()
		local raw = readfile(macroPath(name))
		local data = HttpService:JSONDecode(raw)
		frames = data.frames or data
	end)
	if ok and type(frames) == "table" then
		return frames
	end
	return nil
end

local function deleteMacro(name)
	if not hasFS or not delfile then
		return false
	end
	local ok = pcall(function()
		delfile(macroPath(name))
	end)
	return ok
end

-- ===================== IMPORT / EXPORT (SHARE CODE) =====================
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64encode(data)
	return ((data:gsub(".", function(x)
		local r, b = "", x:byte()
		for i = 8, 1, -1 do
			r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0")
		end
		return r
	end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
		if #x < 6 then
			return ""
		end
		local c = 0
		for i = 1, 6 do
			c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
		end
		return B64:sub(c + 1, c + 1)
	end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local function base64decode(data)
	data = string.gsub(data, "[^" .. B64 .. "=]", "")
	return (data:gsub(".", function(x)
		if x == "=" then
			return ""
		end
		local r, f = "", (B64:find(x) - 1)
		for i = 6, 1, -1 do
			r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
		end
		return r
	end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
		if #x ~= 8 then
			return ""
		end
		local c = 0
		for i = 1, 8 do
			c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
		end
		return string.char(c)
	end))
end

local CODE_PREFIX = "AEXMACRO1:"

-- Xuất macro (name) thành code share. Trả về code hoặc nil, err
local function exportMacroCode(name)
	local raw
	if name and name ~= "" then
		local ok, r = pcall(function()
			return readfile(macroPath(name))
		end)
		if ok and type(r) == "string" and r ~= "" then
			raw = r
		end
	end
	if not raw then
		if #currentFrames == 0 then
			return nil, "Không có macro để export"
		end
		raw = HttpService:JSONEncode({
			place = game.PlaceId,
			count = #currentFrames,
			frames = currentFrames,
		})
	end
	return CODE_PREFIX .. base64encode(raw)
end

-- Nhập code → lưu thành macro tên saveName. Trả về ok, name/err
local function importMacroCode(code, saveName)
	code = tostring(code or ""):gsub("%s+", "")
	if code == "" then
		return false, "Code trống"
	end
	local payload = code:match("^AEXMACRO1:(.+)$") or code
	local okDec, json = pcall(base64decode, payload)
	if not okDec or type(json) ~= "string" or json == "" then
		return false, "Code không hợp lệ"
	end

	local data
	local okJson = pcall(function()
		data = HttpService:JSONDecode(json)
	end)
	if not okJson or type(data) ~= "table" then
		return false, "Dữ liệu lỗi"
	end
	local frames = data.frames or data
	if type(frames) ~= "table" or #frames == 0 then
		return false, "Không có action trong code"
	end

	local name = sanitizeName(saveName ~= "" and saveName or ("import_" .. os.date("%H%M%S")))
	if not hasFS then
		-- Không lưu file được → nạp tạm để play trong phiên
		currentFrames = frames
		return true, name .. " (session)"
	end
	local okSave, err = saveMacro(name, frames)
	if okSave then
		return true, name
	end
	return false, tostring(err)
end

-- ===================== TELEPORT RESUME (CROSS-PLACE) =====================
local RESUME_PATH = MACRO_FOLDER .. "/_resume.json"
local LOADER_PATH = MACRO_FOLDER .. "/_loader.txt"
local loaderUrl = ""
local resumeArmed = false

local function loadLoaderUrl()
	pcall(function()
		if isfile and isfile(LOADER_PATH) then
			loaderUrl = tostring(readfile(LOADER_PATH) or ""):gsub("%s+$", "")
		end
	end)
end

local function saveLoaderUrl(url)
	loaderUrl = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
	pcall(function()
		ensureFolder()
		writefile(LOADER_PATH, loaderUrl)
	end)
end

-- place đích của macro (đọc từ file)
local function getMacroPlace(name)
	if not name or name == "" then
		return nil
	end
	local place
	pcall(function()
		local data = HttpService:JSONDecode(readfile(macroPath(name)))
		place = tonumber(data.place)
	end)
	return place
end

local function saveResume(name)
	pcall(function()
		ensureFolder()
		writefile(RESUME_PATH, HttpService:JSONEncode({
			macro = name,
			place = getMacroPlace(name),
		}))
	end)
end

local function readResume()
	local data
	pcall(function()
		if isfile and isfile(RESUME_PATH) then
			data = HttpService:JSONDecode(readfile(RESUME_PATH))
		end
	end)
	return data
end

local function clearResume()
	pcall(function()
		if isfile and isfile(RESUME_PATH) and delfile then
			delfile(RESUME_PATH)
		end
	end)
end

local function getQueueFn()
	return queue_on_teleport
		or queueonteleport
		or (syn and syn.queue_on_teleport)
		or (fluxus and fluxus.queue_on_teleport)
end

-- Xếp hàng chạy lại hub sau teleport (nếu có loader URL + executor hỗ trợ)
local function armTeleportResume(name)
	saveResume(name)
	resumeArmed = true
	local q = getQueueFn()
	if q and loaderUrl ~= "" then
		pcall(function()
			q(string.format('loadstring(game:HttpGet(%q))()', loaderUrl))
		end)
		return true -- tự động chạy lại
	end
	return false -- cần chạy lại tay
end

-- ===================== SERIALIZE ARGS =====================
local function serializeValue(v, depth)
	depth = depth or 0
	if depth > 6 then
		return { __t = "nil" }
	end
	local t = typeof(v)
	if t == "number" or t == "string" or t == "boolean" then
		return v
	elseif t == "nil" then
		return { __t = "nil" }
	elseif t == "Vector3" then
		return { __t = "Vector3", v.X, v.Y, v.Z }
	elseif t == "Vector2" then
		return { __t = "Vector2", v.X, v.Y }
	elseif t == "CFrame" then
		return { __t = "CFrame", c = { v:GetComponents() } }
	elseif t == "Color3" then
		return { __t = "Color3", v.R, v.G, v.B }
	elseif t == "EnumItem" then
		return { __t = "Enum", s = tostring(v) }
	elseif t == "Instance" then
		local ok, full = pcall(function()
			return v:GetFullName()
		end)
		local inGame = false
		pcall(function()
			inGame = v:IsDescendantOf(game)
		end)
		return {
			__t = "Instance",
			path = ok and full or v.Name,
			name = v.Name,
			class = v.ClassName,
			inGame = inGame, -- false = vật thể tạm (vd InputObject) → tạo lại bằng class
		}
	elseif t == "table" then
		local out = { __t = "table", map = {} }
		for k, val in pairs(v) do
			if type(k) == "number" or type(k) == "string" then
				out.map[tostring(k)] = serializeValue(val, depth + 1)
				if type(k) == "number" then
					out.numKeys = out.numKeys or {}
					out.numKeys[tostring(k)] = true
				end
			end
		end
		return out
	end
	return { __t = "nil" }
end

local function resolveInstance(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local segs = {}
	for seg in string.gmatch(path, "[^%.]+") do
		table.insert(segs, seg)
	end
	if #segs == 0 then
		return nil
	end
	local startIdx = 1
	if segs[1] == "game" then
		startIdx = 2
	end
	local cur = game
	for i = startIdx, #segs do
		local nxt = cur:FindFirstChild(segs[i])
		if not nxt and cur == game then
			pcall(function()
				nxt = game:GetService(segs[i])
			end)
		end
		if not nxt then
			return nil
		end
		cur = nxt
	end
	return cur
end

local function resolveEnum(s)
	local parts = {}
	for p in string.gmatch(tostring(s), "[^%.]+") do
		table.insert(parts, p)
	end
	if parts[1] == "Enum" and parts[2] and parts[3] then
		local ok, result = pcall(function()
			return Enum[parts[2]][parts[3]]
		end)
		if ok then
			return result
		end
	end
	return nil
end

local function deserializeValue(v)
	if type(v) ~= "table" then
		return v
	end
	local t = v.__t
	if t == "nil" then
		return nil
	elseif t == "Vector3" then
		return Vector3.new(v[1], v[2], v[3])
	elseif t == "Vector2" then
		return Vector2.new(v[1], v[2])
	elseif t == "CFrame" then
		return CFrame.new(unpack(v.c))
	elseif t == "Color3" then
		return Color3.new(v[1], v[2], v[3])
	elseif t == "Enum" then
		return resolveEnum(v.s)
	elseif t == "Instance" then
		local inst = nil
		if v.inGame ~= false then
			inst = resolveInstance(v.path)
		end
		if not inst and v.class then
			pcall(function()
				inst = Instance.new(v.class)
			end)
		end
		return inst
	elseif t == "table" then
		local out = {}
		for k, val in pairs(v.map or {}) do
			local key = k
			if v.numKeys and v.numKeys[k] then
				key = tonumber(k) or k
			end
			out[key] = deserializeValue(val)
		end
		return out
	end
	return nil
end

local function describeArgs(argList, n)
	local parts = {}
	for i = 1, n do
		local a = argList[i]
		local tv = typeof(a)
		if tv == "Instance" then
			table.insert(parts, a.Name)
		elseif tv == "Vector3" then
			table.insert(parts, string.format("(%.0f,%.0f,%.0f)", a.X, a.Y, a.Z))
		elseif tv == "CFrame" then
			local p = a.Position
			table.insert(parts, string.format("CF(%.0f,%.0f,%.0f)", p.X, p.Y, p.Z))
		else
			table.insert(parts, tostring(a))
		end
	end
	return table.concat(parts, ", ")
end

-- ===================== UNIT ID HELPERS =====================
local function isUnitId(v)
	return type(v) == "string" and v:match("^%d+$") ~= nil
end

-- Tìm folder chứa các unit đã đặt (tên con là số, vd "112")
local function findUnitsContainer()
	if unitsContainer and unitsContainer.Parent then
		return unitsContainer
	end
	for _, name in ipairs({
		"GameUnits", "Units", "PlacedUnits", "SpawnedUnits", "_Units", "UnitsFolder", "Mobs",
	}) do
		local f = workspace:FindFirstChild(name, true)
		if f then
			unitsContainer = f
			return f
		end
	end
	for _, d in ipairs(workspace:GetChildren()) do
		for _, c in ipairs(d:GetChildren()) do
			if isUnitId(c.Name) then
				unitsContainer = d
				return d
			end
		end
	end
	return nil
end

local function snapshotUnits(container)
	local set = {}
	if not container then
		return set
	end
	for _, c in ipairs(container:GetChildren()) do
		if isUnitId(c.Name) then
			set[c.Name] = true
		end
	end
	return set
end

-- Chờ unit mới xuất hiện (so với snapshot before) → trả về id (string) hoặc nil
local function waitNewUnitId(container, before, tries)
	if not container then
		return nil
	end
	for _ = 1, (tries or 24) do
		task.wait(0.05)
		for _, c in ipairs(container:GetChildren()) do
			local nm = c.Name
			if isUnitId(nm) and not before[nm] then
				return nm
			end
		end
	end
	return nil
end

-- ===================== RECORD (ACTIONS ONLY) =====================
local function recordRemoteCall(remote, method, argList, n)
	if not isRecording or isReplaying then
		return
	end
	if remoteFilterActive then
		local matched = remoteFilter[remote.Name]
		-- Kiểu ReplicaSignal: FireServer(id, "TênHành động", ...) → khớp theo arg[2]/arg[1]
		if not matched and type(argList[2]) == "string" and remoteFilter[argList[2]] then
			matched = true
		end
		if not matched and type(argList[1]) == "string" and remoteFilter[argList[1]] then
			matched = true
		end
		if not matched then
			return
		end
	end

	local args = {}
	for i = 1, n do
		args[i] = serializeValue(argList[i])
	end

	local ok, path = pcall(function()
		return remote:GetFullName()
	end)

	local frame = {
		type = "remote",
		t = os.clock() - recordStartClock,
		path = ok and path or remote.Name,
		name = remote.Name,
		method = method,
		n = n,
		args = args,
	}
	table.insert(currentFrames, frame)

	-- Bắt unit id thật do server cấp sau khi đặt → lưu vào frame để replay map chính xác
	if argList[2] == "PlaceGameUnit" then
		local container = findUnitsContainer()
		local before = snapshotUnits(container)
		task.spawn(function()
			local newId = waitNewUnitId(container, before, 40)
			if newId then
				frame.unitId = newId
			end
		end)
	end

	lastActionText = string.format("%s(%s)", remote.Name, describeArgs(argList, n))
	setStatus("REC: " .. lastActionText)
end

local function startRecording(name)
	if isRecording then
		return
	end
	configName = sanitizeName(name)
	currentFrames = {}
	recordStartClock = os.clock()
	isRecording = true
	setStatus("Recording → " .. configName)
end

-- trả về: saved(bool), savedName, err
local function stopAndSaveRecording()
	if not isRecording then
		return false, nil, "not recording"
	end
	isRecording = false

	if #currentFrames == 0 then
		setStatus("Dừng: không có action nào để lưu")
		return false, configName, "empty"
	end

	local name = sanitizeName(configName)
	local ok, err = saveMacro(name, currentFrames)
	if ok then
		setStatus(string.format("Đã lưu '%s' (%d action)", name, #currentFrames))
		return true, name, nil
	end
	setStatus("Lưu lỗi: " .. tostring(err))
	return false, name, err
end

-- Học Replica ID hiện tại theo tên hành động (arg2), từ chính các lần game fire
local function learnSignalId(remote, argList, n)
	if isReplaying then
		return
	end
	if n >= 2 and type(argList[1]) == "number" and type(argList[2]) == "string" then
		liveSignalId[remote.Name .. "::" .. argList[2]] = argList[1]
	end
end

local function installRemoteHook()
	if not getrawmetatable or not newcclosure or not getnamecallmethod then
		setStatus("Executor thiếu hook → không record được action")
		return false
	end

	local okMt, mt = pcall(getrawmetatable, game)
	if not okMt or type(mt) ~= "table" then
		return false
	end

	local oldNamecall = mt.__namecall
	if type(oldNamecall) ~= "function" then
		return false
	end

	pcall(function()
		if setreadonly then
			setreadonly(mt, false)
		end
	end)

	mt.__namecall = newcclosure(function(self, ...)
		local method = getnamecallmethod()
		if (method == "FireServer" or method == "InvokeServer")
			and not isReplaying
			and typeof(self) == "Instance"
		then
			local args = { ... }
			local n = select("#", ...)
			task.spawn(learnSignalId, self, args, n)
			if isRecording then
				task.spawn(recordRemoteCall, self, method, args, n)
			end
		end
		return oldNamecall(self, ...)
	end)

	pcall(function()
		if setreadonly then
			setreadonly(mt, true)
		end
	end)
	return true
end

-- ===================== PLAY =====================
local function framesToPlay()
	if selectedMacro then
		local f = loadMacro(selectedMacro)
		if f and #f > 0 then
			return f
		end
	end
	if #currentFrames > 0 then
		return currentFrames
	end
	return nil
end

-- Với mỗi PlaceGameUnit → unit id cũ tương ứng.
-- Ưu tiên frame.unitId (ghi chính xác lúc record); fallback theo thứ tự xuất hiện.
local function computePlaceOldIds(frames)
	local result = {}
	local assigned = {}
	for i, f in ipairs(frames) do
		local a = f.args
		if a and a[2] == "PlaceGameUnit" then
			if isUnitId(f.unitId) then
				result[i] = f.unitId
				assigned[f.unitId] = true
			else
				for j = i + 1, #frames do
					local b = frames[j].args
					local uid = b and b[3]
					if isUnitId(uid) and not assigned[uid] then
						result[i] = uid
						assigned[uid] = true
						break
					end
				end
			end
		end
	end
	return result
end

local expectedUnitOld = {} -- set các unit id cũ sẽ được cấp lại (giá trị của placeOldIds)

local function playRemoteFrame(frame, frameIndex)
	local remote = resolveInstance(frame.path)
	if not remote then
		remote = ReplicatedStorage:FindFirstChild(frame.name, true)
	end
	if not remote then
		setStatus("Không tìm thấy remote: " .. tostring(frame.name))
		return
	end
	local n = frame.n or #frame.args
	local args = {}
	for i = 1, n do
		args[i] = deserializeValue(frame.args[i])
	end

	-- Remap Replica ID cũ → ID hiện tại của phiên này
	local remapNote = ""
	if autoRemapId and type(args[1]) == "number" then
		local newId
		if type(args[2]) == "string" then
			newId = liveSignalId[remote.Name .. "::" .. args[2]]
		end
		newId = newId or playIdRemap[args[1]]
		if newId and newId ~= args[1] then
			remapNote = string.format(" [id %s→%s]", tostring(args[1]), tostring(newId))
			args[1] = newId
		end
	end

	-- Remap Unit ID (arg3 chuỗi số) cho Upgrade / ChangePriority / Sell...
	if autoRemapUnit and isUnitId(args[3]) then
		local newUid = unitIdRemap[args[3]]
		-- Nếu unit này sắp được cấp id mới nhưng chưa capture xong → chờ tối đa ~0.8s
		if not newUid and expectedUnitOld[args[3]] then
			for _ = 1, 16 do
				if unitIdRemap[args[3]] then
					break
				end
				task.wait(0.05)
			end
			newUid = unitIdRemap[args[3]]
		end
		if newUid and newUid ~= args[3] then
			remapNote = remapNote .. string.format(" [unit %s→%s]", args[3], newUid)
			args[3] = newUid
		end
	end

	local isPlace = args[2] == "PlaceGameUnit"
	local pendingOldUnit = isPlace and autoRemapUnit and placeOldIds[frameIndex] or nil
	local before, container
	if pendingOldUnit then
		container = findUnitsContainer()
		before = snapshotUnits(container)
	end

	isReplaying = true
	local ok, err = pcall(function()
		if frame.method == "InvokeServer" then
			remote:InvokeServer(unpack(args, 1, n))
		else
			remote:FireServer(unpack(args, 1, n))
		end
	end)
	isReplaying = false

	-- Bắt unit id mới do server cấp sau khi đặt
	if pendingOldUnit and container then
		task.spawn(function()
			local newId = waitNewUnitId(container, before, 30)
			if newId then
				unitIdRemap[pendingOldUnit] = newId
			end
		end)
	end

	setStatus(string.format("%s(%s)%s %s",
		tostring(frame.method == "InvokeServer" and "invoke" or "fire"),
		describeArgs(args, n),
		remapNote,
		ok and "OK" or ("ERR: " .. tostring(err))
	))
end

-- Dựng bảng remap oldId→newId: suy ra từ các func đã học được ID hiện tại
-- (1 replica xử lý nhiều func, nên học 1 func là remap được cả nhóm cùng oldId)
local function buildIdRemap(frames)
	local remap = {}
	for _, f in ipairs(frames) do
		local a = f.args
		if a and type(a[1]) == "number" and type(a[2]) == "string" then
			local liveId = liveSignalId[(f.name or "") .. "::" .. a[2]]
			if liveId and liveId ~= a[1] then
				remap[a[1]] = liveId
			end
		end
	end
	return remap
end

local MAX_GAP = 20 -- clamp khoảng chờ tối đa giữa 2 action (giây)

local function playFrames(frames)
	playIdRemap = autoRemapId and buildIdRemap(frames) or {}

	-- Chuẩn bị remap unit id: mỗi lần play là 1 phiên đặt mới → reset
	unitIdRemap = {}
	placeOldIds = autoRemapUnit and computePlaceOldIds(frames) or {}
	expectedUnitOld = {}
	for _, oldId in pairs(placeOldIds) do
		expectedUnitOld[oldId] = true
	end

	-- Chuẩn hoá: action đầu tiên bắt đầu ngay (bỏ khoảng idle lúc mới record)
	local baseT = frames[1] and frames[1].t or 0
	local prevT = baseT
	for i, frame in ipairs(frames) do
		if not isPlaying then
			break
		end
		local ft = frame.t or prevT
		local dt = (ft - prevT) / math.max(playSpeed, 0.01)
		prevT = ft
		if dt > MAX_GAP then
			dt = MAX_GAP
		end
		if dt > 0 then
			task.wait(dt)
		end
		playRemoteFrame(frame, i)
		setStatus(string.format("Playing %d/%d", i, #frames))
	end
	return true
end

local function playOnce()
	if isPlaying then
		return
	end
	local frames = framesToPlay()
	if not frames then
		setStatus("Chưa có macro để play")
		return
	end
	isPlaying = true
	setStatus("Playing...")
	playFrames(frames)
	isPlaying = false
	setStatus("Play xong")
end

-- ===================== LOOPS =====================
local resumeNotified = false

task.spawn(function()
	while true do
		if autoPlay and not isPlaying and not isRecording then
			local frames = framesToPlay()
			if frames then
				isPlaying = true
				setStatus("Auto Play: " .. tostring(selectedMacro))
				playFrames(frames)
				isPlaying = false
				task.wait(loopDelay)
			else
				setStatus("Auto Play: chưa chọn macro")
				task.wait(1)
			end
		else
			task.wait(0.2)
		end
	end
end)

local hookOk = installRemoteHook()
loadLoaderUrl()
refreshMacroList()

-- ===================== UI =====================
local Window = Fluent:CreateWindow({
	Title = "Dogge HUB",
	SubTitle = "Macro AEX | Action Record",
	TabWidth = 160,
	Size = UDim2.fromOffset(480, 460),
	Acrylic = not isMobile,
	Theme = "AMOLED",
	MinimizeKey = Enum.KeyCode.LeftControl,
	Search = true,
})

local Tabs = {
	Map = Window:AddTab({ Title = "Map", Icon = "solar/map-bold" }),
	Game = Window:AddTab({ Title = "Game", Icon = "solar/gamepad-bold" }),
	Summon = Window:AddTab({ Title = "Summon", Icon = "solar/magic-stick-3-bold" }),
	Record = Window:AddTab({ Title = "Record", Icon = "solar/record-circle-bold" }),
	Play = Window:AddTab({ Title = "Play", Icon = "solar/play-circle-bold" }),
	Share = Window:AddTab({ Title = "Share", Icon = "solar/share-bold" }),
	Settings = Window:AddTab({ Title = "Settings", Icon = "solar/settings-bold" }),
}

local statusParagraph = Tabs.Record:AddParagraph({
	Title = "Status",
	Content = "Idle",
})

task.spawn(function()
	while true do
		statusParagraph:SetDesc(string.format(
			"%s\nConfig: %s | Actions: %d\nLast: %s\nHook: %s",
			lastStatus,
			(configName ~= "" and configName) or "(chưa đặt tên)",
			#currentFrames,
			lastActionText,
			hookOk and "OK" or "FAIL"
		))
		task.wait(0.3)
	end
end)

local macroDropdown
local recordMacroDropdown
local configNameInput = ""
local recordToggleRef

local function refreshAllDropdowns(selectName)
	refreshMacroList()
	if macroDropdown then
		macroDropdown:SetValues(macroList)
	end
	if recordMacroDropdown then
		recordMacroDropdown:SetValues(macroList)
	end
	-- Nếu chưa chọn macro để play, mặc định chọn cái đầu (để Auto Play có sẵn macro)
	if not selectName and not selectedMacro and macroList[1] then
		selectName = macroList[1]
	end
	if selectName then
		selectedMacro = selectName
		selectedMacroPlace = getMacroPlace(selectName)
		if macroDropdown then
			pcall(function()
				macroDropdown:SetValue(selectName)
			end)
		end
	end
end

Tabs.Record:AddInput("ConfigName", {
	Title = "Config Name",
	Default = "",
	Placeholder = "name before record",
	Numeric = false,
	Finished = true,
	Callback = function(value)
		configNameInput = value
	end,
})

recordMacroDropdown = Tabs.Record:AddDropdown("EditMacro", {
	Title = "Select Macro (re-record / delete)",
	Values = macroList,
	Multi = false,
	Default = nil,
	Callback = function(value)
		if not value then
			return
		end
		configNameInput = value
		pcall(function()
			if Fluent.Options and Fluent.Options.ConfigName then
				Fluent.Options.ConfigName:SetValue(value)
			end
		end)
		setStatus("Sẽ record đè: " .. tostring(value))
	end,
})

Tabs.Record:AddButton({
	Title = "Refresh Macro List",
	Callback = function()
		refreshAllDropdowns()
		Fluent:Notify({ Title = "Macro", Content = #macroList .. " macro", Duration = 2 })
	end,
})

Tabs.Record:AddButton({
	Title = "Delete Macro",
	Callback = function()
		local target = configNameInput ~= "" and sanitizeName(configNameInput) or nil
		if not target then
			Fluent:Notify({ Title = "Macro", Content = "Chọn macro trước", Duration = 2 })
			return
		end
		if deleteMacro(target) then
			if selectedMacro == target then
				selectedMacro = nil
			end
			refreshAllDropdowns()
			Fluent:Notify({ Title = "Macro", Content = "Đã xoá: " .. target, Duration = 3 })
		else
			Fluent:Notify({ Title = "Macro", Content = "Xoá lỗi / không tồn tại", Duration = 3 })
		end
	end,
})

Tabs.Record:AddInput("RemoteFilter", {
	Title = "Chỉ ghi hành động (tuỳ chọn)",
	Description = "Tên action/remote, cách nhau dấu phẩy. Trống = ghi tất cả",
	Default = "",
	Placeholder = "vd: PlaceGameUnit, UpgradeGameUnit",
	Numeric = false,
	Finished = true,
	Callback = function(value)
		remoteFilter = {}
		remoteFilterActive = false
		for part in string.gmatch(tostring(value or ""), "[^,]+") do
			local trimmed = part:gsub("^%s+", ""):gsub("%s+$", "")
			if trimmed ~= "" then
				remoteFilter[trimmed] = true
				remoteFilterActive = true
			end
		end
	end,
})

recordToggleRef = Tabs.Record:AddToggle("RecordToggle", {
	Title = "Record",
	Description = "Bật = ghi | Tắt = dừng & tự lưu vào config",
	Default = false,
	Callback = function(value)
		if value then
			startRecording(configNameInput)
			Fluent:Notify({
				Title = "Macro",
				Content = "Recording → " .. configName,
				Duration = 2,
			})
		else
			local saved, name = stopAndSaveRecording()
			if saved then
				refreshAllDropdowns(name)
				selectedMacro = name
				Fluent:Notify({ Title = "Macro", Content = "Đã lưu: " .. name, Duration = 3 })
			else
				Fluent:Notify({
					Title = "Macro",
					Content = "Không lưu (chưa có action nào)",
					Duration = 3,
				})
			end
		end
	end,
})

macroDropdown = Tabs.Play:AddDropdown("MapSelect", {
	Title = "Select Macro",
	Description = "Pick the recorded macro to auto play",
	Values = macroList,
	Multi = false,
	Default = macroList[1],
	Callback = function(value)
		selectedMacro = value
		selectedMacroPlace = getMacroPlace(value)
		resumeNotified = false
		setStatus("Macro: " .. tostring(value))
	end,
})

Tabs.Play:AddToggle("AutoPlay", {
	Title = "Auto Play",
	Default = false,
	Callback = function(value)
		autoPlay = value
		if not value then
			isPlaying = false
		end
	end,
})

local learnedParagraph = Tabs.Play:AddParagraph({
	Title = "Learned IDs (phiên này)",
	Content = "Chưa học id nào. Tự làm 1 lần mỗi action trong trận để hub học id hiện tại.",
})

task.spawn(function()
	while true do
		task.wait(1)
		local lines = {}
		for key, id in pairs(liveSignalId) do
			local func = key:match("::(.+)$") or key
			lines[#lines + 1] = func .. " = " .. tostring(id)
		end
		local content
		if #lines == 0 then
			content = "Chưa học id nào. Tự làm 1 lần mỗi action trong trận để hub học id hiện tại."
		else
			table.sort(lines)
			content = table.concat(lines, "\n")
		end
		pcall(function()
			if learnedParagraph and learnedParagraph.SetDesc then
				learnedParagraph:SetDesc(content)
			elseif learnedParagraph and learnedParagraph.SetContent then
				learnedParagraph:SetContent(content)
			end
		end)
	end
end)

-- ===================== SHARE TAB =====================
local function copyToClipboard(text)
	pcall(function()
		if setclipboard then
			setclipboard(text)
		elseif toclipboard then
			toclipboard(text)
		end
	end)
end

Tabs.Share:AddParagraph({
	Title = "Export",
	Content = "Chọn macro ở tab Record/Play rồi bấm Export để copy code chia sẻ.",
})

Tabs.Share:AddButton({
	Title = "Export selected → copy code",
	Callback = function()
		local name = (configNameInput ~= "" and sanitizeName(configNameInput)) or selectedMacro
		local code, err = exportMacroCode(name)
		if not code then
			Fluent:Notify({ Title = "Export", Content = tostring(err), Duration = 3 })
			return
		end
		copyToClipboard(code)
		Fluent:Notify({
			Title = "Export",
			Content = string.format("Đã copy code (%d ký tự)", #code),
			Duration = 3,
		})
	end,
})

local importCodeInput = ""
local importNameInput = ""

Tabs.Share:AddInput("ImportCode", {
	Title = "Import Code",
	Default = "",
	Placeholder = "dán code AEXMACRO1:...",
	Numeric = false,
	Finished = true,
	Callback = function(value)
		importCodeInput = value
	end,
})

Tabs.Share:AddInput("ImportName", {
	Title = "Import as name (tuỳ chọn)",
	Default = "",
	Placeholder = "tên lưu, trống = tự đặt",
	Numeric = false,
	Finished = true,
	Callback = function(value)
		importNameInput = value
	end,
})

Tabs.Share:AddButton({
	Title = "Import code → save",
	Callback = function()
		local ok, nameOrErr = importMacroCode(importCodeInput, importNameInput)
		if ok then
			refreshAllDropdowns(nameOrErr)
			selectedMacro = nameOrErr
			Fluent:Notify({ Title = "Import", Content = "Đã nhập: " .. nameOrErr, Duration = 3 })
		else
			Fluent:Notify({ Title = "Import", Content = "Lỗi: " .. tostring(nameOrErr), Duration = 4 })
		end
	end,
})

Tabs.Settings:AddSlider("PlaySpeed", {
	Title = "Play speed (x)",
	Default = 1,
	Min = 0.25,
	Max = 5,
	Rounding = 2,
	Callback = function(value)
		playSpeed = value
	end,
})

Tabs.Settings:AddSlider("LoopDelay", {
	Title = "Delay giữa các vòng (s)",
	Default = 0.5,
	Min = 0,
	Max = 10,
	Rounding = 2,
	Callback = function(value)
		loopDelay = value
	end,
})

Tabs.Settings:AddSlider("ResumeDelay", {
	Title = "Delay sau khi vào trận (s)",
	Description = "Chờ trận load rồi mới Auto Play StartGame",
	Default = 4,
	Min = 0,
	Max = 15,
	Rounding = 1,
	Callback = function(value)
		resumeStartDelay = value
	end,
})

Tabs.Settings:AddInput("LoaderUrl", {
	Title = "Loader URL (auto-continue sau teleport)",
	Description = "Dán URL loadstring của hub để tự chạy lại khi vào map. Trống = chạy lại tay.",
	Default = loaderUrl,
	Placeholder = "https://.../macroaex.lua",
	Numeric = false,
	Finished = true,
	Callback = function(value)
		saveLoaderUrl(value)
		Fluent:Notify({
			Title = "Loader",
			Content = loaderUrl ~= "" and "Đã lưu loader URL" or "Đã xoá loader URL",
			Duration = 2,
		})
	end,
})

Tabs.Settings:AddParagraph({
	Title = "Storage",
	Content = hasFS
		and ("Lưu tại: " .. MACRO_FOLDER)
		or "Executor KHÔNG hỗ trợ writefile — chỉ record/play tạm trong phiên",
})

-- Đảm bảo cả 2 dropdown hiển thị macro có sẵn trong folder sau khi UI dựng xong
refreshAllDropdowns()

-- Auto-resume sau teleport: nếu có resume và đang ở đúng place → tự Auto Play tiếp
do
	local resume = readResume()
	if resume and resume.macro then
		local targetPlace = tonumber(resume.place)
		if not targetPlace or targetPlace == game.PlaceId then
			clearResume()
			selectedMacro = resume.macro
			selectedMacroPlace = getMacroPlace(resume.macro)
			pcall(function()
				if macroDropdown then
					macroDropdown:SetValue(resume.macro)
				end
			end)
			Fluent:Notify({
				Title = "Auto Play",
				Content = "Vào trận · chờ load rồi tự chơi: " .. resume.macro,
				Duration = 4,
			})
			-- Chờ trận load ổn định (nhân vật + replica) rồi mới Auto Play StartGame
			task.spawn(function()
				pcall(function()
					if not LocalPlayer.Character then
						LocalPlayer.CharacterAdded:Wait()
					end
				end)
				task.wait(resumeStartDelay)
				autoPlay = true
				pcall(function()
					if Fluent.Options and Fluent.Options.AutoPlay then
						Fluent.Options.AutoPlay:SetValue(true)
					end
				end)
			end)
		end
	end
end

Fluent:Notify({
	Title = "Macro AEX",
	Content = string.format(
		"Loaded · %d macro · Hook %s",
		#macroList,
		hookOk and "OK" or "FAIL"
	),
	Duration = 4,
})

-- ===================== MAP TAB (Select Map / Chapter / Gamemode) =====================
-- Gọi trực tiếp bảng Network của game (_G.Net) -> không cần click / không cần id động.
local function findNet()
	if _G.Net and type(_G.Net) == "table" and type(_G.Net.StartGame) == "function" then
		return _G.Net
	end
	local _getgc = getgc or get_gc_objects
	if not _getgc then return nil end
	for _, t in ipairs(_getgc(true)) do
		if type(t) == "table" then
			local ok = pcall(function()
				return type(t.StartGame) == "function"
					and type(t.PartyStartGame) == "function"
					and type(t.SetQueueData) == "function"
			end)
			if ok and type(t.StartGame) == "function"
				and type(t.PartyStartGame) == "function"
				and type(t.SetQueueData) == "function" then
				_G.Net = t
				return t
			end
		end
	end
	return nil
end

local mapNet = findNet()
local mapQueue = {
	Gamemode   = "Story",
	MapName    = "SchoolGrounds",
	Difficulty = "Normal",
	ActName    = "Act 1",
}
local mapLooping = false
local mapLoopDelay = 5

local function buildQueueData()
	-- Game luôn gửi đủ 4 field (kể cả Infinite vẫn có ActName="Act 1")
	return {
		Gamemode   = mapQueue.Gamemode,
		MapName    = mapQueue.MapName,
		Difficulty = mapQueue.Difficulty,
		ActName    = (mapQueue.ActName ~= nil and mapQueue.ActName ~= "") and mapQueue.ActName or "Act 1",
	}
end

local function startMap()
	if not mapNet then mapNet = findNet() end
	if not mapNet then return false, "Net not found" end
	local data = buildQueueData()
	local ok, err = pcall(function()
		mapNet.CancelMatchmaking()
		mapNet.SetQueueData(data)
		mapNet.PartySetQueueData(data)
		task.wait(0.15)
		mapNet.PartyStartGame(data)
	end)
	return ok, err
end
local function getMapsForMode(mode)
	local names = {}
	pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local maps
		local shared = rs:FindFirstChild("Shared")
		if shared then
			local info = shared:FindFirstChild("Information")
			if info then maps = info:FindFirstChild("Maps") end
		end
		if not maps then
			for _, d in ipairs(rs:GetDescendants()) do
				if d.Name == "Maps" and (d:IsA("Folder") or d:IsA("ModuleScript")) then maps = d break end
			end
		end
		if not maps then return end
		local modeFolder = maps:FindFirstChild(mode)
		local children = modeFolder and modeFolder:GetChildren() or maps:GetChildren()
		for _, m in ipairs(children) do
			if m:IsA("ModuleScript") or m:IsA("Folder") then names[#names + 1] = m.Name end
		end
	end)
	table.sort(names)
	return names
end

local mapDropdown

-- Khóa tên map hiện tại: tách theo Map + Mode + (Act nếu Story) + Difficulty
-- => challenge / normal story / hard... đều có macro riêng
local function currentMapKey()
	local parts = { mapQueue.MapName, mapQueue.Gamemode }
	if mapQueue.Gamemode == "Story" then
		parts[#parts + 1] = mapQueue.ActName
	end
	if mapQueue.Difficulty and mapQueue.Difficulty ~= "" then
		parts[#parts + 1] = mapQueue.Difficulty
	end
	return sanitizeName(table.concat(parts, "_"))
end

-- Đồng bộ lựa chọn Map -> gợi ý tên record + auto chọn macro Play khớp map
local function syncMacroToMap()
	local key = currentMapKey()
	configNameInput = key
	pcall(function()
		if Fluent.Options and Fluent.Options.ConfigName then
			Fluent.Options.ConfigName:SetValue(key)
		end
	end)
	refreshMacroList()
	for _, n in ipairs(macroList) do
		if n == key then
			selectedMacro = key
			selectedMacroPlace = getMacroPlace(key)
			pcall(function() if macroDropdown then macroDropdown:SetValue(key) end end)
			setStatus("Map macro: " .. key)
			return
		end
	end
	setStatus("Chưa có macro cho map: " .. key)
end

Tabs.Map:AddDropdown("MapGamemode", {
	Title = "Mode",
	Values = { "Story", "Challenge", "Infinite", "Mastery", "Expedition" },
	Multi = false,
	Default = "Story",
	Callback = function(v)
		mapQueue.Gamemode = v
		local list = getMapsForMode(v)
		if #list > 0 and mapDropdown then
			mapDropdown:SetValues(list)
			mapDropdown:SetValue(list[1])
			mapQueue.MapName = list[1]
		end
		syncMacroToMap()
	end,
})

do
	local initMaps = getMapsForMode("Story")
	if #initMaps == 0 then initMaps = { "SchoolGrounds" } end
	mapQueue.MapName = initMaps[1]
	mapDropdown = Tabs.Map:AddDropdown("MapNameDrop", {
		Title = "Map",
		Values = initMaps,
		Multi = false,
		Default = initMaps[1],
		Callback = function(v) mapQueue.MapName = v; syncMacroToMap() end,
	})
end

Tabs.Map:AddDropdown("MapDifficulty", {
	Title = "Difficulty",
	Values = { "Normal", "Hard", "Hardmode" },
	Multi = false,
	Default = "Normal",
	Callback = function(v) mapQueue.Difficulty = v; syncMacroToMap() end,
})

do
	local mapActs = {}
	for i = 1, 5 do mapActs[i] = "Act " .. i end
	Tabs.Map:AddDropdown("MapAct", {
		Title = "Act (Story only)",
		Values = mapActs,
		Multi = false,
		Default = "Act 1",
		Callback = function(v) mapQueue.ActName = v; syncMacroToMap() end,
	})
end

Tabs.Map:AddButton({
	Title = "Start",
	Callback = function()
		local ok, err = startMap()
		if not ok then
			Fluent:Notify({ Title = "Map", Content = tostring(err), Duration = 3 })
		end
	end,
})

Tabs.Map:AddToggle("MapAuto", {
	Title = "Auto Map",
	Default = false,
	Callback = function(on)
		mapLooping = on
		if on then
			task.spawn(function()
				while mapLooping do
					startMap()
					local t = 0
					while mapLooping and t < mapLoopDelay do task.wait(1); t = t + 1 end
				end
			end)
		end
	end,
})

Tabs.Map:AddSlider("MapLoopDelay", {
	Title = "Auto Delay (s)",
	Default = 5, Min = 1, Max = 180, Rounding = 0,
	Callback = function(v) mapLoopDelay = v end,
})

-- ===================== SUMMON TAB (Auto Roll + click ngoài để skip) =====================
-- Net.Summon(banner, amount) ; skip animation: Net.HandleInput("ClickInstance", true/false)
local summonBanner = "Standard"
local summonAmount = 10
local summonDelay = 1
local summonAutoSkip = true
local summonRolling = false

local function doSkipClick()
	if not mapNet then mapNet = findNet() end
	if not mapNet or type(mapNet.HandleInput) ~= "function" then return end
	pcall(function()
		for _ = 1, 3 do
			mapNet.HandleInput("ClickInstance", true)
			mapNet.HandleInput("ClickInstance", false)
			task.wait(0.1)
		end
	end)
end

local function doSummon()
	if not mapNet then mapNet = findNet() end
	if not mapNet or type(mapNet.Summon) ~= "function" then return false, "Net not found" end
	local ok, err = pcall(function() mapNet.Summon(summonBanner, summonAmount) end)
	if ok and summonAutoSkip then
		task.wait(0.3)
		doSkipClick()
	end
	return ok, err
end

Tabs.Summon:AddDropdown("SummonAmount", {
	Title = "Amount",
	Values = { "1", "10" },
	Multi = false,
	Default = "10",
	Callback = function(v) summonAmount = tonumber(v) or 10 end,
})

Tabs.Summon:AddToggle("SummonSkip", {
	Title = "Auto Skip (click ngoài)",
	Default = true,
	Callback = function(v) summonAutoSkip = v end,
})

Tabs.Summon:AddButton({
	Title = "Summon Once",
	Callback = function()
		local ok, err = doSummon()
		if not ok then Fluent:Notify({ Title = "Summon", Content = tostring(err), Duration = 3 }) end
	end,
})

Tabs.Summon:AddToggle("SummonAuto", {
	Title = "Auto Roll",
	Default = false,
	Callback = function(on)
		summonRolling = on
		if on then
			task.spawn(function()
				while summonRolling do
					doSummon()
					local t = 0
					while summonRolling and t < summonDelay do task.wait(0.2); t = t + 0.2 end
				end
			end)
		end
	end,
})

Tabs.Summon:AddSlider("SummonDelay", {
	Title = "Roll Delay (s)",
	Default = 1, Min = 0, Max = 30, Rounding = 1,
	Callback = function(v) summonDelay = v end,
})

Tabs.Summon:AddButton({
	Title = "Skip (click ngoài)",
	Callback = function() doSkipClick() end,
})

-- ===================== GAME TAB (Auto Next / Auto Replay trong trận) =====================
-- ReplicaSignal:FireServer(id, "Next"/"Restart"). id học từ hook, fallback 55.
local gameNextOn = false
local gameReplayOn = false
local gameNextDelay = 3
local gameReplayDelay = 3

local function getRoundId()
	for _, fn in ipairs({ "Next", "Restart", "PlaceGameUnit", "UpgradeGameUnit", "SelectSlot", "SelectSlotFromUnitID", "ChangeGameUnitPriority" }) do
		local id = liveSignalId["ReplicaSignal::" .. fn]
		if id then return id end
	end
	return 55
end

local function fireReplica(action)
	pcall(function()
		local re = ReplicatedStorage:FindFirstChild("RemoteEvents")
		local remote = re and re:FindFirstChild("ReplicaSignal")
		if remote then
			remote:FireServer(getRoundId(), action)
		end
	end)
end

Tabs.Game:AddButton({
	Title = "Next (skip wave)",
	Callback = function() fireReplica("Next") end,
})

Tabs.Game:AddToggle("GameAutoNext", {
	Title = "Auto Next",
	Default = false,
	Callback = function(on)
		gameNextOn = on
		if on then
			task.spawn(function()
				while gameNextOn do
					fireReplica("Next")
					local t = 0
					while gameNextOn and t < gameNextDelay do task.wait(0.2); t = t + 0.2 end
				end
			end)
		end
	end,
})

Tabs.Game:AddSlider("GameNextDelay", {
	Title = "Next Delay (s)",
	Default = 3, Min = 0.2, Max = 30, Rounding = 1,
	Callback = function(v) gameNextDelay = v end,
})

Tabs.Game:AddButton({
	Title = "Restart (replay)",
	Callback = function() fireReplica("Restart") end,
})

Tabs.Game:AddToggle("GameAutoReplay", {
	Title = "Auto Replay",
	Default = false,
	Callback = function(on)
		gameReplayOn = on
		if on then
			task.spawn(function()
				while gameReplayOn do
					fireReplica("Restart")
					local t = 0
					while gameReplayOn and t < gameReplayDelay do task.wait(0.2); t = t + 0.2 end
				end
			end)
		end
	end,
})

Tabs.Game:AddSlider("GameReplayDelay", {
	Title = "Replay Delay (s)",
	Default = 3, Min = 0.2, Max = 60, Rounding = 1,
	Callback = function(v) gameReplayDelay = v end,
})
