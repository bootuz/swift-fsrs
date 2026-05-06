#!/usr/bin/env bash
#
# Build FSRSRustCore.xcframework from rust/fsrs-rs-swift.
#
# Output: build/FSRSRustCore.xcframework  (+ checksum.txt for release)
#
# Requires: rustup, cargo, lipo (Xcode), xcodebuild.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust/fsrs-rs-swift"
BUILD_DIR="$REPO_ROOT/build"
FRAMEWORK_NAME="FSRSRustCore"
LIB_NAME="libfsrs_rs_swift.a"
SWIFT_MODULE_NAME="FSRSRustCore"

cd "$RUST_DIR"

# 1. Targets ----------------------------------------------------------------
TARGETS=(
  "aarch64-apple-darwin"
  "x86_64-apple-darwin"
  "aarch64-apple-ios"
  "aarch64-apple-ios-sim"
  "x86_64-apple-ios"
)

echo "==> Ensuring Rust targets are installed"
for t in "${TARGETS[@]}"; do
  rustup target add "$t" >/dev/null
done

# 2. Build per-target -------------------------------------------------------
for t in "${TARGETS[@]}"; do
  echo "==> Building release for $t"
  cargo build --release --target "$t"
done

# 3. Combine slices ---------------------------------------------------------
mkdir -p "$BUILD_DIR/macos" "$BUILD_DIR/ios-sim" "$BUILD_DIR/ios-device"

echo "==> lipo: macOS universal"
lipo -create \
  "target/aarch64-apple-darwin/release/$LIB_NAME" \
  "target/x86_64-apple-darwin/release/$LIB_NAME" \
  -output "$BUILD_DIR/macos/$LIB_NAME"

echo "==> lipo: iOS sim universal"
lipo -create \
  "target/aarch64-apple-ios-sim/release/$LIB_NAME" \
  "target/x86_64-apple-ios/release/$LIB_NAME" \
  -output "$BUILD_DIR/ios-sim/$LIB_NAME"

echo "==> Copy: iOS device"
cp "target/aarch64-apple-ios/release/$LIB_NAME" "$BUILD_DIR/ios-device/$LIB_NAME"

# 4. Generate Swift bindings + headers --------------------------------------
GEN_DIR="$BUILD_DIR/generated"
rm -rf "$GEN_DIR"
mkdir -p "$GEN_DIR"

echo "==> Generating Swift bindings"
# Use the single-architecture aarch64-darwin static lib for bindgen — uniffi's
# `--library` mode parses metadata from object files via `goblin`, which
# rejects lipo'd universal archives ("Failed to extract data from archive
# member ...rcgu.o"). The Rust metadata is identical across architectures, so
# any single slice works.
cargo run --quiet --release --bin uniffi-bindgen -- \
  generate \
  --library "target/aarch64-apple-darwin/release/$LIB_NAME" \
  --language swift \
  --out-dir "$GEN_DIR"

# uniffi emits: <crate>.swift, <crate>FFI.h, <crate>FFI.modulemap
SWIFT_FILE="$GEN_DIR/fsrs_rs_swift.swift"
HEADER_FILE="$GEN_DIR/fsrs_rs_swiftFFI.h"
GEN_MODULE="$GEN_DIR/fsrs_rs_swiftFFI.modulemap"

if [[ ! -f "$SWIFT_FILE" ]] || [[ ! -f "$HEADER_FILE" ]]; then
  echo "ERROR: uniffi-bindgen did not produce expected files in $GEN_DIR" >&2
  ls -la "$GEN_DIR" >&2
  exit 1
fi

# 5. Stage Headers + module.modulemap per-slice -----------------------------
stage_headers() {
  local slice_dir="$1"
  mkdir -p "$slice_dir/Headers"
  cp "$HEADER_FILE" "$slice_dir/Headers/"
  cat > "$slice_dir/Headers/module.modulemap" <<'EOF'
framework module FSRSRustCoreFFI {
    umbrella header "fsrs_rs_swiftFFI.h"
    export *
    module * { export * }
}
EOF
}

# Wait — for static-lib xcframeworks, the modulemap & headers go alongside
# the lib (not in a framework bundle). Replace stage_headers above.
stage_static_slice() {
  local slice_dir="$1"
  rm -rf "$slice_dir/Headers"
  mkdir -p "$slice_dir/Headers"
  cp "$HEADER_FILE" "$slice_dir/Headers/"
  cat > "$slice_dir/Headers/module.modulemap" <<'EOF'
module fsrs_rs_swiftFFI {
    header "fsrs_rs_swiftFFI.h"
    export *
}
EOF
}

stage_static_slice "$BUILD_DIR/macos"
stage_static_slice "$BUILD_DIR/ios-sim"
stage_static_slice "$BUILD_DIR/ios-device"

# 6. Assemble xcframework ---------------------------------------------------
XCFRAMEWORK="$BUILD_DIR/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFRAMEWORK"

echo "==> Assembling $FRAMEWORK_NAME.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD_DIR/macos/$LIB_NAME" \
    -headers "$BUILD_DIR/macos/Headers" \
  -library "$BUILD_DIR/ios-sim/$LIB_NAME" \
    -headers "$BUILD_DIR/ios-sim/Headers" \
  -library "$BUILD_DIR/ios-device/$LIB_NAME" \
    -headers "$BUILD_DIR/ios-device/Headers" \
  -output "$XCFRAMEWORK"

# 7. Vendor the generated Swift wrapper into our source tree ----------------
SWIFT_VENDOR_DIR="$REPO_ROOT/Sources/FSRSOptimizer/Generated"
mkdir -p "$SWIFT_VENDOR_DIR"
cp "$SWIFT_FILE" "$SWIFT_VENDOR_DIR/fsrs_rs_swift.swift"

# 8. Zip + checksum (for releases) ------------------------------------------
ZIP_PATH="$BUILD_DIR/$FRAMEWORK_NAME.xcframework.zip"
rm -f "$ZIP_PATH"
( cd "$BUILD_DIR" && zip -qr "$FRAMEWORK_NAME.xcframework.zip" "$FRAMEWORK_NAME.xcframework" )

CHECKSUM=$(swift package compute-checksum "$ZIP_PATH" 2>/dev/null || shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "$CHECKSUM" > "$BUILD_DIR/checksum.txt"

echo
echo "==> Done."
echo "    xcframework: $XCFRAMEWORK"
echo "    zip:         $ZIP_PATH"
echo "    checksum:    $CHECKSUM"
echo "    swift glue:  $SWIFT_VENDOR_DIR/fsrs_rs_swift.swift"
