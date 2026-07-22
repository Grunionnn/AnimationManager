--[[ 
	Author: Grunion
	Referrals: @Grunionnn (rblx), @_grunion_ (Discord)
	Creation Date: 5/22/2026
	Script Description:
	Upgraded version of the original animation manager, now instead of just being confined purely to sets it allows for you to 
	hot-load animations on the go, this patch was made as a way to run the abilities system without forcing you to have all the 
	ability animations loaded, it also allows you to quickly unload the specific anim at any point necessary, I've also added
	a few more varations in the API and also removed the one shot and continuous option, I'd much rather handle the connection
	in the script its called in rather than internally as it can get messy at times and cause certain race conditions. Follows 
	the same API as the original anim manager just think of it as the old anim manager but with more features to allow more 
	customization, I've also exported out the Animation List as a child of the module to reduce the overall lines of this one
	it's to help boost readability as I noticed as more animations were added the list just took up too much space.
	API:
		============ CONSTRUCTOR ============
		AnimationManager.new(character)          -- Returns a new Manager bound to the given character.

		============ LOADING ============
		:LoadCore()                              -- Loads all animations under the "Core" set. Called automatically on construction.
		:LoadAnimations(setName)                 -- Loads a named animation set, unloading the previous one. Fires SetChanged.
		:LoadIndividualAnimation(name)           -- Loads a single animation from AnimationList.IndividualTracks.
		:Preload()                               -- Preloads all animations in ReplicatedStorage.Animations via ContentProvider.

		============ PLAYBACK ============
		:Play(name, fadeTime?)                   -- Plays a track by name. Checks IndividualTracks, Tracks, then CoreTracks.
		:Stop(name, fadeTime?)                   -- Stops a track by name across all three tables.
		:StopAll(fadeTime?)                      -- Stops all currently loaded tracks.
		:AdjustSpeed(name, speed)                -- Adjusts playback speed of a named track.
		:IsPlaying(name)                         -- Returns whether a named track is currently playing.
		:GetLength(name)                         -- Returns the length of a named track in seconds.

		============ UNLOADING ============
		:UnloadAll()                             -- Stops and destroys all Tracks and IndividualTracks.
		:UnloadNormalTracks()                    -- Stops and destroys all Tracks.
		:UnloadIndividualTracks()                -- Stops and destroys all IndividualTracks.
		:UnloadAnimation(name)                   -- Stops and destroys a single track by name.

		============ QUERIES ============
		:GetCurrentSet()                         -- Returns the name of the currently loaded set.
		:IsSet(setName)                          -- Returns whether setName matches the currently loaded set.
		:GetCurrentPlayingAnimations()           -- Returns a table of all playing tracks keyed by name, each with ID and Track.

		============ SIGNALS ============
		:OnSetChanged(callback)                  -- Fires when LoadAnimations is called. Returns connection.
		:OnTrackStopped(name, callback)          -- Fires when a named track stops. Returns connection.
		:MarkerReached(animName, markerName, callback) -- Fires when an animation marker is hit. Returns connection.

		============ LIFECYCLE ============
		:Destroy()  -- Full cleanup. Stops all tracks, destroys them, cleans trove, disconnects signals, clears the object.

]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")

local Animations = ReplicatedStorage:WaitForChild("Animations")
local Packages = script.Parent

local Networker = require(Packages.Networker)
local Trove = require(Packages.Trove)
local GoodSignal = require(Packages.GoodSignal)
local AnimationList = require(script.AnimationList)

local AnimationManager = {}
AnimationManager.__index = AnimationManager

-->> Types
type ManagerData = {
	-->> Player / Character
	_Player: Player?,
	_Character: Model,
	_Animator: Animator,

	-->> Signal / Trove
	_SetChanged: typeof(GoodSignal.new()),
	_AliveTrove: typeof(Trove.new()),

	-->> Sets / Tracks
	_CurrentSet: string?,
	_CoreTracks: { [string]: AnimationTrack },
	_Tracks: { [string]: AnimationTrack },
	_IndividualTracks: { [string]: AnimationTrack },
}

type ManagerType = typeof(setmetatable({} :: ManagerData, AnimationManager))

export type Manager = ManagerType

local localPlayerManager: Manager? = nil

function AnimationManager.new(char: Model): Manager
	local self = setmetatable({} :: ManagerData, AnimationManager)
	-->> Player/Character
	self._Player = Players:GetPlayerFromCharacter(char)
	self._Character = char
	self._Animator = char:WaitForChild("Humanoid"):WaitForChild("Animator") :: Animator

	-->> Signal
	self._SetChanged = GoodSignal.new()
	self._AliveTrove = Trove.new()
	-->> Sets
	self._CurrentSet = nil
	self._CoreTracks = {}
	self._Tracks = {}
	self._IndividualTracks = {}

	-->> Player Bindings
	if self._Player then
		if self._Player == Players.LocalPlayer then
			localPlayerManager = self
		end
		self:Preload()
		self:BindRemote()
		self._AliveTrove:Add(Players.PlayerRemoving:Connect(function(plr: Player)
			if plr == self._Player then
				self:Destroy()
			end
		end))
	end
	self:LoadCore()

	self._AliveTrove:Add(function()
		if localPlayerManager == self then
			localPlayerManager = nil
		end
		self:Destroy()
	end)

	self._AliveTrove:AttachToInstance(self._Character)

	return self :: ManagerType
end

function AnimationManager.GetLocalPlayerManager(): ManagerType?
	return localPlayerManager
end

function AnimationManager:Preload()
	local animsToPreload = {}
	local function gatherAnimations(folder)
		for _, child in ipairs(folder:GetDescendants()) do
			if child:IsA("Animation") then
				table.insert(animsToPreload, child)
			elseif child:IsA("Folder") then
				gatherAnimations(child)
			end
		end
	end
	gatherAnimations(Animations)
	ContentProvider:PreloadAsync(animsToPreload)
	print(`[AnimationManager]: Preloaded {#animsToPreload} animations.`)
end

function AnimationManager:BindRemote()
	self._AliveTrove:Add(Networker.new("AnimationEvent"):OnClientEvent(function(data)
		local animName = data.animName
		if data.start then
			if not self:IsIndividualLoaded(animName) and AnimationList.IndividualTracks[animName] then
				self:LoadIndividualAnimation(animName)
			end

			self:StopAll()
			self:Play(animName)
		else
			self:Stop(animName)
		end
	end))
end

function AnimationManager:LoadCore()
	self._CoreTracks = {}
	for i, v in pairs(AnimationList.CoreTracks) do
		self._CoreTracks[i] = self._Animator:LoadAnimation(v)
	end
end

--// Playback
function AnimationManager:Play(Track: string, FadeTime: number?): AnimationTrack?
	local track: AnimationTrack = self._IndividualTracks[Track] or self._Tracks[Track] or self._CoreTracks[Track]
	if track then
		track:Play(FadeTime)
		return track
	end
	return nil
end

function AnimationManager:Stop(Track: string, FadeTime: number?)
	local track1: AnimationTrack, track2: AnimationTrack, track3: AnimationTrack =
		self._IndividualTracks[Track], self._Tracks[Track], self._CoreTracks[Track]

	if track1 then
		track1:Stop(FadeTime)
	end
	if track2 then
		track2:Stop(FadeTime)
	end
	if track3 then
		track3:Stop(FadeTime)
	end
end

function AnimationManager:StopAll(fadeTime: number?)
	for _, track: AnimationTrack in pairs(self._CoreTracks) do
		track:Stop(fadeTime)
	end
	for _, track: AnimationTrack in pairs(self._Tracks) do
		track:Stop(fadeTime)
	end
	for _, track: AnimationTrack in pairs(self._IndividualTracks) do
		track:Stop(fadeTime)
	end
end

function AnimationManager:AdjustSpeed(Track: string, Speed: number)
	local track: AnimationTrack = self._IndividualTracks[Track] or self._Tracks[Track] or self._CoreTracks[Track]
	if track then
		track:AdjustSpeed(Speed)
	end
end

--// Track Manipulation
function AnimationManager:LoadAnimations(setName: string)
	if AnimationList[setName] then
		self:StopAll()
		self:UnloadAll()
		self._CurrentSet = setName

		for name, animation in pairs(AnimationList[setName]) do
			self._Tracks[name] = self._Animator:LoadAnimation(animation)
		end

		self._SetChanged:Fire(setName)
		return true
	elseif setName == nil then
		self._SetChanged:Fire(setName)
	end
	return false
end

function AnimationManager:IsIndividualLoaded(name: string): boolean
	return self._IndividualTracks[name] ~= nil
end

function AnimationManager:LoadIndividualAnimation(name: string)
	local animation = AnimationList.IndividualTracks[name]
	if not animation then
		return
	end
	self._IndividualTracks[name] = self._Animator:LoadAnimation(animation)
end

function AnimationManager:UnloadAll()
	for _, track: AnimationTrack in pairs(self._Tracks) do
		track:Stop()
		track:Destroy()
	end

	for _, track: AnimationTrack in pairs(self._IndividualTracks) do
		track:Stop()
		track:Destroy()
	end
end

function AnimationManager:UnloadNormalTracks()
	for _, track: AnimationTrack in pairs(self._Tracks) do
		track:Stop()
		track:Destroy()
	end
end

function AnimationManager:UnloadIndividualTracks()
	for _, track: AnimationTrack in pairs(self._IndividualTracks) do
		track:Stop()
		track:Destroy()
	end
end

function AnimationManager:UnloadAnimation(Track: string)
	local track: AnimationTrack = self._IndividualTracks[Track] or self._Tracks[Track]
	if track then
		track:Stop()
		track:Destroy()
	end
end

--// Information
function AnimationManager:GetCurrentSet(): string?
	return self._CurrentSet
end

function AnimationManager:IsSet(setName: string): boolean
	return self._CurrentSet == setName
end

function AnimationManager:GetLength(Track: string): number?
	local track: AnimationTrack = self._IndividualTracks[Track] or self._Tracks[Track] or self._CoreTracks[Track]
	if not track then
		return
	end
	return track.Length
end

function AnimationManager:IsPlaying(Track: string): boolean
	local track: AnimationTrack = self._IndividualTracks[Track] or self._Tracks[Track] or self._CoreTracks[Track]
	if not track then
		return false
	end
	return track.IsPlaying
end

function AnimationManager:GetCurrentPlayingAnimations(): { [string]: { ID: string, Track: AnimationTrack } }
	local playingAnims = {}
	for _, v: AnimationTrack in pairs(self._Animator:GetPlayingAnimationTracks()) do
		playingAnims[v.Animation.Name] = { ID = v.Animation.AnimationId, Track = v }
	end

	return playingAnims
end

--// Lifecycle
function AnimationManager:Destroy()
	if localPlayerManager == self then
		localPlayerManager = nil
	end

	self:StopAll()
	self:UnloadAll()

	for _, track: AnimationTrack in pairs(self._CoreTracks) do
		track:Destroy()
	end

	self._AliveTrove:Destroy()
	self._SetChanged:DisconnectAll()

	table.clear(self._CoreTracks)
	table.clear(self._Tracks)
	table.clear(self._IndividualTracks)
end

--// Connections
function AnimationManager:OnSetChanged(callback: (string) -> ()): RBXScriptConnection
	return self._SetChanged:Connect(callback)
end

function AnimationManager:OnTrackStopped(name: string, callback: () -> ()): RBXScriptConnection?
	local track: AnimationTrack = self._IndividualTracks[name] or self._Tracks[name] or self._CoreTracks[name]
	if not track then
		return nil
	end
	return track.Stopped:Connect(callback)
end

function AnimationManager:MarkerReached(
	animName: string,
	markerName: string,
	callback: (any) -> ()
): RBXScriptConnection?
	local track: AnimationTrack = self._IndividualTracks[animName]
		or self._Tracks[animName]
		or self._CoreTracks[animName]
	if not track then
		return nil
	end
	return track:GetMarkerReachedSignal(markerName):Connect(callback)
end

return AnimationManager
