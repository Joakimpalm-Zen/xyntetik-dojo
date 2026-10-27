# Xyntetik Harness Supervisor. SwiftPM only; no Xcode needed.
.PHONY: build test

build:
	swift build -c release

test:
	swift test
	python3 -m unittest discover -s tools -p 'test_*.py'
