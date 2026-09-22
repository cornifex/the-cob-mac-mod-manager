#!/bin/bash
#
# valheim-mods.sh — install and update the TheCob mod set for Valheim on macOS
#
# Resolves the newest published version of every mod, installs what changed,
# and leaves everything else alone. Safe to re-run whenever you want updates.
#
#   bash valheim-mods.sh              install / update to newest
#   bash valheim-mods.sh --check      report what would change, touch nothing
#   bash valheim-mods.sh --verify     inspect what's installed; no network, no writes
#   bash valheim-mods.sh --force      reinstall everything at newest
#   bash valheim-mods.sh --dir PATH   point at Valheim explicitly
#   bash valheim-mods.sh --keep-downloads
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
"OdinHorse|OdinPlus|$HEX"
"MultiUserChest|MSchmoecker|$HEX"
"ConditionalConfigSync|shudnal|$HEX"
"ExtraSlots|shudnal|$HEX"
"Quick_Stack_Store_Sort_Trash_Restock|Goldenrevolver|$TS"
)

# Whose dependency pins we compare against, to detect drift.
PACK_NAME="TheCob"; PACK_OWNER="TheCob"; PACK_REG="$HEX"

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
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *)                die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------- locate game

find_valheim() {
  local default="$HOME/Library/Application Support/Steam/steamapps/common/Valheim"
  local vdf="$HOME/Library/Application Support/Steam/steamapps/libraryfolders.vdf"
  local candidates=() c p
  candidates+=("$default")
  if [ -f "$vdf" ]; then
    while IFS= read -r p; do
      if [ -n "$p" ]; then candidates+=("$p/steamapps/common/Valheim"); fi
    done < <(sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf")
  fi
  for c in "${candidates[@]}"; do
    if [ -d "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

step "Locating Valheim"
if [ -z "$VALHEIM" ]; then
  VALHEIM="$(find_valheim)" || die "could not find your Valheim folder.
       Steam -> right-click Valheim -> Manage -> Browse Local Files, then:
         bash $0 --dir \"/the/path/you/see\""
fi
[ -d "$VALHEIM" ] || die "not a directory: $VALHEIM"
if [ ! -e "$VALHEIM/valheim.app" ] && [ ! -e "$VALHEIM/Valheim.app" ] \
   && [ ! -e "$VALHEIM/valheim_Data" ] && [ ! -e "$VALHEIM/Valheim.exe" ]; then
  die "$VALHEIM does not look like a Valheim install. Pass the right one with --dir."
fi
[ -w "$VALHEIM" ] || die "no write permission on $VALHEIM"
say "    $VALHEIM"

STATE="$VALHEIM/BepInEx/.modpack-versions"

# ------------------------------------------------------------------ verify
# Read-only: reports what is on disk. No network, no writes anywhere.

if [ "$VERIFY" -eq 1 ]; then
  ok=0; bad=0
  mark() { if [ "$1" = y ]; then ok=$((ok+1)); printf '    ok    %s\n' "$2"
           else bad=$((bad+1)); printf '    MISS  %s\n' "$2"; fi; }

  step "Loader files"
  for f in BepInEx doorstop_config.ini winhttp.dll start_game_bepinex.sh; do
    if [ -e "$VALHEIM/$f" ]; then mark y "$f"; else mark n "$f"; fi
  done
  if [ -x "$VALHEIM/start_game_bepinex.sh" ]; then
    mark y "start_game_bepinex.sh is executable"
  else
    mark n "start_game_bepinex.sh is NOT executable  (fix: chmod u+x)"
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
  else
    warn "no version state file — this install predates the script, or never ran"
  fi

  step "Rosetta"
  if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    mark y "Rosetta 2 present"
  else
    mark n "Rosetta 2 MISSING  (fix: softwareupdate --install-rosetta)"
  fi

  step "Steam launch options"
  lo=""
  for cfg in "$HOME/Library/Application Support/Steam/userdata"/*/config/localconfig.vdf; do
    [ -f "$cfg" ] || continue
    cand=$(grep -A 40 '"892970"' "$cfg" 2>/dev/null \
           | sed -n 's/.*"LaunchOptions"[[:space:]]*"\(.*\)".*/\1/p' | head -1)
    if [ -n "$cand" ]; then lo="$cand"; break; fi
  done
  if [ -z "$lo" ]; then
    mark n "no launch options set for Valheim -> mods will NOT load"
    say "          set them to:"
    say "          /usr/bin/arch -x86_64 /bin/bash ./start_game_bepinex.sh %command%"
  else
    say "    found: $lo"
    case "$lo" in
      *start_game_bepinex.sh*)
        case "$lo" in
          *-x86_64*) mark y "forces Rosetta and runs the BepInEx launcher" ;;
          *) mark n "runs the launcher but does NOT force x86_64 -> mods will NOT load" ;;
        esac ;;
      *) mark n "does not run start_game_bepinex.sh -> mods will NOT load" ;;
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

resolve_one() { # <entry>  -> appends to the parallel arrays
  local entry="$1" name owner reg ver url prev act
  name="${entry%%|*}"; local rest="${entry#*|}"
  owner="${rest%%|*}"; reg="${rest#*|}"

  api_get "$owner" "$name" "$reg" "$WORK/$name.json"
  ver="$(json_scalar "$WORK/$name.json" version_number)"
  url="$(json_scalar "$WORK/$name.json" download_url)"
  [ -n "$ver" ] && [ -n "$url" ] \
    || die "could not read version/download_url for $owner/$name from the API response.
       Re-run with --keep-downloads and inspect $WORK/$name.json"

  prev="$(installed_version "$name")"
  if [ "$FORCE" -eq 1 ]; then act="reinstall"
  elif [ -z "$prev" ];        then act="install"
  elif [ "$prev" != "$ver" ]; then act="updated"
  else                             act="unchanged"; fi
  if [ "$act" != "unchanged" ]; then changed=$((changed + 1)); fi

  NAMES+=("$name"); VERS+=("$ver"); URLS+=("$url")
  PREV+=("$prev");  ACTION+=("$act")
}

for entry in "${MODS[@]}"; do resolve_one "$entry"; done

i=0
while [ $i -lt ${#NAMES[@]} ]; do
  case "${ACTION[$i]}" in
    unchanged) note="" ;;
    install)   note="new" ;;
    *)         note="(was ${PREV[$i]})  ${ACTION[$i]}" ;;
  esac
  printf '    %-36s %-9s %s\n' "${NAMES[$i]}" "${VERS[$i]}" "$note"
  i=$((i + 1))
done

# ------------------------------------------------------- drift vs the modpack

step "Checking against the versions TheCob's pack pins"
api_get "$PACK_OWNER" "$PACK_NAME" "$PACK_REG" "$WORK/_pack.json"
drift=0; unknown=""
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  dver="${dep##*-}"; drest="${dep%-*}"; dname="${drest#*-}"
  j=0; known=0
  while [ $j -lt ${#NAMES[@]} ]; do
    if [ "${NAMES[$j]}" = "$dname" ]; then
      known=1
      if [ "${VERS[$j]}" != "$dver" ]; then
        printf '    %-36s newest %-9s pack pins %s\n' "$dname" "${VERS[$j]}" "$dver"
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
  warn "$drift mod(s) ahead of what the pack pins — expected on this mode, but"
  warn "   it is the first thing to check if the server behaves oddly for you."
fi
if [ -n "$unknown" ]; then warn "pack now lists mods this script doesn't track:$unknown"; fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  say ""
  say "--check: nothing was modified. $changed mod(s) would change."
  exit 0
fi

if [ "$changed" -eq 0 ]; then
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

bname="${BEPINEX%%|*}"; brest="${BEPINEX#*|}"
bowner="${brest%%|*}"; breg="${brest#*|}"

api_get "$bowner" "$bname" "$breg" "$WORK/_bepinex.json"
bver="$(json_scalar "$WORK/_bepinex.json" version_number)"
burl="$(json_scalar "$WORK/_bepinex.json" download_url)"
bprev="$(installed_version "$bname")"

if [ ! -d "$VALHEIM/BepInEx" ] || [ "$bprev" != "$bver" ] || [ "$FORCE" -eq 1 ]; then
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

install_mod() { # <name> <zip>
  local name="$1" zip="$2" tmp="$WORK/x/$name"
  local found=0 sub dest f

  mkdir -p "$tmp"
  unzip -qo "$zip" -d "$tmp"

  # Move any previous copy aside rather than deleting it.
  for sub in plugins patchers; do
    if [ -d "$VALHEIM/BepInEx/$sub/$name" ]; then
      mkdir -p "$VALHEIM/BepInEx/.replaced-$STAMP/$sub"
      mv "$VALHEIM/BepInEx/$sub/$name" "$VALHEIM/BepInEx/.replaced-$STAMP/$sub/"
    fi
  done

  for sub in plugins patchers core; do
    if [ -d "$tmp/$sub" ]; then
      found=1
      dest="$VALHEIM/BepInEx/$sub/$name"
      mkdir -p "$dest"
      ( cd "$tmp/$sub" && find . -mindepth 1 -maxdepth 1 -exec cp -R {} "$dest/" \; )
    fi
  done

  # Bundled configs are defaults: only place ones the user doesn't already have.
  if [ -d "$tmp/config" ]; then
    found=1
    for f in "$tmp/config"/*; do
      [ -e "$f" ] || continue
      if [ -e "$VALHEIM/BepInEx/config/$(basename "$f")" ]; then
        say "    keeping your existing config/$(basename "$f")"
      else
        cp -R "$f" "$VALHEIM/BepInEx/config/"
      fi
    done
  fi

  if [ "$found" -eq 0 ]; then
    dest="$VALHEIM/BepInEx/plugins/$name"
    mkdir -p "$dest"
    ( cd "$tmp" && find . -mindepth 1 -maxdepth 1 \
        ! -name manifest.json ! -name icon.png \
        ! -name 'README*' ! -name 'CHANGELOG*' ! -name 'LICENSE*' \
        -exec cp -R {} "$dest/" \; )
  fi

  [ -n "$(find "$VALHEIM/BepInEx" -path "*/$name/*" -name '*.dll' 2>/dev/null | head -1)" ]
}

step "Installing $changed change(s)"
failed=0
i=0
while [ $i -lt ${#NAMES[@]} ]; do
  if [ "${ACTION[$i]}" = "unchanged" ]; then i=$((i + 1)); continue; fi
  name="${NAMES[$i]}"; ver="${VERS[$i]}"
  fetch "${URLS[$i]}" "$WORK/$name.zip" "$name $ver"
  if install_mod "$name" "$WORK/$name.zip"; then
    say "    ok   $name $ver"
  else
    warn "$name $ver: no .dll found (config-only package?) — worth a look"
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

      /usr/bin/arch -x86_64 /bin/bash ./start_game_bepinex.sh %command%

  Required on Apple Silicon: BepInEx depends on MonoMod, which has no arm64
  build, so the game must be forced through Rosetta. Without it Valheim
  launches normally and loads none of your mods.
  (Rosetta not installed yet? softwareupdate --install-rosetta)

  Verify after launching:  tail -f "$VALHEIM/BepInEx/LogOutput.log"
EOF
fi
