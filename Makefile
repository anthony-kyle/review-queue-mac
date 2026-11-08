APP := build/ReviewQueue.app
IDENTITY ?= -
BIN_DIR = $(shell swift build -c release --show-bin-path)

.PHONY: build app run install test clean

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN_DIR)/ReviewQueue $(APP)/Contents/MacOS/ReviewQueue
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign "$(IDENTITY)" $(APP)

run: app
	open $(APP)

install: app
	-pkill -x ReviewQueue && sleep 1
	rm -rf /Applications/ReviewQueue.app
	cp -R $(APP) /Applications/
	open /Applications/ReviewQueue.app

test:
	swift test

clean:
	rm -rf .build build
