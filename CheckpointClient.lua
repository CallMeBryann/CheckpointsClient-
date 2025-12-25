-- StarterPlayerScripts/TerlaClient/CheckpointClient
-- INTEGRATED WITH SHAKE + BLUR + FULLSCREEN CP NOTIFICATION

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

if _G.__SUMMIT_UI_BOUND_V8 then
	script:Destroy()
	return
end
_G.__SUMMIT_UI_BOUND_V8 = true

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local cam = workspace.CurrentCamera

local function safeWait(parent, childName, timeout)
	timeout = timeout or 15
	local startTime = tick()
	while (tick() - startTime) < timeout do
		local child = parent:FindFirstChild(childName)
		if child then return child end
		task.wait(0.1)
	end
	warn("[CheckpointClient] Timeout waiting for:", childName)
	return nil
end

local resetEvent = safeWait(ReplicatedStorage, "CP_DropToStart")
local resetAckRE = safeWait(ReplicatedStorage, "CP_DropAck")
local markVisitedRE = safeWait(ReplicatedStorage, "CP_MarkVisited")
local resetVisitedRE = safeWait(ReplicatedStorage, "CP_ResetVisited")
local skipDeniedRE = safeWait(ReplicatedStorage, "CP_SkipDenied")
local syncStateRE = safeWait(ReplicatedStorage, "CP_SyncState")
local customMsgRE = safeWait(ReplicatedStorage, "CP_CustomMessage")
local getCfgRF = safeWait(ReplicatedStorage, "CP_GetPublicConfig")

if not (resetEvent and resetAckRE and markVisitedRE and resetVisitedRE and getCfgRF) then
	warn("[CheckpointClient] Required remotes not found")
	_G.__SUMMIT_UI_BOUND_V8 = nil
	script:Destroy()
	return
end

local CFG = nil
pcall(function()
	CFG = getCfgRF:InvokeServer()
end)

if not CFG then
	warn("[CheckpointClient] Failed to get config")
	_G.__SUMMIT_UI_BOUND_V8 = nil
	script:Destroy()
	return
end

local FOLDER = assert(CFG.FolderName, "No FolderName")
local PREFIX = assert(CFG.PartPrefix, "No PartPrefix")
local START = assert(CFG.StartIndex, "No StartIndex")
local FINISH = assert(CFG.FinishIndex, "No FinishIndex")
local SKIP = (CFG.SkipMode == true)

local SHOW_RESET = (CFG.ShowResetButton == true)
local SHOW_DROP = (CFG.ShowDropButton == true)
local RESET_TEXT = CFG.ResetButtonText or "Reset"
local DROP_TEXT = CFG.DropButtonText or "Back to base"

local VISUALS = CFG.Visuals or {}
local ENABLE_RECOLOR = (VISUALS.EnableRecolor ~= false)
local COLOR_VISITED = VISUALS.VisitedColor or Color3.fromRGB(60,200,255)
local COLOR_CURRENT = VISUALS.CurrentColor or Color3.fromRGB(60,220,120)
local FINISH_FLASH = tonumber(VISUALS.FinishFlashDuration) or 0.45

local SFX_CONFIG = CFG.SoundEffects or {Enabled = false}
local RESET_ACK_TIMEOUT = 5.0
local REBIND_COOLDOWN = 0.2
local SKIP_WARNING_COOLDOWN = 2.0

-- ROMAN NUMERALS CONVERSION
local function numberToRoman(num)
	if not num or num < 1 then return tostring(num) end

	local romanValues = {
		{1000, "M"}, {900, "CM"}, {500, "D"}, {400, "CD"},
		{100, "C"}, {90, "XC"}, {50, "L"}, {40, "XL"},
		{10, "X"}, {9, "IX"}, {5, "V"}, {4, "IV"}, {1, "I"}
	}

	local result = ""
	for _, pair in ipairs(romanValues) do
		local value, numeral = pair[1], pair[2]
		while num >= value do
			result = result .. numeral
			num = num - value
		end
	end
	return result
end

local function formatCheckpointLabel(idx)
	if idx == START then
		return "START"
	elseif idx == FINISH then
		return "SUMMIT"
	end
	return numberToRoman(idx)
end

-- SMART SKIP LOGIC
local SKIP_CHECKPOINTS = { "CP0" }

local function shouldSkipNotif(cpName)
	for _, skip in ipairs(SKIP_CHECKPOINTS) do
		if cpName == skip then return true end
	end
	return false
end

-- BLUR EFFECT
local blur = Instance.new("BlurEffect")
blur.Size = 0
blur.Parent = Lighting

-- SCREEN SHAKE
local shaking = false

local function Shake(intensity, duration)
	if shaking then return end
	shaking = true

	local start = tick()
	local con

	con = RunService.RenderStepped:Connect(function()
		if tick() - start > duration then
			con:Disconnect()
			shaking = false
			return
		end

		local offset = Vector3.new(
			(math.random() - 0.5) * intensity,
			(math.random() - 0.5) * intensity,
			0
		)

		cam.CFrame = cam.CFrame * CFrame.new(offset)
	end)
end

local function ShakeAndBlur()
	local duration = 0.40

	Shake(0.7, duration)

	TweenService:Create(
		blur,
		TweenInfo.new(duration * 0.4, Enum.EasingStyle.Quint),
		{ Size = 18 }
	):Play()

	task.wait(duration * 0.4)

	TweenService:Create(
		blur,
		TweenInfo.new(duration * 0.6, Enum.EasingStyle.Quint),
		{ Size = 0 }
	):Play()
end

-- CP FULLSCREEN NOTIFICATION
local cpNotifGui = Instance.new("ScreenGui")
cpNotifGui.IgnoreGuiInset = true
cpNotifGui.Name = "CPNotificationEffect"
cpNotifGui.ResetOnSpawn = false
cpNotifGui.Parent = playerGui

local cpNotifLabel = Instance.new("TextLabel")
cpNotifLabel.Size = UDim2.new(1, 0, 1, 0)
cpNotifLabel.Position = UDim2.new(0, 0, 0, 0)
cpNotifLabel.BackgroundTransparency = 1
cpNotifLabel.Text = ""
cpNotifLabel.TextSize = 42
cpNotifLabel.TextColor3 = Color3.new(1, 1, 1)
cpNotifLabel.Font = Enum.Font.GothamBlack
cpNotifLabel.TextTransparency = 1
cpNotifLabel.TextXAlignment = Enum.TextXAlignment.Center
cpNotifLabel.TextYAlignment = Enum.TextYAlignment.Center
cpNotifLabel.ZIndex = 20
cpNotifLabel.Parent = cpNotifGui

local cpStroke = Instance.new("UIStroke")
cpStroke.Thickness = 3
cpStroke.Color = Color3.new(0, 0, 0)
cpStroke.Transparency = 0.1
cpStroke.Parent = cpNotifLabel

-- Flag untuk track notifikasi checkpoint
local showingCheckpointNotif = false

local function ShowCPNotif(cpNumber)
	-- Skip notification for START (CP0)
	if cpNumber == START then return end

	-- Check if should skip notification
	if shouldSkipNotif("CP" .. cpNumber) then return end

	-- Gunakan task.spawn agar tidak blocking
	task.spawn(function()
		showingCheckpointNotif = true

		local label = formatCheckpointLabel(cpNumber)
		local text = "CHECKPOINT " .. label .. " REACHED"

		cpNotifLabel.Text = text
		cpNotifLabel.Visible = true

		-- Pastikan teks mulai dari transparan
		cpNotifLabel.TextTransparency = 1
		cpStroke.Transparency = 1

		TweenService:Create(
			cpNotifLabel,
			TweenInfo.new(0.2, Enum.EasingStyle.Quint),
			{ TextTransparency = 0 }
		):Play()

		TweenService:Create(
			cpStroke,
			TweenInfo.new(0.2, Enum.EasingStyle.Quint),
			{ Transparency = 0.1 }
		):Play()

		task.wait(0.4)

		TweenService:Create(
			cpNotifLabel,
			TweenInfo.new(0.4, Enum.EasingStyle.Quint),
			{ TextTransparency = 1 }
		):Play()

		TweenService:Create(
			cpStroke,
			TweenInfo.new(0.4, Enum.EasingStyle.Quint),
			{ Transparency = 1 }
		):Play()

		task.wait(0.4)
		cpNotifLabel.Text = ""
		cpNotifLabel.Visible = false
		showingCheckpointNotif = false
	end)
end

-- BASIC STATE MANAGEMENT
local visited = {}
local originalColors = {}
local currentIdx = player:GetAttribute("CPIndex") or START
local flashFinishUntil = 0
local connections = {}

local gui, resetButton, notifFrame, notifLabel, cpPanel, cpIndicator
local resetting = false
local rebindDebounce = false
local lastRebind = 0
local attributeDebounce = false
local lastSkipWarning = 0

local sfxA, sfxB
local lastPlay = 0
local cooldown = SFX_CONFIG.Cooldown or 0.5
local lastPlayedCP = nil

_G.ConfirmationCallbacks = _G.ConfirmationCallbacks or {}

local cpFolder = workspace:WaitForChild(FOLDER, 10)
if not cpFolder then
	warn("[CheckpointClient] Checkpoint folder not found")
	_G.__SUMMIT_UI_BOUND_V8 = nil
	script:Destroy()
	return
end

if SFX_CONFIG.Enabled then
	sfxA = Instance.new("Sound")
	sfxA.SoundId = SFX_CONFIG.CheckpointSoundId
	sfxA.Volume = SFX_CONFIG.Volume
	sfxA.Name = "CheckpointA"
	sfxA.Parent = SoundService

	sfxB = Instance.new("Sound")
	sfxB.SoundId = SFX_CONFIG.FinishSoundId
	sfxB.Volume = SFX_CONFIG.Volume
	sfxB.Name = "CheckpointB"
	sfxB.Parent = SoundService

	pcall(function() ContentProvider:PreloadAsync({sfxA, sfxB}) end)
end

local function addConnection(name, connection)
	if connections[name] then
		connections[name]:Disconnect()
	end
	connections[name] = connection
end

local function cleanupConnection(name)
	if connections[name] then
		connections[name]:Disconnect()
		connections[name] = nil
	end
end

local function cleanup()
	for name, conn in pairs(connections) do
		if conn then conn:Disconnect() end
	end
	table.clear(connections)
	if sfxA then sfxA:Destroy() end
	if sfxB then sfxB:Destroy() end
	_G.__SUMMIT_UI_BOUND_V8 = nil
	_G.ConfirmationCallbacks.drop = nil
end

local function playSfxOnce(useB, cpIndex)
	if not SFX_CONFIG.Enabled then return end
	local now = tick()
	if now - lastPlay < cooldown then return end
	if lastPlayedCP == cpIndex and now - lastPlay < 1.0 then return end
	lastPlay = now
	lastPlayedCP = cpIndex
	if useB and sfxB then
		sfxB.TimePosition = 0
		sfxB:Play()
	elseif not useB and sfxA then
		sfxA.TimePosition = 0
		sfxA:Play()
	end
end

local function indexFromName(name)
	local n = string.match(name, "^" .. PREFIX .. "(%d+)$")
	return n and tonumber(n) or nil
end

local function getPartByIndex(index)
	return cpFolder:FindFirstChild(PREFIX .. tostring(index))
end

local function cacheOriginalColor(index)
	if originalColors[index] ~= nil then return end
	local part = getPartByIndex(index)
	if part and part:IsA("BasePart") then
		originalColors[index] = part.Color
	end
end

local function paintPart(index, color)
	if not ENABLE_RECOLOR then return end
	local part = getPartByIndex(index)
	if not (part and part:IsA("BasePart")) then return end
	cacheOriginalColor(index)
	if color == nil then
		local orig = originalColors[index]
		if orig then part.Color = orig end
	else
		part.Color = color
	end
end

local function restoreAllColors()
	if not ENABLE_RECOLOR then return end
	for _, inst in ipairs(cpFolder:GetChildren()) do
		if inst:IsA("BasePart") then
			local idx = indexFromName(inst.Name)
			if idx then
				cacheOriginalColor(idx)
				local orig = originalColors[idx]
				if orig then inst.Color = orig end
			end
		end
	end
end

local function applyAllColors()
	if not ENABLE_RECOLOR then return end
	local now = tick()

	for _, inst in ipairs(cpFolder:GetChildren()) do
		if inst:IsA("BasePart") then
			local idx = indexFromName(inst.Name)
			if idx then cacheOriginalColor(idx) end
		end
	end

	for _, inst in ipairs(cpFolder:GetChildren()) do
		if inst:IsA("BasePart") then
			local idx = indexFromName(inst.Name)
			if idx then
				if idx == FINISH and now < flashFinishUntil then
					paintPart(idx, COLOR_CURRENT)
				elseif idx == currentIdx then
					paintPart(idx, COLOR_CURRENT)
				elseif visited[idx] then
					paintPart(idx, COLOR_VISITED)
				else
					paintPart(idx, nil)
				end
			end
		end
	end
end

local function showNote(msg, seconds)
	-- Jangan overwrite notifikasi checkpoint yang masih berlangsung
	if showingCheckpointNotif then return end

	if not notifFrame or not notifLabel then return end
	notifLabel.Text = msg
	notifFrame.Visible = true
	local myMsg = msg
	task.delay(seconds or 2, function()
		if notifLabel and notifLabel.Text == myMsg then
			notifFrame.Visible = false
			if notifLabel.Text == myMsg then
				notifLabel.Text = ""
			end
		end
	end)
end

local function getSummitValue()
	local ls = player:FindFirstChild("leaderstats")
	local s = ls and ls:FindFirstChild("Summit")
	return (s and s.Value) or 0
end

local function computeButtonState()
	if not SHOW_RESET and not SHOW_DROP then
		return false, ""
	end

	local isSpeedRunActive = player:GetAttribute("SpeedRunActive") == true
	if isSpeedRunActive then
		return false, DROP_TEXT
	end

	local cp = player:GetAttribute("CPIndex") or START
	local lapComplete = (player:GetAttribute("LapComplete") == true)

	if lapComplete then
		return SHOW_DROP, DROP_TEXT
	end

	if cp == START then
		return false, DROP_TEXT  
	end

	if cp == FINISH then
		return SHOW_DROP, DROP_TEXT
	end

	if cp > START and cp < FINISH then
		return SHOW_RESET, RESET_TEXT
	end

	return SHOW_DROP, DROP_TEXT
end

local function refreshResetButton()
	if not resetButton then return end

	local show, text = computeButtonState()

	if not SHOW_RESET and not SHOW_DROP then
		show = false
	end

	resetButton.Visible = show

	if resetting then
		resetButton.Active = false
		resetButton.AutoButtonColor = false
		resetButton.Text = (text == DROP_TEXT) and "Menurunkan..." or "Resetting..."
	else
		resetButton.Active = true
		resetButton.AutoButtonColor = true
		resetButton.Text = text
	end
end

local function updateIndicatorText()
	rebindUI()
	pcall(function()
		if cpIndicator then
			cpIndicator.Text = string.format("Checkpoint %d | Summit %d", tonumber(currentIdx) or 0, getSummitValue())
		end
	end)
end

local function updateConfirmationText(context)
	local confirmGUI = playerGui:FindFirstChild("ConfirmationGUI")
	if not confirmGUI then return end

	local confirmFrame = confirmGUI:FindFirstChild("ConfirmationFrame")
	if not confirmFrame then return end

	local confirmText = confirmFrame:FindFirstChild("ConfirmText") 
		or confirmFrame:FindFirstChild("TextLabel")
		or confirmFrame:FindFirstChild("MessageLabel")

	if not confirmText then
		for _, child in ipairs(confirmFrame:GetDescendants()) do
			if child:IsA("TextLabel") and child.Name ~= "Title" then
				confirmText = child
				break
			end
		end
	end

	if confirmText then
		if context == "drop" then
			confirmText.Text = "Apakah kamu ingin Kembali ke CP0?"
		elseif context == "speedrun" then
			confirmText.Text = "Kamu akan kembali ke Basecamp jika ingin SpeedRun"
		end
	end

	confirmFrame:SetAttribute("Context", context)
end

local function rebuildVisitedDefault()
	table.clear(visited)
	for i = START, currentIdx do
		visited[i] = true
		cacheOriginalColor(i)
	end
end

local function forceUIUpdate()
	rebuildVisitedDefault()
	updateIndicatorText()
	applyAllColors()
	refreshResetButton()
end

function rebindUI()
	local now = tick()
	if rebindDebounce or (now - lastRebind) < REBIND_COOLDOWN then
		return
	end
	rebindDebounce = true
	lastRebind = now

	task.defer(function()
		local pg = player:FindFirstChild("PlayerGui")
		if not pg then
			rebindDebounce = false
			return
		end

		local newGui = pg:FindFirstChild("SummitGUI")
		if newGui ~= gui then gui = newGui end
		if not gui then
			rebindDebounce = false
			return
		end

		cpPanel = gui:FindFirstChild("Checkpoint")
		cpIndicator = cpPanel and cpPanel:FindFirstChild("CPIndicator") or nil
		notifFrame = gui:FindFirstChild("NotificationFrame")
		notifLabel = notifFrame and notifFrame:FindFirstChild("TextLabel") or nil

		if not SHOW_RESET and not SHOW_DROP then
			local btn = gui:FindFirstChild("DownButton")
			if btn then
				btn.Visible = false
			end
			resetButton = nil
			cleanupConnection("resetButton")
			rebindDebounce = false
			return
		end

		if SHOW_RESET or SHOW_DROP then
			local btn = gui:FindFirstChild("DownButton")
			if btn and btn ~= resetButton then
				cleanupConnection("resetButton")
				resetButton = btn
				resetButton.Active = true
				resetButton.AutoButtonColor = true

				local function requestResetOrDrop()
					if resetting then return end

					updateConfirmationText("drop")

					local confirmGUI = playerGui:FindFirstChild("ConfirmationGUI")
					if not confirmGUI then 
						warn("[CheckpointClient] ConfirmationGUI not found!")
						return 
					end

					local confirmFrame = confirmGUI:FindFirstChild("ConfirmationFrame")
					if confirmFrame then
						confirmFrame.Visible = true
					else
						warn("[CheckpointClient] ConfirmationFrame not found!")
						return
					end

					_G.ConfirmationCallbacks.drop = function()
						if resetting then return end
						resetting = true

						local _, text = computeButtonState()
						local isDrop = (text == DROP_TEXT)

						refreshResetButton()
						showNote(isDrop and "Menurunkan ke start..." or "Reset ke start...", 1.2)

						cleanupConnection("resetAck")
						addConnection("resetAck", resetAckRE.OnClientEvent:Connect(function(ok, msg)
							cleanupConnection("resetAck")
							resetting = false
							if ok then
								showNote(isDrop and "Berhasil Back to base!" or "Reset berhasil!", 1.5)
							else
								showNote(msg or (isDrop and "Back to base gagal." or "Reset gagal."), 2.5)
							end
							task.delay(0.1, refreshResetButton)
						end))

						resetEvent:FireServer()

						task.delay(RESET_ACK_TIMEOUT, function()
							if not resetting then return end
							resetting = false
							cleanupConnection("resetAck")
							showNote("Koneksi lambat. Coba lagi.", 2.5)
							task.delay(0.1, refreshResetButton)
						end)
					end
				end

				addConnection("resetButton", resetButton.MouseButton1Click:Connect(requestResetOrDrop))
				refreshResetButton()
			end
		else
			resetButton = nil
			cleanupConnection("resetButton")
		end

		rebindDebounce = false
	end)
end

addConnection("markVisited", markVisitedRE.OnClientEvent:Connect(function(cpIndex, currentFromServer, fromTouch)
	if typeof(cpIndex) == "number" then
		visited[cpIndex] = true
		if fromTouch == true then
			if cpIndex == START then
				-- Tidak ada notif & suara untuk CP0
			elseif cpIndex == FINISH then
				playSfxOnce(true, cpIndex)
				flashFinishUntil = tick() + FINISH_FLASH
				ShakeAndBlur()
				ShowCPNotif(cpIndex)
				showNote("Selamat Telah Mencapai Summit!", 3.0)
			else
				if not shouldSkipNotif("CP" .. cpIndex) then
					playSfxOnce(false, cpIndex)
					ShakeAndBlur()
					ShowCPNotif(cpIndex)
				end
			end
		end
	end

	if typeof(currentFromServer) == "number" then
		currentIdx = currentFromServer
	else
		if typeof(cpIndex) == "number" then
			if not currentIdx or cpIndex > currentIdx then
				currentIdx = cpIndex
			end
		end
	end

	task.delay(0.05, function()
		updateIndicatorText()
		applyAllColors()
		refreshResetButton()
	end)
end))

addConnection("resetVisited", resetVisitedRE.OnClientEvent:Connect(function()
	table.clear(visited)
	restoreAllColors()
	applyAllColors()
end))

if customMsgRE then
	addConnection("customMessage", customMsgRE.OnClientEvent:Connect(function(message)
		if message and message ~= "" then
			showNote(message, 3.0)
		end
	end))
end

if SKIP == false and skipDeniedRE then
	addConnection("skipDenied", skipDeniedRE.OnClientEvent:Connect(function(expectedNext)
		local now = tick()
		if now - lastSkipWarning < SKIP_WARNING_COOLDOWN then
			return
		end
		lastSkipWarning = now

		rebindUI()
		showNote(("Kamu harus menekan %s%d terlebih dahulu"):format(PREFIX, expectedNext), 2.0)
	end))
end

addConnection("syncState", syncStateRE.OnClientEvent:Connect(function(currentIndex, visitedArr)
	if typeof(currentIndex) == "number" then
		currentIdx = currentIndex
	end
	table.clear(visited)
	if typeof(visitedArr) == "table" then
		for _, idx in ipairs(visitedArr) do
			visited[idx] = true
			cacheOriginalColor(idx)
		end
	end
	task.wait(0.05)
	updateIndicatorText()
	applyAllColors()
	refreshResetButton()
end))

addConnection("cpIndexChanged", player:GetAttributeChangedSignal("CPIndex"):Connect(function()
	if attributeDebounce then return end
	attributeDebounce = true

	local attr = player:GetAttribute("CPIndex")
	if typeof(attr) == "number" then
		currentIdx = attr
		task.delay(0.05, forceUIUpdate)
	end

	task.delay(0.1, function()
		attributeDebounce = false
	end)
end))

addConnection("lapCompleteChanged", player:GetAttributeChangedSignal("LapComplete"):Connect(function()
	task.delay(0.05, function()
		refreshResetButton()
		if resetting and player:GetAttribute("LapComplete") == false then
			resetting = false
			cleanupConnection("resetAck")
		end
	end)
end))

addConnection("speedRunActiveChanged", player:GetAttributeChangedSignal("SpeedRunActive"):Connect(function()
	task.delay(0.05, refreshResetButton)
end))

addConnection("wantsNewLapChanged", player:GetAttributeChangedSignal("WantsNewLap"):Connect(function()
	task.delay(0.1, refreshResetButton)
end))

player:WaitForChild("leaderstats", 5)
local ls = player:FindFirstChild("leaderstats")
if ls then
	local s = ls:FindFirstChild("Summit")
	if s then
		addConnection("summitChanged", s:GetPropertyChangedSignal("Value"):Connect(function()
			task.delay(0.05, updateIndicatorText)
		end))
	end
	addConnection("leaderstatsChildAdded", ls.ChildAdded:Connect(function(child)
		if child.Name == "Summit" and child:IsA("IntValue") then
			addConnection("summitChanged", child:GetPropertyChangedSignal("Value"):Connect(function()
				task.delay(0.05, updateIndicatorText)
			end))
			task.delay(0.05, updateIndicatorText)
		end
	end))
end

task.spawn(function()
	while task.wait(5) do
		if not gui or not gui.Parent then
			task.wait(0.2)
			rebindUI()
		end

		if not resetButton and (SHOW_RESET or SHOW_DROP) then
			task.wait(0.2)
			rebindUI()
		end

		if resetButton and not SHOW_RESET and not SHOW_DROP then
			resetButton.Visible = false
		end
	end
end)

script.AncestryChanged:Connect(function()
	if not script.Parent then
		cleanup()
	end
end)

rebindUI()
task.wait(0.2)
forceUIUpdate()

