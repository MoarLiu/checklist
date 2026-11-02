#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration="${1:-debug}"
source scripts/code-signing.sh
resolve_signing_identity
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    print -u2 "Usage: $0 [debug|release]"
    exit 1
fi
compiler_options=(-Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)
if [[ "$configuration" == release ]]; then compiler_options+=(-Xswiftc -gnone); fi
swift build -c "$configuration" "${compiler_options[@]}"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/出账日.app"
mkdir -p build
[[ ! -L "$app_dir" ]] || { print -u2 "Refusing to replace a symlink: $app_dir"; exit 1; }
task_dir="$(mktemp -d "$PWD/build/.app-candidate.XXXXXX")"
candidate="$task_dir/出账日.app"
cleanup() {
    if [[ -d "$task_dir/previous.app" && ! -e "$app_dir" ]]; then
        mv "$task_dir/previous.app" "$app_dir"
    fi
    rm -rf "$task_dir"
}
trap cleanup EXIT
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
cp -X "$binary_dir/CheckList" "$candidate/Contents/MacOS/CheckList"
if [[ "$configuration" == release ]]; then
    strip -S "$candidate/Contents/MacOS/CheckList"
fi
cp -X Resources/Info.plist "$candidate/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp -X Resources/AppIcon.icns "$candidate/Contents/Resources/AppIcon.icns"
fi
cp -R -X Resources/Brand "$candidate/Contents/Resources/Brand"
sign_artifact "$candidate"
codesign --verify --deep --strict "$candidate"
if [[ -e "$app_dir" ]]; then mv "$app_dir" "$task_dir/previous.app"; fi
mv "$candidate" "$app_dir"
print -r -- "$app_dir"
