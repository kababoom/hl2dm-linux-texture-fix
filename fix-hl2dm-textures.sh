#!/usr/bin/env bash
#
# fix-hl2dm-textures.sh
# Fix purple / missing custom-map textures in NATIVE Linux Half-Life 2: Deathmatch.
#
# WHY: the native Linux Source engine lowercases its material lookups and reads
# CASE-SENSITIVELY inside .vpk archives and .bsp pakfiles. Custom maps reference
# textures with mixed/UPPER-case paths, so they render on Windows (case-
# insensitive) but go purple on Linux. Stock maps use lowercase names -> fine.
# Proton sidesteps this but disables VAC, so native-client users are stuck.
#
# FIX: the engine *does* resolve lowercase LOOSE files, so unpack what's needed
# to loose files and lowercase them:
#   1. stock materials from the game VPKs        -> loose
#   2. each map's packed content from the BSP     -> loose (carve the pakfile lump)
#   3. lowercase every extracted path             <- the critical step
#
# Do NOT use a FUSE case-insensitive overlay (ciopfs/cicpoffs): Source mmaps its
# VPKs and mmap through FUSE segfaults the engine.
#
# USAGE:
#   ./fix-hl2dm-textures.sh                 # one-shot: fix everything installed now
#   ./fix-hl2dm-textures.sh --watch         # one-shot, then auto-fix new map downloads
#   ./fix-hl2dm-textures.sh [--watch] "/path/to/steamapps/common/Half-Life 2 Deathmatch"
# After it fixes a map, reload it in-game: open the console (~) and type  retry
#
# Requires: unzip, dd, od (coreutils). --watch also needs inotifywait (inotify-tools).
# No root needed.

set -u
GAME_NAME="Half-Life 2 Deathmatch"
MOD="hl2mp"

# ---------- args ----------
WATCH=0
GAME=""
for a in "$@"; do
  case "$a" in
    --watch) WATCH=1 ;;
    -h|--help) echo "usage: $0 [--watch] [/path/to/$GAME_NAME]"; exit 0 ;;
    *) GAME="$a" ;;
  esac
done

# ---------- locate the game install ----------
if [ -z "$GAME" ]; then
  for root in \
      "$HOME/.steam/steam" "$HOME/.steam/root" "$HOME/.steam/debian-installation" \
      "$HOME/.local/share/Steam" \
      "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    [ -d "$root" ] || continue
    if [ -d "$root/steamapps/common/$GAME_NAME" ]; then
      GAME="$root/steamapps/common/$GAME_NAME"; break
    fi
    lf="$root/steamapps/libraryfolders.vdf"
    if [ -f "$lf" ]; then
      while IFS= read -r lib; do
        if [ -d "$lib/steamapps/common/$GAME_NAME" ]; then
          GAME="$lib/steamapps/common/$GAME_NAME"; break
        fi
      done < <(grep -oE '"path"[[:space:]]+"[^"]+"' "$lf" | sed -E 's/.*"([^"]+)"$/\1/')
      [ -n "$GAME" ] && break
    fi
  done
fi
if [ -z "$GAME" ] || [ ! -d "$GAME" ]; then
  echo "Could not find '$GAME_NAME'. Pass the path explicitly, e.g.:"
  echo "  $0 \"\$HOME/.local/share/Steam/steamapps/common/$GAME_NAME\""
  exit 1
fi
VPKBIN="$GAME/bin/vpk"
DLMAPS="$GAME/$MOD/download/maps"
echo "Game: $GAME"
vpk() { LD_LIBRARY_PATH="$GAME/bin" "$VPKBIN" "$@"; }

# ---------- helpers ----------
# Extract one BSP's packed content to loose. Carve LUMP_PAKFILE (lump 40) out
# first (offset/len are little-endian int32 at header bytes 648/652), then unzip
# THAT. Running unzip on the .bsp directly only works when the pakfile sits at
# the file's end; on large maps it's mid-file and unzip silently finds nothing.
extract_bsp_pak() {
  local bsp="$1" tmp ofs len
  ofs=$(od -An -tu4 -j648 -N4 "$bsp" 2>/dev/null | tr -d ' ')
  len=$(od -An -tu4 -j652 -N4 "$bsp" 2>/dev/null | tr -d ' ')
  [ -n "$ofs" ] && [ -n "$len" ] || return 1
  case "$len" in ''|*[!0-9]*) return 1;; esac
  [ "$len" -gt 0 ] || return 1
  tmp=$(mktemp) || return 1
  dd if="$bsp" of="$tmp" bs=1M iflag=skip_bytes,count_bytes skip="$ofs" count="$len" 2>/dev/null
  unzip -o -q "$tmp" -x "materials/maps/*" -d "$GAME/$MOD/" 2>/dev/null  # skip per-map cubemaps
  rm -f "$tmp"
}

# Lowercase every file path under the mod's materials/ and models/ (engine
# lowercases its lookups; packed content is often UPPERCASE).
lowercase_tree() {
  local base root f rel lrel
  for base in "$MOD/materials" "$MOD/models"; do
    root="$GAME/$base"; [ -d "$root" ] || continue
    find "$root" -type f | while IFS= read -r f; do
      rel="${f#"$root"/}"; lrel=$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')
      [ "$rel" != "$lrel" ] && { mkdir -p "$root/$(dirname "$lrel")"; mv -f "$f" "$root/$lrel"; }
    done
    find "$root" -type d -empty -delete 2>/dev/null
  done
}

# Extract stock materials from the VPKs (one-time; skipped once done).
extract_stock() {
  if [ -d "$GAME/hl2/materials/concrete" ]; then
    echo "[stock] already extracted - skipping."; return
  fi
  echo "[stock] extracting materials from VPKs (one-time)..."
  local pair vpkfile dest vmts
  for pair in "hl2/hl2_misc_dir.vpk|hl2" "$MOD/${MOD}_pak_dir.vpk|$MOD"; do
    vpkfile="${pair%%|*}"; dest="${pair##*|}"
    [ -f "$GAME/$vpkfile" ] || continue
    ( cd "$GAME/$dest" || exit
      vmts=$(vpk l "$GAME/$vpkfile" 2>/dev/null | grep -iE '\.vmt$')
      printf '%s\n' "$vmts" | sed 's#/[^/]*$##' | sort -u | while read -r d; do [ -n "$d" ] && mkdir -p "$d"; done
      printf '%s\n' "$vmts" | xargs -d '\n' -r env LD_LIBRARY_PATH="$GAME/bin" "$VPKBIN" x "$GAME/$vpkfile" >/dev/null 2>&1 )
  done
}

# One-shot pass over everything installed right now.
oneshot() {
  extract_stock
  echo "[maps] extracting packed content from installed maps..."
  local n=0 bsp
  for bsp in "$DLMAPS/"*.bsp "$GAME/$MOD/maps/"*.bsp; do
    [ -f "$bsp" ] || continue
    extract_bsp_pak "$bsp" && n=$((n+1))
  done
  lowercase_tree
  echo "[maps] processed $n map(s)."
}

# ---------- run ----------
oneshot

if [ "$WATCH" -eq 1 ]; then
  if ! command -v inotifywait >/dev/null 2>&1; then
    echo; echo "--watch needs inotifywait. Install it with:  sudo apt install inotify-tools"; exit 1
  fi
  mkdir -p "$DLMAPS"
  echo; echo "==> Watching for new map downloads in: $DLMAPS"
  echo "==> Leave this window open while you play. Close it (or Ctrl+C) to stop."
  inotifywait -m -e close_write -e moved_to --format '%w%f' "$DLMAPS" 2>/dev/null |
  while IFS= read -r path; do
    case "$path" in
      *.bsp)
        echo "[$(basename "$path")] new map - fixing..."
        extract_bsp_pak "$path"
        lowercase_tree
        echo "    done. Reload in-game: console (~) -> retry"
        ;;
    esac
  done
else
  echo "Done. Reload the map in-game (console ~ -> retry)."
fi
