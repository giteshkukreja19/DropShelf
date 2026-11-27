# DropShelf

## What’s new in v2.1.0

- Capture Studio: recording setup, compact controls, pause/resume, restart, discard and configurable countdown.
- Live microphone speech recognition, optional captions and TXT/SRT transcript export.
- Remove Silent Parts and video trimming.
- Quick Screen Translation using Apple Translation on supported macOS versions.
- Image background removal, favourite items and automatic file organization.
- Expanded document conversion and improved PDF-to-Word formatting (complex layouts may vary).
- Redesigned installer and File & Text Tools settings.

Apple Silicon; macOS 13 or later, with newer versions required for some features. Ad-hoc signed, not notarized.

[Download v2.1.0](https://github.com/giteshkukreja19/DropShelf/releases/tag/v2.1.0)


## What's New in v2.0.0

- Capture Studio for screen recording.
- Custom Actions and reusable workflows.
- Intelligent Shelf Names.
- Folder Monitoring.
- Favourite file locations.
- Improved image and document tools.
- Customizable keyboard shortcuts.
- Configurable storage location.
- Redesigned native macOS settings.
- Automatic light and dark appearance.
- Improved shelf interactions and animations.
- Updated Sparkle update configuration.
- Stability and performance improvements.

### Compatibility

- Apple Silicon Macs (M1 and newer).
- macOS 13 or later, with newer macOS versions required for some features.
- All 41 automated tests passed.

### Download

[Download DropShelf v2.0.0](https://github.com/giteshkukreja19/DropShelf/releases/tag/v2.0.0)



A free, open-source macOS shelf for files. Drag stuff in, drop it out wherever you need it later.

It's an exact clone of [Dropover](https://dropoverapp.com/) — same shake-to-summon shelf, same drop-anywhere-to-collect workflow, same drag-out-to-deliver behavior — except free.

<img width="730" height="572" alt="Image2026-05-04 at 00 07 52@2x" src="https://github.com/user-attachments/assets/328a8574-0c14-4f75-9814-df07415fe675" />


## Why

Dropover is a great paid app. DropShelf is the same idea, written from scratch as a single SwiftPM target, free under the MIT license. If Dropover does what you need and you want to support its author, buy Dropover. If you want a free tool that does the same thing without a license server, this is it.

## What it does

- **Shake a Finder drag** to summon a floating shelf at the cursor. Drop the files onto it.
- **Drop anywhere on screen** while a shelf is open to add files, images, or text.
- **Drag back out** to any app — Finder, browser upload zones, Mail, Slack, Messages, anywhere that accepts a file URL.
- **Dock to the screen edge** for ambient access; the shelf becomes a tab you can hover or drop onto.
- **Multiple shelves** at once, each with its own floating panel.
- **Auto-expiry** — shelves clean themselves up after a configurable retention window.

## Features

- Drag from Finder *or* drag back out to any drop target — including web upload widgets, since the pasteboard exposes both `NSFilePromiseProvider` and `public.file-url`.
- Drag preview matches the rendered card (image thumbnail, text preview, or doc card) instead of a generic file icon.
- Aspect-ratio-aware cards: a landscape photo shows wide-and-short, a portrait shows tall-and-narrow — both uncropped.
- File metadata in-line: dimensions for images (RAW/CR2/HEIC included), page count for PDFs, size for everything.
- **Convert to ▶** in the right-click menu — image interop (HEIC ↔ JPEG/PNG, PNG/TIFF/WebP → JPEG/PNG, JPEG → PNG) via ImageIO, video → MP4 (MOV/M4V plus best-effort MKV/AVI) via AVFoundation. Pass-through remux when the source is already H.264/AAC. Multi-select converts in batch; a small spinner / progress bar overlays the source card while a video is encoding, with ✕ to cancel.
- **Keep Mac Awake** at the top of the menubar menu, plus an **Activate for ▶** submenu (5/10/15/20 min, 1/2/3/5 hr, indefinitely). Backed by an IOKit power assertion — blocks idle display sleep, idle system sleep, and the screen saver (does not override lid-close, same as Caffeine). Status icon fills solid with a knockout corner pip while it's on.
- **Pasted text snippets** are real openable files: double-click opens in TextEdit, Show in Finder reveals them.
- **AppKit-level drop target** — no green "+" copy badge on the cursor while dragging onto a shelf.
- **Newest-first** ordering in the expanded grid/list so the just-dropped tile is right where you're looking.
- **Rename…** in the right-click menu on any file row (Finder-style: stem pre-selected, extension preserved).
- **Cmd-Z undo** for Clear Shelf and Move to Trash. Trash undo restores the file from the system Trash to its original location.
- Quick Look on space, batch rename, ZIP archive, Move to Trash, Show in Finder, AirDrop, Messages, Open With…
- Auto-pruning of items whose backing files were trashed from Finder while you weren't looking.
- Menubar status icon flips between resting (`[ ·]`) and "ready to receive" while a drop is in flight.
- Liquid-glass-ish floating panel (vibrant blur + subtle stroke) that approximates macOS Tahoe's `.glassEffect()` on macOS 13+.

## Install

### Pre-built DMG

Latest release: <https://github.com/giteshkukreja19/DropShelf/releases/latest>

One-liner install:

```sh
curl -L -o ~/Downloads/DropShelf.dmg \
  https://github.com/giteshkukreja19/DropShelf/releases/latest/download/DropShelf.dmg
open ~/Downloads/DropShelf.dmg
# Drag DropShelf.app to /Applications, eject the DMG, then:
xattr -dr com.apple.quarantine /Applications/DropShelf.app
open /Applications/DropShelf.app
```

The `xattr` step is one-time per machine — the DMG is ad-hoc signed (no Apple Developer ID / notarization), so Gatekeeper marks it quarantined on first download. After that, DropShelf lives in your menubar; click the icon to see options, or shake any Finder drag to summon a shelf.

### Build from source

Requires macOS 13+ and the Swift toolchain that ships with Xcode 15+ (Swift 5.9).

```sh
git clone https://github.com/giteshkukreja19/DropShelf.git
cd DropShelf

# Run for development:
swift run ShelfDemo

# Build a signed .app and .dmg for distribution:
bash scripts/build-dmg.sh
# → produces dist/DropShelf.app and DropShelf.dmg in the repo root
```

Cutting a new release after a build:

```sh
gh release create v1.2 DropShelf.dmg \
  --title "DropShelf v1.2" \
  --notes "What changed in this release…"
```

`scripts/build-dmg.sh` regenerates the app icon (`scripts/make-icon.swift`), builds in release mode, embeds Sparkle.framework, ad-hoc signs the bundle inner-out, and packages a DMG with an `/Applications` symlink for drag-install.

### Releasing a new version (with auto-update)

DropShelf ships with Sparkle 2.x for in-app updates from v1.5.0 onward. Each release is signed with an EdDSA private key and listed in `appcast.xml` so existing installs pick it up.

**One-time setup (per release machine):**

1. `swift package resolve` — pulls Sparkle's CLI tools into `.build/artifacts/sparkle/Sparkle/bin/`.
2. `.build/artifacts/sparkle/Sparkle/bin/generate_keys` — creates the EdDSA key pair. The private key lives in your macOS Keychain; the tool prints the public key.
3. Save the public key into `scripts/.sparkle-public-key` (gitignored):
   ```sh
   echo "SPARKLE_PUBLIC_KEY=<paste public key here>" > scripts/.sparkle-public-key
   ```

**Per release:**

1. Set the display `VERSION` and increasing `BUILD_VERSION` in `scripts/build-dmg.sh`.
2. `bash scripts/build-dmg.sh` — produces `DropShelf.dmg` with Sparkle.framework embedded and the feed URL + public key baked into Info.plist.
3. `bash scripts/sign-appcast.sh DropShelf.dmg <version> <build-version>` — prints an appcast `<item>` snippet with the signed enclosure to stdout.
4. Prepend that snippet inside the `<channel>` block in `appcast.xml`.
5. `gh release create v<version> DropShelf.dmg --title "DropShelf v<version>" --notes "..."`
6. `git add appcast.xml && git commit -m "release: v<version>" && git push origin main`

Existing v1.5.0+ installs see the new version on their next daily check (or when the user clicks "Check for Updates…" in the menu). v1.4.x users will need to download v1.5.0 manually one final time.

## Permissions

DropShelf doesn't ask for any special permissions. It uses macOS's stock drag pasteboard, security-scoped bookmarks for files added across reboots, and `CGEvent`-based mouse monitoring for the shake gesture (no accessibility prompt needed for `.leftMouseDragged` global monitors).

## Status

Personal project. Works for me. PRs welcome but no guarantees about responsiveness.

## Credits

- Inspired by, and functionally a clone of, [**Dropover**](https://dropoverapp.com/) — go buy it if this helps you.
- Built with SwiftUI + AppKit on top of `NSPanel`, `NSFilePromiseProvider`, `QLThumbnailGenerator`, and `CGImageSource`.
