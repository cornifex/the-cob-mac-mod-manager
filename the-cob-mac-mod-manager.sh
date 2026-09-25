#!/bin/bash
#
# the-cob-mac-mod-manager.sh — install and update the TheCob mod set for
# Valheim on macOS, Linux and Steam Deck
#
# Resolves the newest published version of every mod, installs what changed,
# and leaves everything else alone. Safe to re-run whenever you want updates.
#
#   bash the-cob-mac-mod-manager.sh              install / update to newest
#   bash the-cob-mac-mod-manager.sh --check      report what would change, touch nothing
#   bash the-cob-mac-mod-manager.sh --verify     inspect what's installed; no network, no writes
#   bash the-cob-mac-mod-manager.sh --force      reinstall everything at newest
#   bash the-cob-mac-mod-manager.sh --dir PATH   point at Valheim explicitly
#   bash the-cob-mac-mod-manager.sh --keep-downloads
#
# Your settings are never clobbered: files already in BepInEx/config/ are left
# as they are, and a replaced mod is moved aside into BepInEx/.replaced-<stamp>/
# rather than deleted.
#
# Note: you are tracking newest-of-everything, not the versions TheCob's modpack
# pins. The script tells you when those two have drifted apart, because that is
# the usual cause of bugs only you can reproduce on the server.

set -euo pipefail

HEX="https://valheim.hexium.gg"
TS="https://thunderstore.io"

# The loader. Installed only when missing or when its version changes.
BEPINEX="BepInExPack_Valheim|denikson|$HEX"

# name|owner|registry
MODS=(
"TheCob|TheCob|$HEX"
"Jotunn|ValheimModding|$HEX"
"YamlDotNet|ValheimModding|$HEX"
"Recycle_N_Reclaim|Azumatt|$HEX"
"AzuCraftyBoxes|Azumatt|$HEX"
"AAA_Crafting|Azumatt|$HEX"
"AzuAreaRepair|Azumatt|$HEX"
"OdinHorse|OdinPlus|$HEX"
"MultiUserChest|MSchmoecker|$HEX"
"ConditionalConfigSync|shudnal|$HEX"
"ExtraSlots|shudnal|$HEX"
"UsefulPaths|RustyMods|$HEX"
"Sailing|Smoothbrain|$HEX"
"Quick_Stack_Store_Sort_Trash_Restock|Goldenrevolver|$TS"
"Pathfinder|Crystal|$TS"
)

# Whose dependency pins we compare against, to detect drift.
PACK_NAME="TheCob"; PACK_OWNER="TheCob"; PACK_REG="$HEX"

# Steam launch options each Valheim build needs.
LAUNCH_MAC='/usr/bin/arch -x86_64 /bin/bash ./start_game_bepinex.sh %command%'
LAUNCH_NATIVE='./start_game_bepinex.sh %command%'
LAUNCH_PROTON='WINEDLLOVERRIDES="winhttp=n,b" %command%'

# Read to recognize SteamOS, for the Desktop Mode note.
OS_RELEASE="/etc/os-release"

VALHEIM=""; CHECK_ONLY=0; FORCE=0; KEEP_DOWNLOADS=0; VERIFY=0

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '    !  %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)            VALHEIM="${2:-}"; shift 2 ;;
    --check)          CHECK_ONLY=1; shift ;;
    --verify)         VERIFY=1; shift ;;
    --force)          FORCE=1; shift ;;
    --keep-downloads) KEEP_DOWNLOADS=1; shift ;;
    -h|--help)        sed -n '2,/^$/p' "$0"; exit 0 ;;
    *)                die "unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------------ platform

os="$(uname -s)"
case "$os" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      die "unsupported system: $os. This script runs on macOS and Linux, including Steam Deck.
       On Windows, use a mod manager such as Gale or r2modman." ;;
esac

missing=""
for tool in curl unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then missing="$missing $tool"; fi
done
if [ -n "$missing" ]; then die "missing required tool(s):$missing"; fi

IS_DECK=0
if [ "$PLATFORM" = linux ] && [ -r "$OS_RELEASE" ] \
   && grep -Eqi '^ID="?steamos"?$' "$OS_RELEASE"; then
  IS_DECK=1
fi

# ---------------------------------------------------------------- locate game

steam_roots() { # existing Steam install roots for this platform, one per line
  local r
  if [ "$PLATFORM" = mac ]; then
    set -- "$HOME/Library/Application Support/Steam"
  else
    set -- "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
  fi
  for r in "$@"; do
    if [ -d "$r" ]; then printf '%s\n' "$r"; fi
  done
}

looks_like_valheim() { # <dir>
  [ -e "$1/valheim_Data" ] || [ -e "$1/valheim.x86_64" ] \
    || [ -e "$1/valheim.app" ] || [ -e "$1/Valheim.app" ] \
    || [ -e "$1/valheim.exe" ] || [ -e "$1/Valheim.exe" ]
}

# Each Steam root, then every library its libraryfolders.vdf lists (an SD card,
# a second drive). A folder Steam left behind after moving the game is skipped.
find_valheim() {
  local root lib
  while IFS= read -r root; do
    if looks_like_valheim "$root/steamapps/common/Valheim"; then
      printf '%s\n' "$root/steamapps/common/Valheim"; return 0
    fi
    if [ -f "$root/steamapps/libraryfolders.vdf" ]; then
      while IFS= read -r lib; do
        if [ -n "$lib" ] && looks_like_valheim "$lib/steamapps/common/Valheim"; then
          printf '%s\n' "$lib/steamapps/common/Valheim"; return 0
        fi
      done < <(sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$root/steamapps/libraryfolders.vdf")
    fi
  done < <(steam_roots)
  return 1
}

detect_runtime() { # <dir> -> mac | linux-native | proton | unknown
  if [ -e "$1/valheim.x86_64" ]; then echo linux-native
  elif [ -e "$1/valheim.app" ] || [ -e "$1/Valheim.app" ]; then echo mac
  elif [ -e "$1/valheim.exe" ] || [ -e "$1/Valheim.exe" ]; then echo proton
  else echo unknown; fi
}

step "Locating Valheim"
if [ -z "$VALHEIM" ]; then
  VALHEIM="$(find_valheim)" || die "could not find your Valheim folder.
       Steam -> right-click Valheim -> Manage -> Browse Local Files, then:
         bash $0 --dir \"/the/path/you/see\""
fi
[ -d "$VALHEIM" ] || die "not a directory: $VALHEIM"
looks_like_valheim "$VALHEIM" \
  || die "$VALHEIM does not look like a Valheim install. Pass the right one with --dir."
[ -w "$VALHEIM" ] || die "no write permission on $VALHEIM"

RUNTIME="$(detect_runtime "$VALHEIM")"
case "$RUNTIME" in
  mac)          LAUNCH="$LAUNCH_MAC";    desc="macOS build" ;;
  linux-native) LAUNCH="$LAUNCH_NATIVE"; desc="native Linux build" ;;
  proton)       LAUNCH="$LAUNCH_PROTON"; desc="Windows build under Proton" ;;
  *)            LAUNCH="";               desc="couldn't tell which build this is" ;;
esac
say "    $VALHEIM"
say "    runtime: $RUNTIME ($desc)"

STATE="$VALHEIM/BepInEx/.modpack-versions"

# ------------------------------------------------------------------ verify
# Read-only: reports what is on disk. No network, no writes anywhere.

if [ "$VERIFY" -eq 1 ]; then
  ok=0; bad=0
  mark() { if [ "$1" = y ]; then ok=$((ok+1)); printf '    ok    %s\n' "$2"
           else bad=$((bad+1)); printf '    MISS  %s\n' "$2"; fi; }

  # What each build loads BepInEx through. The macOS and Linux builds start via
  # start_game_bepinex.sh, which preloads the doorstop library; the Windows
  # build under Proton loads winhttp.dll, which reads doorstop_config.ini.
  case "$RUNTIME" in
    mac)          loader="BepInEx doorstop_libs/libdoorstop_x64.dylib start_game_bepinex.sh" ;;
    linux-native) loader="BepInEx doorstop_libs/libdoorstop_x64.so start_game_bepinex.sh" ;;
    proton)       loader="BepInEx doorstop_config.ini winhttp.dll" ;;
    *)            loader="BepInEx" ;;
  esac

  step "Loader files"
  for f in $loader; do
    if [ -e "$VALHEIM/$f" ]; then mark y "$f"; else mark n "$f"; fi
  done
  if [ "$RUNTIME" != proton ]; then
    if [ -x "$VALHEIM/start_game_bepinex.sh" ]; then
      mark y "start_game_bepinex.sh is executable"
    else
      mark n "start_game_bepinex.sh is NOT executable  (fix: chmod u+x)"
    fi
  fi

  step "Installed mods"
  if [ -d "$VALHEIM/BepInEx/plugins" ]; then
    for d in "$VALHEIM/BepInEx/plugins"/*/; do
      [ -d "$d" ] || continue
      n="$(basename "$d")"
      c=$(find "$d" -name '*.dll' 2>/dev/null | wc -l | tr -d ' ')
      v=""
      if [ -f "$STATE" ]; then v="$(awk -F'\t' -v k="$n" '$1==k{print $2; exit}' "$STATE")"; fi
      printf '    %-36s %-9s %s dll\n' "$n" "${v:-?}" "$c"
    done
  else
    warn "no BepInEx/plugins directory"
  fi
  tot=$(find "$VALHEIM/BepInEx/plugins" -name '*.dll' 2>/dev/null | wc -l | tr -d ' ')
  say "    ---"
  say "    $tot plugin DLLs total"
  if [ -f "$STATE" ]; then
    say "    loader: $(awk -F'\t' '$1=="BepInExPack_Valheim"{print $2}' "$STATE")"
    say "    pack:   $PACK_NAME $(awk -F'\t' -v k="$PACK_NAME" '$1==k{print $2}' "$STATE")"
  else
    warn "no version state file — this install predates the script, or never ran"
  fi

  if [ "$PLATFORM" = mac ]; then
    step "Rosetta"
    if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      mark y "Rosetta 2 present"
    else
      mark n "Rosetta 2 MISSING  (fix: softwareupdate --install-rosetta)"
    fi
  fi

  # Valheim's own block only (app 892970), so another game's options are never
  # mistaken for it. Steam escapes quotes inside values as \".
  launch_options() { # <localconfig.vdf>
    awk '
      !inapp && /^[[:space:]]*"892970"[[:space:]]*$/ { pending = 1; next }
      pending { pending = 0; if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) { inapp = 1; depth = 1 }; next }
      inapp && /^[[:space:]]*\{/ { depth++; next }
      inapp && /^[[:space:]]*\}/ { if (--depth == 0) inapp = 0; next }
      inapp && depth == 1 && /^[[:space:]]*"LaunchOptions"[[:space:]]/ {
        v = $0
        sub(/^[[:space:]]*"LaunchOptions"[[:space:]]*"/, "", v)
        sub(/"[[:space:]]*$/, "", v)
        gsub(/\\"/, "\"", v)
        print v; exit
      }
    ' "$1"
  }
  lo_miss() { mark n "$1"; say "          set them to:"; say "          $LAUNCH"; }

  step "Steam launch options"
  lo=""; found_cfg=0
  while IFS= read -r root; do
    for cfg in "$root/userdata"/*/config/localconfig.vdf; do
      [ -f "$cfg" ] || continue
      found_cfg=1
      lo="$(launch_options "$cfg")"
      if [ -n "$lo" ]; then break 2; fi
    done
  done < <(steam_roots)

  if [ "$RUNTIME" = unknown ]; then
    if [ -n "$lo" ]; then say "    found: $lo"; fi
    warn "can't tell which Valheim build this is, so launch options weren't checked"
  elif [ -z "$lo" ] && [ "$found_cfg" -eq 0 ]; then
    lo_miss "couldn't find Steam's localconfig.vdf to read launch options from"
  elif [ -z "$lo" ]; then
    lo_miss "no launch options set for Valheim -> mods will NOT load"
  else
    say "    found: $lo"
    case "$RUNTIME" in
      mac)
        case "$lo" in
          *start_game_bepinex.sh*)
            case "$lo" in
              *-x86_64*) mark y "forces Rosetta and runs the BepInEx launcher" ;;
              *) lo_miss "runs the launcher but does NOT force x86_64 -> mods will NOT load" ;;
            esac ;;
          *WINEDLLOVERRIDES*) lo_miss "sets the Proton override, which does nothing for the macOS build -> mods will NOT load" ;;
          *) lo_miss "does not run start_game_bepinex.sh -> mods will NOT load" ;;
        esac ;;
      linux-native)
        case "$lo" in
          *"arch -x86_64"*) lo_miss "uses the macOS Rosetta wrapper (arch -x86_64), which fails on Linux" ;;
          *start_game_bepinex.sh*) mark y "runs the BepInEx launcher" ;;
          *WINEDLLOVERRIDES*) lo_miss "sets the Proton override, but this is the native Linux build -> mods will NOT load" ;;
          *) lo_miss "does not run start_game_bepinex.sh -> mods will NOT load" ;;
        esac ;;
      proton)
        case "$lo" in
          *start_game_bepinex.sh*) lo_miss "runs the native launcher, which doesn't work for the Windows build under Proton" ;;
          *WINEDLLOVERRIDES*winhttp=n*) mark y "sets the winhttp override Proton needs" ;;
          *) lo_miss "does not set the winhttp override -> mods will NOT load" ;;
        esac ;;
    esac
  fi
  say ""
  say "────────────────────────────────────────────────────────────────"
  if [ "$bad" -eq 0 ]; then say "All $ok checks passed."
  else say "$bad problem(s), $ok ok. See MISS lines above."; fi
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/valheim-mods.XXXXXX")"
cleanup() {
  if [ "$KEEP_DOWNLOADS" -eq 1 ]; then say ""; say "Downloads kept in: $WORK"
  else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# ------------------------------------------------------------------ json

# Both registries serve the Thunderstore-shaped experimental package API:
#   GET /api/experimental/package/{owner}/{name}/
#   -> { ..., "latest": { "version_number": "...", "download_url": "...",
#                         "dependencies": ["Owner-Name-1.2.3", ...] } }
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; fi

json_scalar() { # <file> <key>
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r --arg k "$2" '.latest[$k] // empty' "$1"
  else
    # Split on structural characters so a greedy match can't jump fields.
    tr ',{}' '\n\n\n' < "$1" \
      | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
  fi
}

json_deps() { # <file> -> "Owner-Name-Version" per line
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r '.latest.dependencies[]? // empty' "$1"
  else
    tr ',[]' '\n\n\n' < "$1" \
      | sed -n 's/^[[:space:]]*"\([^"]*-[^"]*-[0-9][^"]*\)".*/\1/p'
  fi
}

api_get() { # <owner> <name> <registry> <outfile>
  local url="$3/api/experimental/package/$1/$2/"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$4" "$url" 2>/dev/null \
    || die "could not reach the registry for $1/$2
       $url
       If this keeps failing the API shape may have changed; the mod pages
       still offer manual downloads."
}

# ------------------------------------------------------------------ resolve

installed_version() { # <name>
  [ -f "$STATE" ] || return 0
  awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$STATE"
}

step "Resolving newest versions"

NAMES=(); VERS=(); URLS=(); PREV=(); ACTION=()
changed=0

resolve() { # <entry>  -> sets R_NAME R_VER R_URL R_PREV R_ACT
  local owner reg rest
  R_NAME="${1%%|*}"; rest="${1#*|}"
  owner="${rest%%|*}"; reg="${rest#*|}"

  api_get "$owner" "$R_NAME" "$reg" "$WORK/$R_NAME.json"
  R_VER="$(json_scalar "$WORK/$R_NAME.json" version_number)"
  R_URL="$(json_scalar "$WORK/$R_NAME.json" download_url)"
  [ -n "$R_VER" ] && [ -n "$R_URL" ] \
    || die "could not read version/download_url for $owner/$R_NAME from the API response.
       Re-run with --keep-downloads and inspect $WORK/$R_NAME.json"

  R_PREV="$(installed_version "$R_NAME")"
  if [ "$FORCE" -eq 1 ]; then R_ACT="reinstall"
  elif [ -z "$R_PREV" ];          then R_ACT="install"
  elif [ "$R_PREV" != "$R_VER" ]; then R_ACT="updated"
  else                                 R_ACT="unchanged"; fi
}

# The loader installs differently from the mods, so it keeps its own variables.
resolve "$BEPINEX"
bname="$R_NAME"; bver="$R_VER"; burl="$R_URL"; bprev="$R_PREV"; bact="$R_ACT"

for entry in "${MODS[@]}"; do
  resolve "$entry"
  if [ "$R_ACT" != "unchanged" ]; then changed=$((changed + 1)); fi
  NAMES+=("$R_NAME"); VERS+=("$R_VER"); URLS+=("$R_URL")
  PREV+=("$R_PREV");  ACTION+=("$R_ACT")
done

# Mods plus the loader: what a run would actually touch.
pending=$changed
if [ "$bact" != "unchanged" ]; then pending=$((pending + 1)); fi

print_row() { # <name> <ver> <prev> <action>
  local note
  case "$4" in
    unchanged) note="" ;;
    install)   note="new" ;;
    *)         note="(was $3)  $4" ;;
  esac
  printf '    %-36s %-9s %s\n' "$1" "$2" "$note"
}

print_row "$bname" "$bver" "$bprev" "$bact"
i=0
while [ $i -lt ${#NAMES[@]} ]; do
  print_row "${NAMES[$i]}" "${VERS[$i]}" "${PREV[$i]}" "${ACTION[$i]}"
  i=$((i + 1))
done

# ------------------------------------------------------- drift vs the modpack

step "Checking against the versions TheCob's pack pins"
api_get "$PACK_OWNER" "$PACK_NAME" "$PACK_REG" "$WORK/_pack.json"
drift=0; unknown=""
ALL_NAMES=("$bname" "${NAMES[@]}"); ALL_VERS=("$bver" "${VERS[@]}")
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  dver="${dep##*-}"; drest="${dep%-*}"; dname="${drest#*-}"
  j=0; known=0
  while [ $j -lt ${#ALL_NAMES[@]} ]; do
    if [ "${ALL_NAMES[$j]}" = "$dname" ]; then
      known=1
      if [ "${ALL_VERS[$j]}" != "$dver" ]; then
        printf '    %-36s newest %-9s pack pins %s\n' "$dname" "${ALL_VERS[$j]}" "$dver"
        drift=$((drift + 1))
      fi
      break
    fi
    j=$((j + 1))
  done
  if [ "$known" -eq 0 ]; then unknown="$unknown $dname"; fi
done < <(json_deps "$WORK/_pack.json")

if [ "$drift" -eq 0 ]; then
  say "    in sync with the pack"
else
  warn "$drift package(s) ahead of what the pack pins — expected on this mode, but"
  warn "   it is the first thing to check if the server behaves oddly for you."
fi
if [ -n "$unknown" ]; then warn "pack now lists mods this script doesn't track:$unknown"; fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  say ""
  say "--check: nothing was modified. $pending package(s) would change."
  exit 0
fi

if [ "$pending" -eq 0 ]; then
  say ""
  say "Everything already at newest. Nothing to do."
  exit 0
fi

# ------------------------------------------------------------------ BepInEx

fetch() { # <url> <out> <label>
  curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1" \
    || die "download failed: $3"
  unzip -tqq "$2" >/dev/null 2>&1 \
    || die "not a valid zip: $3 (a proxy may have returned an error page)"
}

if [ ! -d "$VALHEIM/BepInEx" ] || [ "$bact" != "unchanged" ]; then
  step "Installing BepInEx $bver${bprev:+ (was $bprev)}"
  fetch "$burl" "$WORK/bepinex.zip" "BepInEx $bver"
  mkdir -p "$WORK/x/_bepinex"
  unzip -qo "$WORK/bepinex.zip" -d "$WORK/x/_bepinex"

  src="$WORK/x/_bepinex"
  if [ -d "$src/BepInExPack_Valheim" ]; then src="$src/BepInExPack_Valheim"; fi

  # Never let a loader upgrade overwrite existing settings or installed plugins.
  if [ -d "$VALHEIM/BepInEx" ]; then
    rm -rf "$src/BepInEx/config" "$src/BepInEx/plugins" "$src/BepInEx/patchers"
  fi
  ( cd "$src" && find . -mindepth 1 -maxdepth 1 -exec cp -R {} "$VALHEIM/" \; )
  [ -d "$VALHEIM/BepInEx" ] || die "BepInEx missing after install — pack layout may have changed."
  say "    ok"
else
  step "BepInEx $bver already installed"
fi

mkdir -p "$VALHEIM/BepInEx/plugins" "$VALHEIM/BepInEx/config"

# -------------------------------------------------------------------- mods

install_mod() { # <name> <zip>  -> sets CFG_NEW, CFG_KEPT
  local name="$1" zip="$2" tmp="$WORK/x/$name"
  local found=0 root sub dest rel

  mkdir -p "$tmp"
  unzip -qo "$zip" -d "$tmp"

  # Move any previous copy aside rather than deleting it.
  for sub in plugins patchers; do
    if [ -d "$VALHEIM/BepInEx/$sub/$name" ]; then
      mkdir -p "$VALHEIM/BepInEx/.replaced-$STAMP/$sub"
      mv "$VALHEIM/BepInEx/$sub/$name" "$VALHEIM/BepInEx/.replaced-$STAMP/$sub/"
    fi
  done

  # Files sit either at the top of the zip or one level down under BepInEx/,
  # which is how Gale exports a modpack's configs.
  CFG_NEW=0; CFG_KEPT=0
  for root in "$tmp" "$tmp/BepInEx"; do
    for sub in plugins patchers core; do
      if [ -d "$root/$sub" ]; then
        found=1
        dest="$VALHEIM/BepInEx/$sub/$name"
        mkdir -p "$dest"
        ( cd "$root/$sub" && find . -mindepth 1 -maxdepth 1 -exec cp -R {} "$dest/" \; )
      fi
    done

    # Bundled configs are defaults: place each file, subfolders included,
    # only if the user doesn't already have it.
    if [ -d "$root/config" ]; then
      found=1
      while IFS= read -r rel; do
        rel="${rel#./}"
        if [ -e "$VALHEIM/BepInEx/config/$rel" ]; then
          CFG_KEPT=$((CFG_KEPT + 1))
        else
          mkdir -p "$(dirname "$VALHEIM/BepInEx/config/$rel")"
          cp "$root/config/$rel" "$VALHEIM/BepInEx/config/$rel"
          CFG_NEW=$((CFG_NEW + 1))
        fi
      done < <(cd "$root/config" && find . -type f)
    fi
  done

  if [ "$found" -eq 0 ]; then
    dest="$VALHEIM/BepInEx/plugins/$name"
    mkdir -p "$dest"
    ( cd "$tmp" && find . -mindepth 1 -maxdepth 1 \
        ! -name manifest.json ! -name icon.png \
        ! -name 'README*' ! -name 'CHANGELOG*' ! -name 'LICENSE*' \
        -exec cp -R {} "$dest/" \; )
  fi

  # A package that ships configs and no code at all (the modpack) is complete.
  if [ -z "$(find "$tmp" -name '*.dll' | head -1)" ] && [ $((CFG_NEW + CFG_KEPT)) -gt 0 ]; then
    return 0
  fi
  [ -n "$(find "$VALHEIM/BepInEx" -path "*/$name/*" -name '*.dll' 2>/dev/null | head -1)" ]
}

if [ "$changed" -gt 0 ]; then step "Installing $changed change(s)"; fi
failed=0
i=0
while [ $i -lt ${#NAMES[@]} ]; do
  if [ "${ACTION[$i]}" = "unchanged" ]; then i=$((i + 1)); continue; fi
  name="${NAMES[$i]}"; ver="${VERS[$i]}"
  fetch "${URLS[$i]}" "$WORK/$name.zip" "$name $ver"
  if install_mod "$name" "$WORK/$name.zip"; then
    note=""
    if [ $((CFG_NEW + CFG_KEPT)) -gt 0 ]; then
      note="  (configs: $CFG_NEW added, $CFG_KEPT existing kept)"
    fi
    say "    ok   $name $ver$note"
  else
    warn "$name $ver: no .dll found — worth a look"
    failed=$((failed + 1))
  fi
  i=$((i + 1))
done

# ------------------------------------------------------------------ state

{
  printf '%s\t%s\n' "$bname" "$bver"
  i=0
  while [ $i -lt ${#NAMES[@]} ]; do
    printf '%s\t%s\n' "${NAMES[$i]}" "${VERS[$i]}"
    i=$((i + 1))
  done
} > "$STATE"

if [ -f "$VALHEIM/start_game_bepinex.sh" ]; then
  chmod u+x "$VALHEIM/start_game_bepinex.sh"
fi

# ------------------------------------------------------------------ report

dll_count=$(find "$VALHEIM/BepInEx/plugins" -name '*.dll' 2>/dev/null | wc -l | tr -d ' ')
say ""
say "────────────────────────────────────────────────────────────────"
say "Done. $dll_count plugin DLLs in BepInEx/plugins/."
if [ -d "$VALHEIM/BepInEx/.replaced-$STAMP" ]; then
  say "Previous copies moved to BepInEx/.replaced-$STAMP/ (delete when happy)."
fi
if [ "$failed" -gt 0 ]; then say "$failed mod(s) need a manual look — see above."; fi

if [ -z "$bprev" ]; then
  cat <<EOF

FIRST-TIME SETUP — do this once in Steam:

  Steam -> Valheim -> Properties -> General -> Launch Options, paste:

EOF
  if [ -n "$LAUNCH" ]; then
    say "      $LAUNCH"
  else
    say "  Couldn't tell which Valheim build this is. Use the line for yours:"
    say ""
    say "      macOS:          $LAUNCH_MAC"
    say "      Linux native:   $LAUNCH_NATIVE"
    say "      Proton:         $LAUNCH_PROTON"
  fi
  say ""
  if [ "$RUNTIME" = mac ]; then
    cat <<'EOF'
  Required on Apple Silicon: BepInEx depends on MonoMod, which has no arm64
  build, so the game must be forced through Rosetta. Without it Valheim
  launches normally and loads none of your mods.
  (Rosetta not installed yet? softwareupdate --install-rosetta)

EOF
  elif [ "$RUNTIME" = proton ]; then
    cat <<'EOF'
  Keep the quotes exactly as shown. The override makes Proton load BepInEx's
  winhttp.dll instead of its own; without it Valheim loads none of your mods.

EOF
  fi
  if [ "$IS_DECK" -eq 1 ]; then
    cat <<'EOF'
  On Steam Deck, set this in Desktop Mode, in the Steam window here. It carries
  over into Game Mode.

EOF
  fi
  say "  Verify after launching:  tail -f \"$VALHEIM/BepInEx/LogOutput.log\""
fi
