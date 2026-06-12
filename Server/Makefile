# SwiftPM (command line) cannot compile MLX's Metal shaders — only
# Xcode/xcodebuild can (see mlx-swift README). MLX looks for `mlx.metallib`
# next to the executable at runtime, so we extract it from an xcodebuild and
# colocate it with swift-build binaries.

DD := .xcodebuild
PRODUCTS := $(DD)/Build/Products/Release
METALLIB := $(PRODUCTS)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib

.PHONY: metallib dev server demo dist clean

# One-time (and after every mlx-swift version bump): compile Metal shaders
# via xcodebuild and colocate the metallib for `swift build` / `swift run`.
metallib:
	xcodebuild -scheme KokoroServer -configuration Release \
	  -destination platform=macOS -derivedDataPath $(DD) -quiet build
	mkdir -p .build/debug .build/release
	cp $(METALLIB) .build/debug/mlx.metallib
	cp $(METALLIB) .build/release/mlx.metallib

dev:
	swift build
	@test -f .build/debug/mlx.metallib || $(MAKE) metallib

server: dev
	.build/debug/KokoroServer

demo: dev
	.build/debug/KokoroDemo

# Self-contained distributable: binary + metallib side by side.
dist:
	$(MAKE) metallib
	swift build -c release --product KokoroServer
	mkdir -p dist
	cp .build/release/KokoroServer dist/kokoro-server
	cp $(METALLIB) dist/mlx.metallib
	@echo "dist/kokoro-server ready (keep mlx.metallib next to it)"

clean:
	rm -rf .build $(DD) dist
