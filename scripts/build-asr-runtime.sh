#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
STAGE="$ROOT/.build/asr-runtime"
REVISION=41738b58b305c08bdecf5379dccdc19a0f7c3b05
SOURCE="$STAGE/transcribe-source"
CONFIGURATION="${CONFIGURATION:-release}"
mkdir -p "$STAGE"
if [[ ! -d "$SOURCE/.git" ]]; then
    git init -q "$SOURCE"
    git -C "$SOURCE" remote add origin https://github.com/handy-computer/transcribe.cpp.git
fi
if ! git -C "$SOURCE" cat-file -e "$REVISION^{commit}" 2>/dev/null; then
    git -C "$SOURCE" fetch --depth 1 origin "$REVISION"
fi
git -C "$SOURCE" checkout --detach "$REVISION"
cmake -S "$SOURCE" -B "$STAGE/native-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_INSTALL_PREFIX="$STAGE/native-install" \
    -DCMAKE_INSTALL_RPATH=@loader_path -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DTRANSCRIBE_BUILD_SHARED=ON -DTRANSCRIBE_BUILD_TESTS=OFF \
    -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_BUILD_TOOLS=OFF \
    -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF
cmake --build "$STAGE/native-build" --target transcribe --parallel 8
cmake --install "$STAGE/native-build"
mkdir -p "$STAGE/transcribe"
for library in "$STAGE/native-install/lib/"*.dylib; do
    cp -L "$library" "$STAGE/transcribe/"
done

# Official optimized Orukeet runtime; verify before bundling.
ARCHIVE="$STAGE/orukeet-0.1.1.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 \
        https://github.com/Oruk-AI/orukeet/releases/download/v0.1.1/nemo-speech-orukeet-0.1.1-macos-arm64-metal.tar.gz \
        --output "$ARCHIVE"
fi
EXPECTED=aaf30beadcdb6ac2b6004bbe20d4a7601aa640c3f67be0e4668370a76fddcbc1
[[ "$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" == "$EXPECTED" ]] || {
    echo "error: Orukeet runtime checksum mismatch" >&2; exit 1
}
mkdir -p "$STAGE/orukeet"
tar -xzf "$ARCHIVE" -C "$STAGE/orukeet" --strip-components=1

# The native build system skips MLX's Metal shaders; without default.metallib
# every MLX model fails to load.
xcrun swift build --package-path "$ROOT/Runtime" --build-system swiftbuild --disable-sandbox -c "$CONFIGURATION"
[[ -f "$ROOT/Runtime/.build/$CONFIGURATION/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
    echo "error: MLX Metal library was not built" >&2; exit 1
}
mkdir -p "$STAGE/licenses"
install -m 644 "$SOURCE/LICENSE" "$STAGE/licenses/transcribe.cpp.txt"
install -m 644 "$SOURCE/ggml/LICENSE" "$STAGE/licenses/ggml.txt"
for dependency in "$ROOT/Runtime/.build/checkouts/"*(/); do
    for license in "$dependency/"{LICENSE,LICENSE.txt,LICENSE.md,NOTICE,NOTICE.txt}(N); do
        install -m 644 "$license" "$STAGE/licenses/${dependency:t}-${license:t}"
    done
done
echo "ASR runtime ready: $STAGE"
