SCHEME     = Typist
DEST       = platform=macOS
BUILD_DIR  = $(shell xcodebuild -scheme $(SCHEME) -destination '$(DEST)' -showBuildSettings 2>/dev/null | grep -m1 'BUILD_DIR' | awk '{print $$3}')

.PHONY: generate build release install run clean

generate:
	xcodegen generate

build: generate
	xcodebuild -scheme $(SCHEME) -destination '$(DEST)' build

release: generate
	xcodebuild -scheme $(SCHEME) -configuration Release -destination '$(DEST)' build

install: release
	@rm -rf /Applications/$(SCHEME).app
	cp -R "$$(xcodebuild -scheme $(SCHEME) -configuration Release -destination '$(DEST)' -showBuildSettings 2>/dev/null | grep -m1 'BUILD_DIR' | awk '{print $$3}')/Release/$(SCHEME).app" /Applications/
	@echo "Installed to /Applications/$(SCHEME).app"

run: build
	@open "$$(xcodebuild -scheme $(SCHEME) -destination '$(DEST)' -showBuildSettings 2>/dev/null | grep -m1 'BUILD_DIR' | awk '{print $$3}')/Debug/$(SCHEME).app"

clean:
	xcodebuild -scheme $(SCHEME) -destination '$(DEST)' clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/$(SCHEME)-*
