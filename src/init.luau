--!strict
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Packages = script.Parent

local GoodSignal = require(Packages.goodsignal)
local Trove = require(Packages.trove)
local Networker = require(Packages.networker)

if RunService:IsServer() then 
    Networker.new("AnimationEvent", "RemoteEvent", "Reliable")
end

local AnimationManager = {}
AnimationManager.__index = AnimationManager

local DEBUG = true

type SetChangedSignal = GoodSignal.Signal<string?> & {
	DisconnectAll: (self: SetChangedSignal) -> (),
}

export type AnimationListTemplate = {
	["Individual"]: {
		[string]: Animation,
	},
	["Core"]: {
		[string]: Animation,
	},
	[string]: {
		[string]: Animation,
	},
}

export type AnimationManagerData = {
	_player: Player?,
	_char: Model,
	_humanoid: Humanoid,
	_animator: Animator | AnimationController,
	_animationList: AnimationListTemplate,
    _animationFolder: Folder,

	_coreTracks: { [string]: AnimationTrack },
	_tracks: { [string]: AnimationTrack },
	_individualTracks: { [string]: AnimationTrack },
	_currentSet: string?,

	_aliveTrove: Trove.Trove,
	_setChanged: SetChangedSignal,
	_destroyed: boolean,
}

export type AnimationManager = typeof(setmetatable({} :: AnimationManagerData, AnimationManager))

--// Constructor
function AnimationManager.new(
	char: Model,
	AnimationList: AnimationListTemplate,
	AnimationFolder: Folder
): AnimationManager
	assert(char and char:IsA("Model"), "[AnimationManager]: char must be a Model")
	assert(char and char:FindFirstChildWhichIsA("Humanoid"), "[AnimationManager]: char must have a Humanoid")
	assert(
		char
			and (
				char:FindFirstChildWhichIsA("Animator", true) or char:FindFirstChildWhichIsA(
					"AnimationController",
					true
				)
			),
		"[AnimationManager]: char must have an Animator or AnimationController"
	)
	assert(AnimationList and type(AnimationList) == "table", "[AnimationManager]: AnimationList must be a table")
	assert(AnimationFolder and AnimationFolder:IsA("Folder"), "[AnimationManager]: AnimationFolder must be a Folder")
	local self = setmetatable({} :: AnimationManagerData, AnimationManager) :: AnimationManager

	-->> Player and Character References
	self._player = Players:GetPlayerFromCharacter(char)
	self._char = char
	self._humanoid = char:FindFirstChildWhichIsA("Humanoid")
	self._animator = char:FindFirstChildWhichIsA("Animator", true)
		or char:FindFirstChildWhichIsA("AnimationController", true)
	self._animationList = AnimationList
	self._animationFolder = AnimationFolder

	-->> Tracks
	self._coreTracks = {}
	self._tracks = {}
	self._individualTracks = {}

	-->> Sets
	self._currentSet = nil
	self._setChanged = GoodSignal.new() :: SetChangedSignal

	-->> Cleanup
	self._destroyed = false
	self._aliveTrove = Trove.new()
	local setChanged = self._setChanged
	self._aliveTrove:Add(function()
		setChanged:DisconnectAll()
	end)
	self._aliveTrove:AttachToInstance(char)
	self._aliveTrove:Add(self._humanoid.Died:Connect(function()
		self:Destroy()
	end))
	if self._player then
		self._aliveTrove:Add(Players.PlayerRemoving:Connect(function(player: Player)
			if player == self._player then
				self:Destroy()
			end
		end))
	end
	self._aliveTrove:Add(function()
		self:Destroy()
	end)

	-->> Initialization
	self:Preload()
	if not self._destroyed then
		self:LoadCore()
	end

	return self
end

--// Connections 
function AnimationManager.BindRemote(self: AnimationManager)
	if RunService:IsClient() and self._player then
		self._aliveTrove:Add(Networker.new("AnimationEvent"):OnClientEvent(function(data)
			local animName = data.animName
			if data.start then
				if not self:IsIndividualLoaded(animName) and self._animationList["Individual"][animName] then
					self:LoadIndividualTrack(animName)
				end

				self:StopAll()
				self:PlayAnimation(animName)
			else
				self:StopAnimation(animName)
			end
		end))
	end
end

function AnimationManager.OnSetChanged(self: AnimationManager, callback: (string?) -> ()): GoodSignal.Connection
	return self._aliveTrove:Add(self._setChanged:Connect(callback), "Disconnect")
end

function AnimationManager.OnTrackStopped(
	self: AnimationManager,
	name: string,
	callback: () -> ()
): RBXScriptConnection?
	local track: AnimationTrack = self._individualTracks[name] or self._tracks[name] or self._coreTracks[name]
	if not track then
		return nil
	end

	return self._aliveTrove:Add(track.Stopped:Connect(callback))
end

function AnimationManager.MarkerReached(
	self: AnimationManager,
	animName: string,
	markerName: string,
	callback: (any) -> ()
): RBXScriptConnection?
	local track: AnimationTrack = self._individualTracks[animName]
		or self._tracks[animName]
		or self._coreTracks[animName]
	if not track then
		return nil
	end

	return self._aliveTrove:Add(track:GetMarkerReachedSignal(markerName):Connect(callback))
end

--// Loading Animations
function AnimationManager:Preload()
	assert(
		self._animationFolder and self._animationFolder:IsA("Folder"),
		"[AnimationManager]: AnimationFolder must be a Folder"
	)
	local animsToPreload = {}

	for _, v in pairs(self._animationFolder:GetDescendants()) do
		if v:IsA("Animation") then
			table.insert(animsToPreload, v)
		end
	end
	if DEBUG then
		print("[AnimationManager]: Preloading animations...")
	end
	ContentProvider:PreloadAsync(animsToPreload)
	if DEBUG then
		print(`[AnimationManager]: Preloaded {#animsToPreload} animations.`)
	end
end

function AnimationManager.LoadCore(self: AnimationManager)
	assert(self._animationList["Core"], "[AnimationManager]: Core animations not found in AnimationList")
	self:UnloadCoreTracks()

	for i, v in pairs(self._animationList["Core"]) do
		local t = self._animator:LoadAnimation(v)
		self._coreTracks[i] = t
	end

	if DEBUG then
		print("[AnimationManager]: Core animations loaded")
	end
end

function AnimationManager.LoadIndividualTrack(self: AnimationManager, name: string)
	assert(
		self._animationList["Individual"][name],
		"[AnimationManager]: Individual animation not found in AnimationList"
	)
	if self._individualTracks[name] then
		return self._individualTracks[name]
	end

	local t = self._animator:LoadAnimation(self._animationList["Individual"][name])
	self._individualTracks[name] = t

	if DEBUG then
		print("[AnimationManager]: Individual animation " .. name .. " loaded")
	end

	return t
end

function AnimationManager.LoadSet(self: AnimationManager, setName: string)
	assert(self._animationList[setName], "[AnimationManager]: Set not found in AnimationList")

	local previousSet = self._currentSet
	for _, v in pairs(self._tracks) do
		v:Stop(0)
		v:Destroy()
	end
	table.clear(self._tracks)

	self._currentSet = setName
	for i, v in pairs(self._animationList[setName]) do
		local t = self._animator:LoadAnimation(v)
		self._tracks[i] = t
	end
	if previousSet ~= setName then
		self._setChanged:Fire(setName)
	end

	if DEBUG then
		print("[AnimationManager]: Set " .. setName .. " loaded")
	end
end

--// Unloading Animations
function AnimationManager.UnloadCoreTracks(self: AnimationManager)
	for _, v in pairs(self._coreTracks) do
		v:Stop(0)
		v:Destroy()
	end
	table.clear(self._coreTracks)
end

function AnimationManager.UnloadSet(self: AnimationManager)
	for _, v in pairs(self._tracks) do
		v:Stop(0)
		v:Destroy()
	end
	table.clear(self._tracks)

	local previousSet = self._currentSet
	self._currentSet = nil
	if previousSet ~= nil and not self._destroyed then
		self._setChanged:Fire(nil)
	end
end

function AnimationManager.UnloadIndividualTrack(self: AnimationManager, name: string)
	local track: AnimationTrack = self._individualTracks[name]
	if not track then
		return
	end

	self._individualTracks[name] = nil
	track:Stop(0)
	track:Destroy()
end

function AnimationManager.UnloadIndividualTracks(self: AnimationManager)
	for _, v in pairs(self._individualTracks) do
		v:Stop(0)
		v:Destroy()
	end
	table.clear(self._individualTracks)
end

--// Playing Animations
function AnimationManager.PlayAnimation(self: AnimationManager, name: string, fadeTime: number?)
	local track: AnimationTrack = self._individualTracks[name] or self._tracks[name] or self._coreTracks[name]
	if not track then
		warn("[AnimationManager]: Animation " .. name .. " not loaded")
		return
	end

	track:Play(fadeTime)
end

--// Stopping Animations
function AnimationManager.StopAnimation(self: AnimationManager, name: string, fadeTime: number?)
	local track: AnimationTrack = self._individualTracks[name] or self._tracks[name] or self._coreTracks[name]
	if not track then
		warn("[AnimationManager]: Animation " .. name .. " not loaded")
		return
	end

	track:Stop(fadeTime)
end

function AnimationManager.StopAll(self: AnimationManager, fadeTime: number?)
	for _, v in pairs(self._coreTracks) do
		v:Stop(fadeTime)
	end

	for _, v in pairs(self._tracks) do
		v:Stop(fadeTime)
	end

	for _, v in pairs(self._individualTracks) do
		v:Stop(fadeTime)
	end
end

--// Adjusting Animations
function AnimationManager.AdjustSpeed(self: AnimationManager, name: string, speed: number)
	local track: AnimationTrack = self._individualTracks[name] or self._tracks[name] or self._coreTracks[name]
	if not track then
		warn("[AnimationManager]: Animation " .. name .. " not loaded")
		return
	end

	track:AdjustSpeed(speed)
end

--// Information Getters
function AnimationManager.GetCurrentSet(self: AnimationManager): string?
    return self._currentSet
end

function AnimationManager.IsIndividualLoaded(self: AnimationManager, animation: string): boolean
    return self._individualTracks[animation] ~= nil
end

function AnimationManager.IsSet(self: AnimationManager, setName: string): boolean
	return self._currentSet == setName
end

function AnimationManager.GetLoadedTracks(
	self: AnimationManager
): ({ AnimationTrack }, { [string]: AnimationTrack }, { [string]: AnimationTrack }, { [string]: AnimationTrack })
	local tracks: { AnimationTrack } = {}
	for _, v in pairs(self._coreTracks) do
		table.insert(tracks, v)
	end
	for _, v in pairs(self._tracks) do
		table.insert(tracks, v)
	end
	for _, v in pairs(self._individualTracks) do
		table.insert(tracks, v)
	end
	return tracks, self._coreTracks, self._tracks, self._individualTracks
end

function AnimationManager.GetLength(self: AnimationManager, name: string): number?
	local track: AnimationTrack = self._individualTracks[name] or self._tracks[name] or self._coreTracks[name]
	if not track then
		return nil
	end
	return track.Length
end

--// Cleanup
function AnimationManager.Destroy(self: AnimationManager)
	if self._destroyed then
		return
	end
	self._destroyed = true

	self._aliveTrove:Destroy()
	self:UnloadCoreTracks()
	self:UnloadSet()
	self:UnloadIndividualTracks()

	table.clear(self)
	self._destroyed = true
end

return AnimationManager
