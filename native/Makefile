# TabChroma Lights — compact native macOS menu-bar app.
# One Swift file, compiled directly with swiftc. No Xcode project, no bundle.

APP   := tabchroma-lights
SRC   := main.swift
SWIFT := swiftc
# Swift 5 mode keeps this small AppKit app free of Swift 6 strict-concurrency noise.
FLAGS := -swift-version 5 -O -framework AppKit

$(APP): $(SRC)
	$(SWIFT) $(FLAGS) $(SRC) -o $(APP)

.PHONY: run test clean
run: $(APP)
	./$(APP)

test: $(APP)
	TAB_CHROMA_REGISTRY_DB="$$(mktemp -t tabchroma-native.XXXXXX.sqlite3)" TAB_CHROMA_LIGHTS_COLLAPSE=2 ./$(APP) --self-test

clean:
	rm -f $(APP)
