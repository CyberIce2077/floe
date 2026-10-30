APP := build/Floe.app
ID := io.github.cyberice2077.floe
KC := $(HOME)/Library/Keychains/floe-signing.keychain-db

# macOS ties permissions to the signature. Ad-hoc ("-") changes every build, so `make cert` once
# creates a local "Floe Developer" identity that keeps Accessibility and Screen Recording across rebuilds.
ifneq ($(wildcard $(KC)),)
SIGN ?= Floe Developer
endif
SIGN ?= -

$(APP): Sources/*.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	swiftc -O -swift-version 5 -target arm64-apple-macos14 Sources/*.swift -o $(APP)/Contents/MacOS/Floe
	cp Info.plist $(APP)/Contents/
	@[ "$(SIGN)" != "Floe Developer" ] || security unlock-keychain -p floe $(KC)
	codesign --force --sign "$(SIGN)" $(if $(filter Floe,$(SIGN)),--keychain $(KC)) $(APP)

# Permissions survive as long as the signature's requirement stays the same; reset them only when it changes.
install: $(APP)
	-pkill -x Floe
	@old=$$(codesign -d -r- /Applications/Floe.app 2>&1 | grep designated); \
	new=$$(codesign -d -r- $(APP) 2>&1 | grep designated); \
	if [ "$$old" != "$$new" ]; then \
		tccutil reset Accessibility $(ID); tccutil reset ScreenCapture $(ID); \
		defaults delete $(ID) asked.accessibility 2>/dev/null; defaults delete $(ID) asked.screenRecording 2>/dev/null; \
	fi; true
	rm -rf /Applications/Floe.app
	cp -R $(APP) /Applications/
	open /Applications/Floe.app

cert:
	@[ ! -e $(KC) ] || { echo "Signing identity already set up."; exit 0; }; \
	d=$$(mktemp -d); trap 'rm -rf $$d' EXIT; \
	openssl req -x509 -newkey rsa:2048 -nodes -keyout $$d/k.pem -out $$d/c.pem -days 3650 -subj "/CN=Floe Developer" \
		-addext "extendedKeyUsage=codeSigning" -addext "keyUsage=critical,digitalSignature" 2>/dev/null && \
	openssl pkcs12 -export -inkey $$d/k.pem -in $$d/c.pem -out $$d/f.p12 -passout pass:floe -name "Floe Developer" \
		-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 && \
	security create-keychain -p floe $(KC) && security set-keychain-settings $(KC) && \
	security import $$d/f.p12 -k $(KC) -P floe -T /usr/bin/codesign >/dev/null && \
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k floe $(KC) >/dev/null && \
	echo "Created the Floe Developer signing identity."

clean:
	rm -rf build

.PHONY: install cert clean
