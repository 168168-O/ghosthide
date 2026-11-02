TARGET := iphoneos
CC := xcrun -sdk $(TARGET) clang
CFLAGS := -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -fobjc-arc -O2
LDFLAGS_APP := -framework UIKit -framework Foundation -framework LocalAuthentication -framework MobileCoreServices -lobjc
LDFLAGS_HELPER := -framework Foundation -lobjc
APP := build/GhostHide.app

all: GhostHide.tipa

$(APP)/GhostHide: $(wildcard src/*.m) $(wildcard src/*.h)
	@mkdir -p $(APP)
	$(CC) $(CFLAGS) src/main.m src/AppDelegate.m src/RootViewController.m src/AppScanner.m src/HideManager.m src/SpawnRoot.m $(LDFLAGS_APP) -o $@

$(APP)/ghosthelper: src/helper/helper_main.m
	@mkdir -p $(APP)
	$(CC) $(CFLAGS) src/helper/helper_main.m $(LDFLAGS_HELPER) -o $@

GhostHide.tipa: $(APP)/GhostHide $(APP)/ghosthelper
	cp resources/Info.plist $(APP)/Info.plist
	ldid -Sresources/app-entitlements.plist $(APP)/GhostHide
	ldid -Sresources/helper-entitlements.plist $(APP)/ghosthelper
	@rm -f GhostHide.tipa
	(cd build && zip -qry ../GhostHide.tipa GhostHide.app)
	@echo "=== Done: GhostHide.tipa (install via TrollStore) ==="

clean:
	rm -rf build GhostHide.tipa
