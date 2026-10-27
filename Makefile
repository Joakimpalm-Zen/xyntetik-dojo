# Xyntetik Harness Supervisor. SwiftPM only; no Xcode needed.
APP := build/XyntetikHarnessSupervisor.app
BIN := .build/release/XyntetikHarnessSupervisor

.PHONY: build test app run smoke remote-setup clean

build:
	swift build -c release

test:
	swift test
	python3 -m unittest discover -s tools -p 'test_*.py'

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/tools
	cp $(BIN) $(APP)/Contents/MacOS/
	cp tools/xhs-mcp.py tools/xhs-pi.ts $(APP)/Contents/Resources/tools/
	cp packaging/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: app
	open $(APP)

# Launch proof without a human: one local pane runs `echo ok`, the bus answers, the app quits.
smoke: app
	XHS_SMOKE=1 XHS_PORT=7799 $(APP)/Contents/MacOS/XyntetikHarnessSupervisor

# Install the shim and the pi extension on a remote host: make remote-setup HOST=user@box
remote-setup:
	@test -n "$(HOST)" || (echo "usage: make remote-setup HOST=user@box" && exit 2)
	tar -C tools -cf - xhs-mcp.py xhs-pi.ts | ssh $(HOST) 'mkdir -p ~/.xhs && tar -C ~/.xhs -xf - && python3 ~/.xhs/xhs-mcp.py install'

clean:
	rm -rf build .build
