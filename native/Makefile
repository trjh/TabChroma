# TabChroma Lights — compact native macOS menu-bar app.
# One Swift file, compiled directly with swiftc. No Xcode project, no bundle.

APP   := tabchroma-lights
SRC   := main.swift
SWIFT := swiftc
# Swift 5 mode keeps this small AppKit app free of Swift 6 strict-concurrency noise.
FLAGS := -swift-version 5 -O -framework AppKit

# Install layout (override on the command line, e.g. `make install BINDIR=~/bin`).
PREFIX        ?= $(HOME)/.local
BINDIR        ?= $(PREFIX)/bin
# make does not expand a leading ~/ — do it ourselves so `BINDIR=~/x` works.
# `override` is required so this beats a command-line `BINDIR=~/x` assignment.
override BINDIR := $(patsubst ~/%,$(HOME)/%,$(BINDIR))
LABEL         := com.tabchroma.lights
PLIST_IN      := $(LABEL).plist.in
LAUNCH_AGENTS := $(HOME)/Library/LaunchAgents
PLIST         := $(LAUNCH_AGENTS)/$(LABEL).plist

$(APP): $(SRC)
	$(SWIFT) $(FLAGS) $(SRC) -o $(APP)

.PHONY: run test install uninstall clean
run: $(APP)
	./$(APP)

test: $(APP)
	TAB_CHROMA_REGISTRY_DB="$$(mktemp -t tabchroma-native.XXXXXX.sqlite3)" TAB_CHROMA_LIGHTS_COLLAPSE=2 ./$(APP) --self-test

# Install the binary to a stable path (outside this repo working tree) and load
# a launchd LaunchAgent that runs it at login. Re-run after editing main.swift.
install: $(APP)
	mkdir -p "$(BINDIR)" "$(LAUNCH_AGENTS)"
	install -m 0755 $(APP) "$(BINDIR)/$(APP)"
	sed 's|@BIN@|$(BINDIR)/$(APP)|g' $(PLIST_IN) > "$(PLIST)"
	-launchctl unload "$(PLIST)" 2>/dev/null
	launchctl load -w "$(PLIST)"
	@echo "Installed $(APP) -> $(BINDIR) and loaded LaunchAgent $(LABEL)."

uninstall:
	-launchctl unload "$(PLIST)" 2>/dev/null
	rm -f "$(PLIST)" "$(BINDIR)/$(APP)"
	@echo "Unloaded LaunchAgent $(LABEL) and removed $(BINDIR)/$(APP)."

clean:
	rm -f $(APP)
