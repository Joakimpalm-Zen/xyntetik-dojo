# Xyntetik Harness Supervisor. SwiftPM only; no Xcode needed.
APP := build/XyntetikHarnessSupervisor.app
BIN := .build/release/XyntetikHarnessSupervisor

.PHONY: build test icon app run smoke remote-setup clean

build:
	swift build -c release

test:
	swift test
	python3 -m unittest discover -s tools -p 'test_*.py'

# The app icon: the Ensō from packaging/make-icon.swift, rendered at every size and packed into an icns.
build/AppIcon.icns: packaging/make-icon.swift
	rm -rf build/AppIcon.iconset
	swift packaging/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $@

icon: build/AppIcon.icns

app: build build/AppIcon.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/tools
	cp $(BIN) $(APP)/Contents/MacOS/
	cp tools/xhs-mcp.py tools/xhs-pi.ts $(APP)/Contents/Resources/tools/
	cp packaging/Info.plist $(APP)/Contents/Info.plist
	cp build/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(APP)

run: app
	open $(APP)

# Launch proof without a human: one local pane runs `echo ok`, the bus answers, the app quits.
# With HOST=user@box the pane runs `echo ok` on that host over ssh instead (POSIX or Windows).
smoke: app
	XHS_SMOKE=1 XHS_SMOKE_HOST=$(HOST) XHS_PORT=7799 $(APP)/Contents/MacOS/XyntetikHarnessSupervisor

# Install the shim and the pi extension on a remote host (POSIX or Windows): make remote-setup HOST=user@box
remote-setup:
	@test -n "$(HOST)" || (echo "usage: make remote-setup HOST=user@box" && exit 2)
	tools/remote-setup.sh $(HOST)

clean:
	rm -rf build .build
