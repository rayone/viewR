# viewR

A native macOS image viewer built from scratch with AppKit and Swift concurrency. Opens an image, enumerates every image in the same directory, and lets you navigate with arrow keys. Designed to handle folders with 10,000+ images without stutter. I archtected the app, and a combination of Gemini Pro, Claude Opus and ChatGPT coded it. 

## Why viewR exists

Stock macOS Preview loads slowly on large folders. Third-party viewers pull in Electron or cross-platform frameworks and consume hundreds of megabytes of RAM for what should be a simple task. viewR is a single-purpose tool: view images fast, navigate instantly, stay out of the way.

## Features

- **Pure AppKit.** No SwiftUI, no Catalyst, no Electron, no web views. One native window.
- **Parallel decode pipeline.** A GCD concurrent queue decodes images ahead of your navigation on background threads. The main thread never blocks on image I/O.
- **Two-tier cache.** Screen-resolution and full-resolution variants are cached independently with an adaptive memory budget (25% of system RAM, capped at 2 GB).
- **Sliding window preload.** Up to 400 images cached (configurable), split 25% behind and 75% ahead. Navigation feels instant.
- **Natural filename sort.** `img9` comes before `img10`.
- **Appearance-aware dock icon.** Automatically switches between light and dark variants based on your system theme.
- **Open files or folders.** Select a single image (viewR finds its siblings) or open an entire directory.
- **Keyboard-driven.** Arrow keys to navigate, delete to trash, rotate, zoom, copy — all without touching the mouse.
- **Zero dependencies.** Only system frameworks: Foundation, AppKit, ImageIO, UniformTypeIdentifiers.
- **Localized.** English, German, French, Japanese, Simplified Chinese.

## Install

### Homebrew (recommended)

```bash
brew tap rayone/tap
brew trust rayone/tap
brew install --cask viewr
```

This downloads the DMG, installs `viewR.app` into `/Applications`, and removes the quarantine attribute automatically — no manual Gatekeeper bypass needed.

### Manual download

1. Go to [Releases](../../releases) and download `viewR.dmg`.
2. Open the DMG. Drag `viewR.app` into the `Applications` folder (the shortcut is inside the DMG).
3. **Important — see [Security](#security) below.**

### Build from source

See [Building from source](#building-from-source) below.

## Security

viewR is free and open-source software. It is **not signed with an Apple Developer certificate** because:

- Apple charges $99/year for a Developer ID certificate. This is a personal open-source project with no revenue.
- Code signing and notarization are mechanisms Apple uses to maintain control over what software can run on macOS. They do not inherently make software safer — they make software *approved by Apple*.
- You can read every line of source code in this repository. You can build it yourself. That is stronger assurance than any certificate.
- You can get your favorite AI to perform a code review.

### Bypassing Gatekeeper

When you first open viewR after downloading, macOS will display one of these messages:

- *"viewR.app is damaged and can't be opened"*
- *"viewR.app can't be opened because Apple cannot check it for malicious software"*

This is macOS Gatekeeper enforcing its quarantine policy on unsigned apps. To allow viewR to run:

**Method 1 — Terminal (recommended):**
```bash
xattr -cr /Applications/viewR.app
```
This removes the quarantine extended attribute that macOS applies to downloaded files. It does not modify the application.

**Method 2 — System Settings:**
1. Try to open viewR (it will be blocked).
2. Go to **System Settings > Privacy & Security**.
3. Scroll down. You will see a message about viewR being blocked.
4. Click **Open Anyway**.

**Method 3 — Right-click:**
1. Right-click (or Control-click) `viewR.app` in Finder.
2. Select **Open** from the context menu.
3. Click **Open** in the dialog that appears.

After allowing it once, macOS will not ask again.

## Building from source

### Requirements

- macOS 13.0 (Ventura) or later
- Swift toolchain via Command Line Tools

Install the toolchain if you haven't:
```bash
xcode-select --install
```

Xcode.app is **not** required. The project uses Swift Package Manager exclusively.

### Build

```bash
git clone https://github.com/rayone/viewR.git
cd viewR
bash build.sh release
```

This compiles the Swift source, assembles the `.app` bundle (binary + Info.plist + icon + localizations), strips debug symbols, and ad-hoc signs the result.

The output is `viewR.app` in the project root. Move it to `/Applications` or run it directly:

```bash
open viewR.app
```

For a debug build (faster compilation, includes debug symbols, native architecture only):
```bash
bash build.sh
```

### What build.sh does

1. Compiles all Swift sources via `swift build`.
2. Creates the `viewR.app/Contents/` directory structure.
3. Copies the binary, `Info.plist`, and localization files.
4. Generates `AppIcon.icns` from source PNGs (if present in the project root).
5. Resizes and copies light/dark icon variants for runtime dock icon switching.
6. Strips debug symbols (release mode only).
7. Clears extended attributes and ad-hoc code signs the bundle.

### Project structure

```
Sources/viewR/
  main.swift              — Entry point
  AppDelegate.swift       — App lifecycle, open panel, dock icon
  WindowController.swift  — Window, scroll view, toolbar
  ImageCanvasView.swift   — CGImage rendering, zoom
  NavigationController.swift — Mediator: index, cache, display
  ImageCache.swift        — Two-tier LRU cache, adaptive memory budget
  DecodeScheduler.swift   — GCD parallel decode, priority queue
  DirectoryScanner.swift  — Directory enumeration, natural sort, FS watcher
  HotkeyManager.swift     — Keyboard shortcut handling
  SaveQueue.swift         — Background file mutations (rotate, delete)
  InfoHUD.swift           — Image metadata overlay
  TitlebarToolbar.swift   — Titlebar controls
  SettingsWindow.swift    — Preferences
  Theme.swift             — Color palette
  ImageOpenTypes.swift    — Supported UTTypes

bundle/
  Info.plist              — App metadata, file associations
  Resources/              — Localization strings

build.sh                  — Build + assemble + sign
Package.swift             — SPM manifest
```

## Usage

```bash
# Open a specific image (viewR finds all images in the same folder):
open -a /Applications/viewR.app ~/Photos/vacation/IMG_0001.jpg

# Open a folder directly:
open -a /Applications/viewR.app ~/Photos/vacation/

# Or just launch and use File > Open:
open /Applications/viewR.app
```

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| Left / Right arrow | Previous / Next image |
| Cmd+O | Open file or folder |
| Cmd+Delete | Move to Trash |
| R / Cmd+R | Rotate clockwise |
| Touchpad Pinch | Zoom |
| Z / double-click | Toggle zoom (Fill, Native, Fit)|
| I | Toggle info overlay |
| Cmd+, | Settings |

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel (build produces a native binary for your architecture)

## License

MIT
