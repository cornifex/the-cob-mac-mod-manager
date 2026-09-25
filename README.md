# the-cob-mac-mod-manager

A single-file installer and updater for the [TheCob](https://valheim.hexium.gg/mods/TheCob/TheCob) Valheim modpack on macOS.

There is no mod manager for macOS. [Gale](https://github.com/Kesomannen/gale) ships Windows and Linux builds only, and so does [r2modman](https://github.com/ebkr/r2modmanPlus). This script covers the gap: it resolves the newest version of every mod in the pack, installs what changed, and leaves everything else alone.

## Requirements

- macOS with Valheim installed through Steam
- Rosetta 2 — `softwareupdate --install-rosetta` (Apple Silicon only)
- `curl` and `unzip`, both stock on macOS. `jq` is used when present and not required.

## Install

```sh
bash the-cob-mac-mod-manager.sh
```

It finds Valheim at the default Steam path, or in any library listed in `libraryfolders.vdf`. If detection fails, point it directly:

```sh
bash the-cob-mac-mod-manager.sh --dir "/path/to/steamapps/common/Valheim"
```

### Then set the Steam launch options — once

Steam → Valheim → Properties → General → Launch Options:

```
/usr/bin/arch -x86_64 /bin/bash ./start_game_bepinex.sh %command%
```

**This is not optional on Apple Silicon.** BepInEx 5 depends on MonoMod, which has [no arm64 support](https://github.com/BepInEx/BepInEx/issues/899), so the game must be forced through Rosetta. Leave off `arch -x86_64` and Valheim launches perfectly normally with none of your mods loaded — which is the confusing part, because nothing appears to be broken.

The script deliberately does not set this for you. Steam stores launch options in `localconfig.vdf` and rewrites that file on exit, so an edit made while Steam is running is silently discarded, and a bad patch lands in the same file as every other game's settings.

## Usage

```sh
bash the-cob-mac-mod-manager.sh              # install, or update to newest
bash the-cob-mac-mod-manager.sh --check      # report what would change, touch nothing
bash the-cob-mac-mod-manager.sh --verify     # inspect what's installed; no network, no writes
bash the-cob-mac-mod-manager.sh --force      # reinstall everything at newest
bash the-cob-mac-mod-manager.sh --dir PATH   # point at Valheim explicitly
bash the-cob-mac-mod-manager.sh --keep-downloads
```

Re-run it whenever you want updates. It records installed versions in `BepInEx/.modpack-versions`, compares against what the registries currently serve, and downloads only what actually changed — a run with nothing new exits in a couple of seconds.

### `--verify`

Reports loader files, the executable bit on `start_game_bepinex.sh`, every plugin folder with its version and DLL count, whether Rosetta 2 is present, and — reading `localconfig.vdf` read-only — whether your Steam launch options are correct. It distinguishes the three states that matter: correct, running the launcher without `-x86_64`, and not running it at all.

## What it won't break

- **Your configs.** Anything already in `BepInEx/config/` is left alone. A mod's bundled config is treated as a default and only placed if you don't already have that file. This includes `BepInEx.cfg` when the loader itself upgrades, and the configs TheCob's pack ships, so a fresh install starts with the pack's settings. Settings marked `[Synced with Server]` come from the server while you're connected, whatever your file says.
- **Your old versions.** A replaced mod is moved to `BepInEx/.replaced-<timestamp>/`, never deleted. A bad update is a drag-back.
- **Anything outside Valheim.** The script refuses to run against a directory that doesn't look like a Valheim install, and downloads to a temp dir it removes on exit.

## Version tracking

This tracks **the newest version of each mod**, not the versions TheCob's pack pins. Every run reports where the two have diverged:

```
==> Checking against the versions TheCob's pack pins
    Jotunn          newest 2.31.1   pack pins 2.30.0
    !  1 package(s) ahead of what the pack pins
```

Not an error. But `ConditionalConfigSync` means the server pushes config down to clients, so version drift is the first thing to check if the server misbehaves for you and nobody else. If the pack later adds a mod this script doesn't track, it says so.

To pin to the pack instead, replace the resolver with the pack's own `latest.dependencies` list.

## Mods

| Mod | Author |
|---|---|
| TheCob | TheCob |
| Jotunn | ValheimModding |
| YamlDotNet | ValheimModding |
| Recycle_N_Reclaim | Azumatt |
| AzuCraftyBoxes | Azumatt |
| AAA_Crafting | Azumatt |
| AzuAreaRepair | Azumatt |
| OdinHorse | OdinPlus |
| MultiUserChest | MSchmoecker |
| ConditionalConfigSync | shudnal |
| ExtraSlots | shudnal |
| UsefulPaths | RustyMods |
| Sailing | Smoothbrain |
| Quick_Stack_Store_Sort_Trash_Restock | Goldenrevolver |
| Pathfinder | Crystal |

Thirteen resolve from [Hexium](https://valheim.hexium.gg/). Two aren't published there and resolve from Thunderstore: [`Quick_Stack_Store_Sort_Trash_Restock`](https://thunderstore.io/c/valheim/p/Goldenrevolver/Quick_Stack_Store_Sort_Trash_Restock/) and [`Pathfinder`](https://thunderstore.io/c/valheim/p/Crystal/Pathfinder/). Both registries serve the same Thunderstore-shaped API, so one resolver handles both:

```
GET {registry}/api/experimental/package/{owner}/{name}/
  -> .latest.version_number
     .latest.download_url
     .latest.dependencies[]
```

The loader is [BepInExPack Valheim](https://valheim.hexium.gg/mods/denikson/BepInExPack_Valheim), tracked and upgraded the same way.

## Troubleshooting

**Game launches, no mods.** Launch options. Run `--verify`.

**No `BepInEx/LogOutput.log` after launching.** Same — the launch options never took effect.

**A mod misbehaves after an update.** Its previous copy is in `BepInEx/.replaced-<timestamp>/`. Move it back and pin that version.

**"not a valid zip".** A proxy or captive portal returned an error page with a 200. The script catches this rather than installing garbage.

**Adding or removing a mod.** Edit the `MODS` array — `name|owner|registry`, one per line.
