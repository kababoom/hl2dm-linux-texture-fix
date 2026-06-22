# HL2DM Linux Texture Fix

Fixes **purple / missing custom-map textures** in **native Linux** *Half-Life 2: Deathmatch* — no Proton, no broken VAC.

![missing material checkerboard](https://developer.valvesoftware.com/w/images/thumb/2/25/Missing_textures.jpg/320px-Missing_textures.jpg)

## The problem

On native Linux, the Source engine **lowercases** material lookups and reads **case-sensitively inside `.vpk` archives and `.bsp` pakfiles**. Custom maps reference textures with mixed/UPPER-case paths, so:

- **Stock maps** (lowercase names) → render fine.
- **Custom maps** (mixed/upper-case names) → **purple/black checkerboard**.

It works on Windows because NTFS + the Windows build are case-insensitive. **Proton** sidesteps it too — **but Proton disables VAC**, so if you want to play on secure servers you're on the native client, where this bug bites.

## The fix

The engine *does* resolve **lowercase loose files** correctly. So this script:

1. Extracts stock materials from the game's VPKs → loose files.
2. **Carves** each map's packed content out of its `.bsp` pakfile → loose files.
3. **Lowercases** every extracted path — the critical step, since packed content is frequently UPPERCASE.

No FUSE, no overlay, nothing running alongside the game.

> ⚠️ **Do not** use a case-insensitive FUSE overlay (`ciopfs` / `cicpoffs`) for this. Source memory-maps its VPKs, and mmap through a FUSE layer **segfaults the engine on startup**. Loose extraction is the stable approach.

## Usage

```bash
chmod +x fix-hl2dm-textures.sh
./fix-hl2dm-textures.sh            # auto-detects your HL2DM install
# or pass the path explicitly:
./fix-hl2dm-textures.sh "$HOME/.local/share/Steam/steamapps/common/Half-Life 2 Deathmatch"
```

Run it once, and again whenever you download new custom maps. Then reload the map in-game (open the console with `` ~ `` and type `retry`).

Requires `unzip`, `dd`, `od` (standard on any distro). **No root needed.**

### Auto mode (`--watch`)

`--watch` does an initial pass, then **re-scans the download folder every few seconds** and auto-fixes each new map shortly after it finishes downloading:

```bash
./fix-hl2dm-textures.sh --watch
```

Leave it running while you play; reload a map (`retry`) after it reports fixing one. (It polls rather than using inotify events, so it can't miss a download regardless of timing, and needs no extra packages. It only reads game files and writes loose copies — it never touches the running game.)

## Still purple after running it?

Then that map references content that **isn't packed in the BSP and isn't in the game** — genuinely missing assets (it'd be purple on Windows too). Nothing to extract; the file simply doesn't exist on your machine.

**Find out exactly what's missing:** add `-condebug` to the game's launch options, load the map, and the engine writes every `Missing map material: NAME` line to `hl2mp/console.log`.

## Notes

- Tested on **Half-Life 2: Deathmatch**. The same technique works for other Source 1 games (CS:S, etc.) — change `GAME_NAME` / `MOD` at the top of the script.
- This is a **workaround for an engine limitation** (case-sensitive VPK/BSP lookups on Linux), not an official fix.

## License

[MIT](LICENSE)
