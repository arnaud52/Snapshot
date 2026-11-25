# Snapshot

A small macOS menu-bar app (in the spirit of Greenshot): press **⌘L**, select an area,
and the capture opens in an editor where you can annotate it, then copy or save it.

## Build & install

Requires the Xcode Command Line Tools (Swift 5.9+), macOS 13+.

```bash
./build.sh            # builds build/Snapshot.app
./build.sh install    # also copies it to /Applications and launches it
```

On first launch macOS asks for **Screen Recording** permission
(System Settings → Privacy & Security → Screen & System Audio Recording). Enable *Snapshot*,
then click *Restart Snapshot* in the Snapshot window.

`build.sh` signs the app with the local self-signed identity **“Snapshot Local Signing”** (login
keychain) when it exists, so the permission survives rebuilds. Without it the app is ad-hoc
signed and the permission must be re-granted after every rebuild. Diagnostics are written to
`~/Library/Logs/Snapshot.log`.

Opening the app (Finder, Spotlight, Launchpad) shows the **Snapshot settings window**: permission
status with *Open System Settings…* / *Restart Snapshot* buttons, a launch-at-login checkbox, and
capture buttons, and the **capture shortcut** (click it, press the new keys; *Reset* restores ⌘L).
It is also in the menu-bar icon → *Settings…* (⌘,).

## Capturing

| Action | How |
|---|---|
| Capture area | **⌘L** anywhere (press **Space** during selection to switch to window mode, **Esc** to cancel) |
| Capture window / full screen | Menu-bar icon |
| History | Menu-bar icon → *History…*, editor toolbar clock button, or ⌘Y |
| Annotate an existing image | Menu-bar icon → *Open Image…* or *Edit Image from Clipboard*, or drop an image on the app |

## Editor

| Tool | Key | Notes |
|---|---|---|
| Select / move | V | Drag to move, drag handles to resize, double-click text to edit, ⌫ deletes, arrows nudge (⇧ = 10pt) |
| Rectangle / Ellipse | R / E | ⇧ = square / circle |
| Arrow / Line | A / L | ⇧ snaps to 45° |
| Freehand | P | |
| Highlight | H | Marker-style (multiply), yellow by default |
| Text | T | Click to type, ⌥↩ for a new line, ↩ or Esc to finish |
| Step number | N | Numbered circles 1, 2, 3… |
| Blur / Pixelate | B / X | Pixelate is the safer option for hiding sensitive text |
| Crop | C | Drag the area to keep |

- Colors: swatches or the color well. Each tool remembers its own color. Changing color/size
  with an annotation selected applies it to that annotation.
- The blue **Copy** button (or **⌘C**) copies the edited image to the clipboard · folder button (**⇧⌘R**) shows the file in Finder · **⌘↩** copy and close · **⌘Z / ⇧⌘Z** undo/redo
- Edits are saved automatically into the screenshot's file. *File → Export As…* (⇧⌘S) saves a PNG/JPEG copy elsewhere.
- Zoom: pinch, **⌘+ / ⌘- / ⌘0 / ⌘9** (fit)
- Exports keep full Retina resolution.

## Screenshots folder & history

Every capture is saved automatically as a PNG in **`~/Pictures/Snapshot`** (change it in the
Snapshot window → *Screenshots are saved automatically to* → *Change…*). Edits are auto-saved
into the same file, so the folder always has the annotated version. Menu-bar icon →
*Open Screenshots Folder* opens it in Finder. The History
window shows them newest first: double-click to re-open in the editor, drag a thumbnail into
another app, right-click for *Copy Image*, *Show in Finder* and *Move to Trash* (⌫ also trashes).

## Shortcut

The global capture shortcut is set in the Snapshot window. A global shortcut takes priority over
the same keys in every other app (⌘L will no longer focus a browser's address bar).
If one of macOS's own screenshot shortcuts (System Settings → Keyboard → Keyboard Shortcuts →
Screenshots) uses the same keys, change it there, or both tools will start.

## License

[MIT](LICENSE)
