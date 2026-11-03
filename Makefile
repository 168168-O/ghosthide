TARGET := iphoneos
CC := xcrun -sdk $(TARGET) clang
CFLAGS := -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -fobjc-arc -O2
LDFLAGS_APP := -framework UIKit -framework Foundation -framework LocalAuthentication -framework MobileCoreServices -framework Security -framework CoreGraphics -lobjc
LDFLAGS_HELPER := -framework Foundation -framework Security -lobjc
APP := build/GhostHide.app
PAYLOAD := build/Payload

all: GhostHide.ipa GhostHide.tipa

$(APP)/GhostHide: $(wildcard src/*.m) $(wildcard src/*.h)
	@mkdir -p $(APP)
	$(CC) $(CFLAGS) $(filter-out src/helper/%,$(wildcard src/*.m)) $(LDFLAGS_APP) -o $@

$(APP)/ghosthelper: src/helper/helper_main.m
	@mkdir -p $(APP)
	$(CC) $(CFLAGS) src/helper/helper_main.m $(LDFLAGS_HELPER) -o $@

# IPA = zip，内部必须是 Payload/GhostHide.app/...
GhostHide.ipa: $(APP)/GhostHide $(APP)/ghosthelper
	cp resources/Info.plist $(APP)/Info.plist
	-cp resources/AppIcon60x60@2x.png $(APP)/
	ldid -Sresources/app-entitlements.plist $(APP)/GhostHide
	ldid -Sresources/helper-entitlements.plist $(APP)/ghosthelper
	rm -rf $(PAYLOAD) GhostHide.ipa
	mkdir -p $(PAYLOAD)
	cp -R $(APP) $(PAYLOAD)/
	(cd build && zip -qry ../GhostHide.ipa Payload)
	@echo "=== Done: GhostHide.ipa ==="

# TIPA = tar，同样要求 Payload/ 这一层
GhostHide.tipa: $(APP)/GhostHide $(APP)/ghosthelper
	cp resources/Info.plist $(APP)/Info.plist
	-cp resources/AppIcon60x60@2x.png $(APP)/
	ldid -Sresources/app-entitlements.plist $(APP)/GhostHide
	ldid -Sresources/helper-entitlements.plist $(APP)/ghosthelper
	rm -rf $(PAYLOAD) GhostHide.tipa
	mkdir -p $(PAYLOAD)
	cp -R $(APP) $(PAYLOAD)/
	(cd build && tar -cf ../GhostHide.tipa Payload)
	@echo "=== Done: GhostHide.tipa ==="

clean:
	rm -rf build GhostHide.ipa GhostHide.tipa
