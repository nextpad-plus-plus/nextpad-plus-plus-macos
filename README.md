# Nextpad++ for macOS

**The full native port of Notepad++ to macOS.** A full port of the original [Notepad++](https://notepad-plus-plus.org) codebase — not a rewrite, not an alternative, not Wine.

<p align="center">
  <a href="https://nextpad.org"><img src="https://raw.githubusercontent.com/nextpad-plus-plus/nextpad.org/main/news/npp_v1.1.1_updates/bottom-docked-panels-dark.png" alt="Notepad++ for macOS" width="1000"></a>
</p>

<p align="center">
  <a href="https://nextpad.org"><strong>Website</strong></a> ·
  <a href="https://nextpad.org/download/"><strong>Download</strong></a> ·
  <a href="https://nextpad.org/plugins/"><strong>Plugins</strong></a> ·
  <a href="https://nextpad.org/online-help/"><strong>Help</strong></a> ·
  <a href="https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos/releases"><strong>Releases</strong></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-11%2B-blue" alt="macOS 11+">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-green" alt="Apple Silicon and Intel">
  <img src="https://img.shields.io/badge/license-GPL--3.0-orange" alt="GPL-3.0 License">
  <img src="https://img.shields.io/github/v/release/nextpad-plus-plus/nextpad-plus-plus-macos" alt="Latest release">
</p>

---

## What this is

Nextpad++ for macOS brings the beloved Notepad++ Windows code editor to Apple's desktop platform as a **fully native Mac application**. This is the actual Notepad++ codebase fully ported to run natively on macOS — built from source in Objective-C++, using platform-native APIs, with no compatibility layer in between.

- ✅ **Native macOS app** — no Wine, Porting Kit, CrossOver, or emulation
- ✅ **Universal Binary** — runs natively on Apple Silicon (M1–M5) and Intel
- ✅ **Apple-notarized** — ships signed and approved for macOS Gatekeeper
- ✅ **Free and open source** — GPL-3.0, no ads, no subscriptions, no telemetry
- ✅ **Full feature parity** — syntax highlighting, plugins, macros, find-in-files, regex, split view, document map, and more

The goal is not just to make Notepad++ "run" on Mac — it's to make it feel like it *belongs* there, with native menus, shortcuts, file dialogs, dark mode, Tahoe look, full plugin ecosystem and system integration.

## Screenshots

<p align="center">
  <img src="https://nextpad.org/assets/images/screenshots/shot-nextpad-2.png" alt="Nextpad++ for macOS in Light mode" width="850">
  <br><em>Nextpad++ for macOS in Light mode</em>
</p>

<p align="center">
  <img src="https://nextpad.org/assets/images/screenshot1.png" alt="Nextpad++ for macOS in Light mode, Classic Look" width="850">
  <br><em>Nextpad++ for macOS in Light mode, Classic Look</em>
</p>

<p align="center">
  <img src="https://nextpad.org/assets/images/plugins_admin_screen.png" alt="Nextpad++ for macOS in Light mode, Classic Look and Plugin Admin" width="850">
  <br><em>Nextpad++ for macOS in Light mode and Classic Look</em>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/nextpad-plus-plus/nextpad.org/main/assets/images/github_screen1.png" alt="Notepad++ for macOS" width="1000">
  <br><em>Nextpad++ for macOS in Dark mode and Tahoe Look</em>
</p>

## Installation
### Download

Get the latest build from **[nextpad.org/download](https://nextpad.org/download/)** or directly from [GitHub Releases](https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos/releases).

The download is a signed, notarized `.dmg`:

1. Open the downloaded `.dmg`
2. Drag **Nextpad++** to your **Applications** folder
3. Launch from Applications or Spotlight
4. 
### Homebrew

You can install Nextpad++ via Homebrew:

```shell
brew install --cask nextpad-plus-plus/homebrew-nextpad/nextpad
```

Or install the tap first, step by step:

```shell
brew tap nextpad-plus-plus/nextpad
brew install --cask nextpad
```

## System Requirements

| | |
|---|---|
| **Operating System** | macOS 11 (Big Sur) or later |
| **Processor** | Apple Silicon (M1/M2/M3/M4/M5) or Intel |
| **Disk Space** | ~50 MB |
| **Memory** | 4 GB RAM minimum |

## Features

- **Syntax highlighting** for 80+ programming languages, with customizable color themes and user-defined languages
- **Plugin system** with a native Plugin Admin — [~50 plugins already ported](https://nextpad.org/plugins/), with all ~140 expected by end of April 2026
- **Scintilla-based editing component** with code folding
- **Multi-document tabbed editing**
- **Split view** — view and edit two documents side by side or two parts of the same document
- **Powerful search**: regular expressions, find-in-files, bookmark lines, incremental search
- **Macro recording** to automate repetitive editing tasks
- **Native macOS UI**: menus, dialogs, keyboard shortcuts, dark mode following system preferences
- **137-language UI** out of the box
- **Document map, character panel, clipboard history, column editor, command palette**
- **Scintilla as the editing engine** — battle-tested, high-performance, the same component powering the Windows version

## FAQ

### Is this the "real" Notepad++ for Mac?

Yes — Nextpad++ for macOS is a native port of the actual Notepad++ codebase, running directly on macOS as a first-class native application. It is not a knockoff, a Wine wrapper, or a new editor that imitates Notepad++.

### Do I need Wine, Porting Kit, or CrossOver?

No. None of those. Nextpad++ for macOS is a full native port of the original Windows codebase. It runs as a first-class native macOS application using platform APIs directly.

### Does it work on Apple Silicon?

Yes. Nextpad++ for macOS is built as a Universal Binary with native ARM64 support. It runs at full speed on all Apple Silicon Macs without Rosetta translation.

### Is it free?

Yes. Completely free and open source under the GPL-3.0 license. No ads, no subscriptions, no in-app purchases, no telemetry.

### Does it support plugins from the Windows version?

Plugins are being incrementally ported from Windows. About 50 plugins are already ported and working on macOS, with the full set (~140) expected by the end of April 2026. See the [plugin compatibility page](https://nextpad.org/plugins/) for current status.

## Building from Source

This project is written in C++ and Objective-C++ and uses CMake as its build system. Source code lives in `src/`, and platform-native UI code uses `.mm` files (Objective-C++).

Build instructions will be published as the macOS build pipeline matures. For now, the easiest way to use Nextpad++ on macOS is to download the signed `.dmg` release.

## Contributing

Bug reports, feedback, and contributions are welcome. For:
- **Bug reports and feature requests** — please open an [issue](https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos/issues)
- **Code contributions** — submit a pull request against `main`
- **Plugin porting** — see the [plugin registry](https://github.com/nextpad-plus-plus/nppPluginList)

## License

Nextpad++ for macOS is distributed under the [GNU General Public License v3.0](LICENSE), matching the license of the original Notepad++ project.

## Credits

- **Don Ho** — original author and principal developer of [Notepad++](https://notepad-plus-plus.org). For over two decades, Don has maintained Notepad++ as a free, open-source project loved by millions of developers. This macOS port is built directly upon his extraordinary work and the Notepad++ codebase, and would not exist without him.
- **Andrey Letov** — developer of the macOS port ([aletik.me](https://aletik.me), [GitHub](https://github.com/aletik)).
- **[Scintilla](https://www.scintilla.org/)** — the editing component that powers both Windows and macOS versions.

## Links

- 🌐 **Website:** https://nextpad.org
- 📥 **Download:** https://nextpad.org/download/
- 🔌 **Plugins:** https://nextpad.org/plugins/
- 📖 **Documentation:** https://nextpad.org/online-help/
- 🐛 **Issues:** https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos/issues
- 💬 **Original Notepad++ Community:** https://community.notepad-plus-plus.org/
- 💖 **Donate:** https://nextpad.org/donate/

---

<p align="center">
  <em>Made with care for Mac users who have waited 20 years for this.</em>
</p>
