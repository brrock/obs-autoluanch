# obs-autoluanch

`obs-autoluanch` is a macOS CLI daemon for opening the right OBS setup when an app appears.

It watches configured app profiles, launches a separate OBS instance for each matching profile, switches OBS to the configured scene, and can start recording on launch. Config changes are hot-reloaded while the daemon is running.

## Features

- Watch multiple app profiles at the same time.
- Launch one OBS instance per matching profile.
- Open a specific OBS scene and scene collection.
- Optionally start recording when OBS launches.
- Match apps by exact process name or prefix.
- Match the visible macOS menu-bar app name for wrapper apps such as Minecraft/Java.
- Optionally require a matching window title.
- Edit profiles through macOS picker dialogs.
- Run continuously through `brew services`.
- Hot-reload config changes without restarting the daemon.

## Requirements

- macOS
- OBS installed at `/Applications/OBS.app`
- Zig 0.16 for building from source
- Homebrew for service installation

The interactive config command uses macOS automation dialogs and may require Accessibility/Automation permission for Terminal, iTerm, or the shell app running it.

## Quick Start

Build locally:

```sh
zig build
```

Create or edit the default config:

```sh
./zig-out/bin/obs-autoluanch config
```

Start the daemon:

```sh
./zig-out/bin/obs-autoluanch daemon
```

Check whether it is running:

```sh
./zig-out/bin/obs-autoluanch status
```

By default, both `config` and `daemon` use:

```sh
~/.config/obsautolaunch/config.json
```

You can pass a custom path when needed:

```sh
obs-autoluanch config ./my-config.json
obs-autoluanch daemon ./my-config.json
```

## Commands

```sh
obs-autoluanch config [config.json]
obs-autoluanch daemon [config.json]
obs-autoluanch status
```

`config` opens an interactive profile editor. It loads existing profiles first, then lets you add, edit, delete, and save.

`daemon` watches the config file and reloads it when it changes.

`status` prints daemon PIDs when running and exits with code `1` when no daemon is found.

## Homebrew Service

This repo includes a tap formula at `Formula/obs-autoluanch.rb`.

```sh
brew tap brrock/obs-autoluanch https://github.com/brrock/obs-autoluanch
brew install --HEAD brrock/obs-autoluanch/obs-autoluanch
```

Create the config before starting the service:

```sh
obs-autoluanch config
```

Start, check, and stop the daemon:

```sh
brew services start obs-autoluanch
obs-autoluanch status
brew services stop obs-autoluanch
```

Logs are written to:

```sh
$(brew --prefix)/var/log/obs-autoluanch.log
```

## Interactive Config

Run:

```sh
obs-autoluanch config
```

The editor uses macOS dialogs to choose:

- a profile action: add, edit, delete, or save
- a running app to watch
- whether to watch the macOS menu-bar app name or executable process name
- app matching mode
- optional window title matching
- an OBS scene from your OBS scene collections
- whether recording should start when OBS launches

For apps whose names vary, choose `Any app starting with first 2 words`. The generated prefix can still be edited before saving.

For Java/wrapper apps such as Minecraft, choose `Mac menu bar app name`. That matches the app name shown in the macOS menu bar instead of the lower-level executable name such as `java`.

## Config File

Example:

```json
{
  "poll_interval_ms": 1000,
  "obs_executable": "/Applications/OBS.app/Contents/MacOS/OBS",
  "profiles": [
    {
      "name": "browser-demo",
      "app": "Google Chrome",
      "app_match": "prefix",
      "app_source": "display",
      "app_title": "Demo",
      "app_title_match": "contains",
      "scene": "Browser Demo",
      "start_recording": false,
      "obs_args": ["--collection", "Demo"]
    }
  ]
}
```

Fields:

- `poll_interval_ms`: polling interval for app checks.
- `obs_executable`: default OBS executable path.
- `profiles[].name`: stable profile name used in logs and reload state.
- `profiles[].app`: process name or process-name prefix.
- `profiles[].app_match`: `exact` or `prefix`.
- `profiles[].app_source`: `display` for the macOS menu-bar app name, or `process` for executable process matching.
- `profiles[].app_title`: optional window title text.
- `profiles[].app_title_match`: `any`, `contains`, `exact`, or `prefix`.
- `profiles[].scene`: OBS scene passed to `--scene`.
- `profiles[].start_recording`: adds `--startrecording` when OBS launches.
- `profiles[].obs_executable`: optional OBS executable override.
- `profiles[].obs_args`: extra OBS CLI arguments, commonly `--collection` or `--profile`.

Older config files using `configs` are still accepted. The interactive editor writes `profiles`.

## Runtime Behavior

When a profile matches, `obs-autoluanch` starts OBS with:

```sh
OBS --multi --scene <scene> [--startrecording] <obs_args...>
```

If the matching profile already has a tracked OBS process, the daemon focuses that OBS process instead of launching another one.

If two configured apps are open, two OBS instances can run at the same time, one per matching profile.

Recording is started at OBS launch time. Starting recording in an already-running OBS instance would require OBS WebSocket control and is not implemented yet.

## Development

```sh
zig build
zig build test
brew style Formula/obs-autoluanch.rb
```
