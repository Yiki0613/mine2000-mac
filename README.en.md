<div align="center">
  <img src="Resources/AppIcon_1024.png" width="120" alt="Mine2000">
  <h1>Mine2000</h1>
  <p>A native macOS Minesweeper, rewritten from scratch in Swift 6 + AppKit</p>

  [![CI](https://github.com/Yiki0613/mine2000-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/Yiki0613/mine2000-mac/actions/workflows/ci.yml)
  ![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
  ![Swift](https://img.shields.io/badge/Swift-6.0-orange)
  ![License](https://img.shields.io/badge/license-MIT-green)

  <sub><a href="README.md">中文</a> · English</sub>
</div>

![Gameplay](docs/screenshots/gameplay.png)

---

## What is this

In 2005 a small Japanese studio called AhoSoft released **`mine2000`**, a Windows
Minesweeper with five difficulty levels, LED segment displays, a smiley reset
button and a `.m2k` high-score file. The source was never published, and it never
came to the Mac.

This project:

1. **Recovered the exact behaviour from the binary** — PE resource parsing for the
   tile atlas, disassembly for the five mine counts and the flood-fill
   neighbourhood, pixel-level measurement for every HUD coordinate.
2. **Rewrote it in Swift 6 + AppKit** — no compatibility layer, no embedded
   Windows binary, no third-party dependencies.

The result is not "a Windows program that runs on macOS". It is a native app that
happens to look exactly like the original, with every line newly written.

```bash
git clone https://github.com/Yiki0613/mine2000-mac.git
cd mine2000-mac
bash build.sh app && open .build/Mine2000.app
```

## Features

- **Five difficulties** — 8×8/10 · 16×16/40 · 30×16/99 · 48×24/256 · 64×48/777
- **Full rule set** — first-click protection, 8-neighbour flood fill, chording,
  flagging, timer freeze
- **Pixel-accurate HUD** — LED seven-segment digits, five face states, pressed-in
  feedback; timer width adapts to difficulty (3 digits on beginner, 5 otherwise)
- **`.m2k` high scores** — byte-for-byte compatible with the original format
- **Chinese UI** — menus, difficulty names and dialogs localised; the original
  Japanese strings remain in the source for cross-reference
- **Zero dependencies** — no Xcode project, no package manager, plain `swift build`

<img src="docs/screenshots/hud.png" width="100%" alt="HUD detail">

## Testing

Three layers, one command:

```bash
bash build.sh verify
```

| Layer | Count | What it checks |
|---|---:|---|
| Unit tests | **129** | Board rules, scoring, codec, menu structure, localisation |
| Logic self-test | **46** | Cross-stage flow: first click → flood fill → flag → chord → win/lose → timer freeze |
| GUI self-test | **16** | The screen actually updates: real mouse events + offscreen render + **per-pixel diff** |

The GUI layer exists for a reason. This project hit a bug where right-clicking a
cell updated the model correctly (`changed=true, flags=1`) but the view never got
`needsDisplay = true` — **logic perfect, screen unchanged**. Only rendering the
view and counting pixels catches that.

## How it was made

1. **Extract the atlas** — the original art is not a uniform grid but three
   differently-sized sub-atlases stacked vertically (16×16 tiles, 13×23 LEDs,
   26×26 faces).
2. **Read the behaviour** — disassembling the five level-initialisation functions
   yields `10 / 40 / 99 / 256 / 777` directly; following the drawing routine yields
   every HUD coordinate as an integer literal.
3. **Chase the details** — why does the beginner timer show only 3 digits? Because
   the drawing code has `cmp columns, 8; jle`. Why does pressing a cell show a
   recessed plate instead of a mine? Because that is what the original draws.
4. **Freeze it in tests** — every finding became an assertion.

See [`docs/`](docs/) for the full reverse-engineering notes (in Chinese).

## Known limitations

- **Unsigned and not notarised.** On first launch, right-click → Open, or run
  `xattr -dr com.apple.quarantine "/Applications/扫雷 2000.app"`.
- The high-score window and `.m2k` import/export dialogs have manual testing only.
- Requires macOS 14+ (swift-testing).

## License

- **Code** — [MIT](LICENSE), Copyright © 2026 Yiki
- **Original assets** — `tiles_144x81.bmp`, `logo_170x57.bmp`, `mine2000.ico` and
  `hiscore.dat` remain the property of Tomohiro Kumagai / Kazuhiro Toyama (AhoSoft)
  and are **not** covered by the MIT license. They are included solely to reproduce
  the original look and remain format-compatible. See [NOTICE](NOTICE).

No affiliation with or endorsement by the original authors is claimed. If you are a
rights holder and object to this use, please open an issue and the assets will be
removed promptly.

## Credits

- **Tomohiro Kumagai, Kazuhiro Toyama (AhoSoft)** — authors of the original
  `mine2000`. A twenty-year-old puzzle game deserves to be taken seriously once.
- The app icon is drawn from real atlas pixels, not redrawn.
