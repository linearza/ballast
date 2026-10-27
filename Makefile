APP      := Ballast
VERSION  := $(shell cat VERSION)
DIST     := dist
BUNDLE   := $(DIST)/$(APP).app
DEST     := $(HOME)/Applications/$(APP).app
REPO     := $(shell git remote get-url origin 2>/dev/null | sed -nE 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$$|\1|p')

# swift test with the Command Line Tools sometimes drops the swift-testing
# macro plugin from clean builds; passing its folder explicitly avoids that.
TESTING_PLUGINS := $(shell dirname "$$(xcrun -f swift 2>/dev/null)")/../lib/swift/host/plugins/testing

.PHONY: build test app install uninstall release icon screenshots check clean

check:
	@swift --version 2>/dev/null | grep -Eq 'Swift version ([6-9]|[1-9][0-9])\.' || { \
	  echo "Ballast needs Swift 6. Install the Command Line Tools: xcode-select --install"; exit 1; }

build: check
	swift build -c release

test: check
	swift test -Xswiftc -plugin-path -Xswiftc "$(TESTING_PLUGINS)"

app: build
	BALLAST_REPO="$(REPO)" scripts/bundle.sh "$$(swift build -c release --show-bin-path)/$(APP)" "$(BUNDLE)" "$(VERSION)"

install: app
	@osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	@mkdir -p "$(HOME)/Applications"
	rm -rf "$(DEST)"
	cp -R "$(BUNDLE)" "$(DEST)"
	@# Tell Spotlight and Launch Services about the fresh copy right away.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(DEST)" || true
	@mdimport "$(DEST)" || true
	open "$(DEST)"

uninstall:
	@osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	@if [ -d "$(DEST)" ]; then osascript -e 'tell app "Finder" to delete POSIX file "$(DEST)"' >/dev/null; fi
	rm -rf "$(HOME)/Library/Application Support/Ballast"
	@echo "Ballast removed. It's in the Trash."

release: check
	swift build -c release --arch arm64 --arch x86_64
	BALLAST_REPO="$(REPO)" scripts/bundle.sh "$$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$(APP)" "$(BUNDLE)" "$(VERSION)"
	cd $(DIST) && rm -f $(APP)-$(VERSION).zip && ditto -c -k --keepParent $(APP).app $(APP)-$(VERSION).zip
	@echo "$(DIST)/$(APP)-$(VERSION).zip"

# Renders docs/screenshots from made-up sample data; nothing on this Mac is scanned.
screenshots: app
	BALLAST_SCREENSHOTS="$(CURDIR)/docs/screenshots" "$(BUNDLE)/Contents/MacOS/$(APP)" -AppleLocale en_US -AppleLanguages '(en)'

icon:
	swift scripts/icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build $(DIST)
