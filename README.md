# PadCursor

Control your Mac with a game controller. PadCursor is a small menu bar app that turns a PS5 DualSense (or any controller macOS supports) into a mouse, scroll wheel and shortcut pad, with sticky buttons that make clicking easy from the couch.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/baygut/padcursor/main/install.sh | bash
```

Or download `PadCursor.zip` from the [latest release](https://github.com/baygut/padcursor/releases/latest), unzip it and move `PadCursor.app` to Applications. The app is signed and notarized.

Then:

1. Pair the controller in **System Settings → Bluetooth**. On a DualSense, hold **PS + Create** until the light flashes.
2. Open PadCursor. A controller icon appears in the menu bar.
3. Allow PadCursor under **System Settings → Privacy & Security → Accessibility**. It needs this to move the cursor, click and move windows.

Requires macOS 13 or later on Apple silicon.

## Default controls

| Input | Action |
|---|---|
| Left stick | Move the cursor (gentle near the center, fast at full tilt) |
| R2 / L2 | Hold for faster / more precise movement |
| Left stick flick | On a button: jump to the next button in that direction |
| Right stick | Scroll; keep holding it to scroll faster |
| Right stick double flick up / down | Jump to the top / bottom of the page |
| ✕ Cross | Left click (hold to drag, double-tap to double-click) |
| ○ Circle | Right click |
| □ Square | Delete (repeats while held) |
| △ Triangle | Pause / resume |
| L3 | Middle click |
| R3 | Spotlight (⌘Space) |
| D-pad | Arrow keys |
| L1 tap / hold + left stick | Back (⌘[) / move the window under the cursor |
| R1 tap / hold + left stick | Forward (⌘]) / resize the window under the cursor |
| Touchpad swipe left / right | Next / previous Space |
| Touchpad swipe up / down | Mission Control / App Exposé |
| Touchpad press and hold | Push to talk: holds fn (for dictation apps such as Wispr Flow) |
| Options | Magnet on / off |
| Create | Quit |

Every button can be remapped in **Settings…** from the menu bar icon: pick a built-in action, record any keyboard shortcut, or choose a key to hold for push to talk.

## Sticky buttons (magnet)

Like the cursor in a console browser:

- The cursor slows down over buttons, links, tabs, menu items and Dock icons, so it is easy to stop on them.
- When you let go of the stick, it glides to the center of the button.
- A quick flick of the stick jumps straight to the next button in that direction. Keep holding after a jump to move freely again.

PadCursor finds buttons through the macOS Accessibility API in the background, so the cursor never waits on a slow app. Stickiness, flick range and the rest are adjustable in Settings, and **Options** turns the magnet off.

## Settings

- **Buttons:** remap every button, swipe and the L1/R1 hold modes.
- **Movement:** cursor speed, R2 boost, L2 precision, dead zone, scroll speed and acceleration, magnet strength and flick range.
- **Light:** the controller's light bar color for normal, magnet off and paused, or turn it off.
- **Launch at Login** is in the menu.

## Updates

PadCursor checks this repository's latest release once a day and offers to install a newer version. **Check for Updates…** in the menu checks right away. An update is installed only when it is signed by the same developer, and the app restarts on its own; the Accessibility permission carries over.

## Build from source

```bash
git clone https://github.com/baygut/padcursor.git
cd padcursor
./scripts/build-app.sh
open dist/PadCursor.app
```

Needs the Xcode Command Line Tools (Swift 5.9 or later). Set `SIGN_IDENTITY` and `NOTARY_PROFILE` to sign and notarize a release build.

## Uninstall

Quit PadCursor from the menu bar, delete `PadCursor.app` from Applications, and remove it from the Accessibility list in System Settings.

## License

MIT. PlayStation, PS5 and DualSense are trademarks of Sony Interactive Entertainment; this project is not affiliated with Sony.
