APP = Status
BUNDLE_ID = app.status.$(APP)

BUILD_PATH = $(PWD)/build
APP_PATH = "$(BUILD_PATH)/$(APP).app"
ZIP_PATH = "$(BUILD_PATH)/$(APP).zip"
WIDGET_PATH = "$(BUILD_PATH)/$(APP).app/Contents/PlugIns/WidgetsExtension.appex"

.SILENT: archive notarize sign verify prepare-dmg prepare-dSYM clean next-version check history disk smc leveldb
.PHONY: install build archive notarize sign verify prepare-dmg prepare-dSYM clean next-version check history open smc leveldb test-smc

build: test-smc clean next-version archive notarize sign verify prepare-dmg prepare-dSYM open

# Build, sign (Developer ID) and install into /Applications without notarizing.
install: clean archive
	osascript -e 'quit app "Status"' >/dev/null 2>&1 || true
	ditto $(APP_PATH) /Applications/$(APP).app
	open /Applications/$(APP).app

# --- MAIN WORKFLOW FUNCTIONS --- #

archive: test-smc clean
	osascript -e 'display notification "Exporting application archive..." with title "Build Status"'
	echo "Exporting application archive..."

	xcodebuild \
  		-scheme $(APP) \
  		-destination 'generic/platform=macOS' \
  		-configuration Release archive \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive

	echo "Application built, starting the export archive..."

	xcodebuild -exportArchive \
  		-exportOptionsPlist "$(PWD)/exportOptions.plist" \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive \
  		-exportPath $(BUILD_PATH)

	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

	echo "Project archived successfully"

notarize:
	osascript -e 'display notification "Submitting app for notarization..." with title "Build Status"'
	echo "Submitting app for notarization..."

	xcrun notarytool submit --keychain-profile "STATUS_NOTARY" --wait $(ZIP_PATH)

	echo "Status successfully notarized"

sign:
	osascript -e 'display notification "Stapling Status..." with title "Build Status"'
	echo "Going to staple an application..."

	xcrun stapler staple $(APP_PATH)
	spctl -a -t exec -vvv $(APP_PATH)

	osascript -e 'display notification "Status successfully stapled" with title "Build Status"'
	echo "Status successfully stapled"

verify:
	echo "Verifying widget extension..."

	if [ ! -d $(WIDGET_PATH) ]; then \
		echo "ERROR: widget extension is missing at $(WIDGET_PATH)"; \
		exit 1; \
	fi

	marketingVersion=$$(/usr/libexec/PlistBuddy -c "print :objects:9A141107229E721200D29793:buildSettings:MARKETING_VERSION" "$(PWD)/Status.xcodeproj/project.pbxproj") ;\
	appShort=$$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(BUILD_PATH)/$(APP).app/Contents/Info.plist") ;\
	appBuild=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(BUILD_PATH)/$(APP).app/Contents/Info.plist") ;\
	widgetShort=$$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(BUILD_PATH)/$(APP).app/Contents/PlugIns/WidgetsExtension.appex/Contents/Info.plist") ;\
	widgetBuild=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(BUILD_PATH)/$(APP).app/Contents/PlugIns/WidgetsExtension.appex/Contents/Info.plist") ;\
	echo "Declared: $$marketingVersion" ;\
	echo "App:    $$appShort ($$appBuild)" ;\
	echo "Widget: $$widgetShort ($$widgetBuild)" ;\
	if [ "$$appShort" != "$$marketingVersion" ]; then \
		echo "ERROR: built app version ($$appShort) does not match the declared MARKETING_VERSION ($$marketingVersion)." ;\
		exit 1; \
	fi ;\
	if [ "$$appShort" != "$$widgetShort" ] || [ "$$appBuild" != "$$widgetBuild" ]; then \
		echo "ERROR: widget extension version ($$widgetShort/$$widgetBuild) does not match app version ($$appShort/$$appBuild)." ;\
		echo "PluginKit keys widgets on bundle-id + version; a stale version makes the widget disappear from the picker after update." ;\
		exit 1; \
	fi

	codesign --verify --strict $(WIDGET_PATH) || { echo "ERROR: widget extension code signature is invalid"; exit 1; }

	echo "Widget extension verified successfully"

prepare-dmg:
	if [ ! -d $(PWD)/create-dmg ]; then \
	    git clone https://github.com/create-dmg/create-dmg; \
	fi

	./create-dmg/create-dmg \
	    --volname $(APP) \
	    --background "./Status/Supporting Files/background.png" \
	    --window-pos 200 120 \
	    --window-size 500 320 \
	    --icon-size 80 \
	    --icon "Status.app" 125 175 \
	    --hide-extension "Status.app" \
	    --app-drop-link 375 175 \
	    --no-internet-enable \
	    $(PWD)/$(APP).dmg \
	    $(APP_PATH)

	rm -rf ./create-dmg

prepare-dSYM:
	echo "Zipping dSYMs..."
	cd $(BUILD_PATH)/Status.xcarchive/dSYMs && zip -r $(PWD)/dSYMs.zip .
	echo "Created zip with dSYMs"

# --- HELPERS --- #

test-smc:
	python3 Kit/scripts/run-smc-tests.py

clean:
	rm -rf $(BUILD_PATH)
	if [ -a $(PWD)/dSYMs.zip ]; then rm $(PWD)/dSYMs.zip; fi;
	if [ -a $(PWD)/Status.dmg ]; then rm $(PWD)/Status.dmg; fi;

next-version:
	versionNumber=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(PWD)/Status/Supporting Files/Info.plist") ;\
	echo "Actual version is: $$versionNumber" ;\
	versionNumber=$$((versionNumber + 1)) ;\
	echo "Next version is: $$versionNumber" ;\
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$versionNumber" "$(PWD)/Status/Supporting Files/Info.plist" ;\

check:
	xcrun notarytool log 2d0045cc-8f0d-4f4c-ba6f-728895fd064a --keychain-profile "STATUS_NOTARY"

history:
	xcrun notarytool history --keychain-profile "STATUS_NOTARY"

open:
	osascript -e 'display notification "Status signed and ready for distribution" with title "Build Status"'
	echo "Opening working folder..."
	open $(PWD)

smc:
	$(MAKE) --directory=./smc
	open $(PWD)/smc

leveldb:
	if [ ! -d $(PWD)/leveldb-source ]; then \
		git clone --recurse-submodules https://github.com/google/leveldb.git leveldb-source; \
	fi
	mkdir -p $(PWD)/leveldb-source/build
	cd $(PWD)/leveldb-source/build && cmake -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" -DCMAKE_BUILD_TYPE=Release .. && cmake --build .
	cp $(PWD)/leveldb-source/build/libleveldb.a $(PWD)/Kit/lldb/libleveldb.a
	rm -rf $(PWD)/leveldb-source
