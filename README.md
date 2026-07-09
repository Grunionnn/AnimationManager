# AnimationManager

A lightweight Roblox animation manager that supports dynamic loading, unloading, playback, preloading, animation markers, and automatic cleanup for animation sets and individual animations.

## Features

* Dynamic animation set loading
* Individual animation loading and unloading
* Animation preloading
* Simple playback API
* Marker reached callbacks
* Track stopped callbacks
* Automatic cleanup with Trove
* Local player manager support
* Runtime animation swapping

## Installation

Add the package to your `wally.toml`:

```toml
AnimationManager = "grunion/animationmanager@1.0.0"
```

Then install your dependencies:

```sh
wally install
```

## Basic Usage

```lua
local AnimationManager = require(Packages.AnimationManager)

local manager = AnimationManager.new(character)

manager:LoadAnimations("Combat")
manager:Play("Idle")
```

## Remote Animation Events

This package uses a remote named `AnimationEvent` so the server can tell a client to play or stop specific animations.

This is mainly useful for PvP/server-authoritative combat. For example, if the server detects that a player was stunned, it can tell that player’s client to play the stun animation without requiring animation managers to also exist on the server.

This keeps animation tracks client-sided and avoids forcing the server to load animations it does not need.

The animation event NEEDS to be made before this can function, all you need to do is either use networker on the server to make it quickly or just manually make the remote in studio itself.

## API

### Constructor

```lua
AnimationManager.new(character)
```

Creates a new animation manager for a character.

### Loading

```lua
manager:LoadCore()
manager:LoadAnimations(setName)
manager:LoadIndividualAnimation(name)
manager:Preload()
```

### Playback

```lua
manager:Play(name, fadeTime?)
manager:Stop(name, fadeTime?)
manager:StopAll(fadeTime?)
manager:AdjustSpeed(name, speed)
manager:IsPlaying(name)
manager:GetLength(name)
```

### Unloading

```lua
manager:UnloadAll()
manager:UnloadNormalTracks()
manager:UnloadIndividualTracks()
manager:UnloadAnimation(name)
```

### Information

```lua
manager:GetCurrentSet()
manager:IsSet(setName)
manager:GetCurrentPlayingAnimations()
```

### Events

```lua
manager:OnSetChanged(callback)
manager:OnTrackStopped(name, callback)
manager:MarkerReached(animationName, markerName, callback)
```

### Cleanup

```lua
manager:Destroy()
```

## License

MIT
