# Floe

A tiny macOS menu bar app that does a few things fast:

- **Window switcher**: ⌘Tab shows a row of large app icons with a floating card of the selected app's windows (live previews from every Space, with a window count). ⌘\` moves between windows, ⇧ or ← goes back, W closes the window, Q quits the app, Esc cancels, click to pick.
- **Quit on close**: an app quits when its last window closes (Finder and menu bar apps are left alone).
- **Maximize windows**: the green button fills the screen instead of creating a full-screen Space; click again to restore. ⌥-click for real full screen.
- **Invert mouse scrolling**: reverses wheel mice only; the trackpad keeps natural scrolling.
- **Stay awake**: keeps the display and the Mac from sleeping.
- **CPU / GPU temperatures** in the menu (Apple Silicon), read only while the menu is open.

Native Swift/AppKit, no dependencies, about 800 lines.

## Build

Requires macOS 14+ and the Xcode command line tools.

```sh
make install   # builds, copies to /Applications and launches
```

On first launch, grant **Accessibility** (needed for the switcher, scrolling, maximize and quit on close). On first ⌘Tab, grant **Screen Recording** for window previews (icons and counts work without it).

Ad-hoc signed builds lose their permissions on every rebuild, so `make install` resets them and macOS asks again. Pass `SIGN="Your Identity"` to keep them.

## License

MIT
