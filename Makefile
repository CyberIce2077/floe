APP := build/Floe.app
ID := io.github.cyberice2077.floe
# Set SIGN to a real identity so macOS keeps permissions across rebuilds; ad-hoc ("-") loses them.
SIGN ?= -

$(APP): Sources/*.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	swiftc -O -swift-version 5 -target arm64-apple-macos14 Sources/*.swift -o $(APP)/Contents/MacOS/Floe
	cp Info.plist $(APP)/Contents/
	codesign --force --sign "$(SIGN)" $(APP)

# Ad-hoc builds get a new signature each time, so stale permission grants are reset to re-prompt.
install: $(APP)
	-pkill -x Floe
	rm -rf /Applications/Floe.app
	cp -R $(APP) /Applications/
	-[ "$(SIGN)" != "-" ] || tccutil reset Accessibility $(ID)
	-[ "$(SIGN)" != "-" ] || tccutil reset ScreenCapture $(ID)
	open /Applications/Floe.app

clean:
	rm -rf build

.PHONY: install clean
