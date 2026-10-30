# Floe

A tiny macOS menu bar app that does a few things fast:

- **Window switcher**: ⌘Tab shows a row of large app icons with a floating card of the selected app's windows (live previews from every Space, with a window count). ⌘\` moves between windows, ⇧ or ← goes back, W closes the window, Q quits the app, Esc cancels, click to pick.
- **Quit on close**: an app quits when its last window closes (Finder and menu bar apps are left alone).
- **Maximize windows**: the green button fills the screen instead of creating a full-screen Space; click again to restore. ⌥-click for real full screen.
- **Invert mouse scrolling**: reverses wheel mice only; the trackpad keeps natural scrolling.
- **Stay awake**: keeps the display and the Mac from sleeping.
- **CPU / GPU temperatures** in the menu bar panel (Apple Silicon), read only while it's open.

Native Swift/AppKit, no dependencies, about 1300 lines.

## Build

Requires macOS 14+ and the Xcode command line tools.

```sh
make cert      # once: a local signing identity so macOS remembers permissions across rebuilds
make install   # builds, copies to /Applications and launches
```

On first launch Floe opens Settings and shows what it needs, with an **Allow** button for each:

- **Accessibility** turns on the switcher, scrolling, maximize and quit on close.
- **Screen Recording** is optional and only adds live window previews to ⌘Tab.

Each row flips to *Allowed* as soon as you grant it in System Settings. Accessibility takes effect right away; for Screen Recording, macOS may offer to reopen Floe. Without `make cert`, builds are ad-hoc signed and macOS asks again after every install.

## License

MIT
