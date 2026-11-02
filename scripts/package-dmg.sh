#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/code-signing.sh
resolve_signing_identity
./scripts/build.sh release

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
architecture="$(uname -m)"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Invalid app version"; exit 1; }
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || exit 1
release_dir="${CHECKLIST_RELEASE_DIR:-$PWD/release}"
mkdir -p "$release_dir"
task_dir="$(mktemp -d /private/tmp/checklist-dmg.XXXXXX)"
mount_dir="$task_dir/mounted"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then hdiutil detach "$mount_dir" -quiet || true; fi
    rm -rf "$task_dir"
}
trap cleanup EXIT
mkdir -p "$task_dir/root"
# Keep local extended attributes and live app state outside the image.
cp -R -X "build/出账日.app" "$task_dir/root/出账日.app"
ln -s /Applications "$task_dir/root/Applications"
codesign --verify --deep --strict "$task_dir/root/出账日.app"
asset="CheckList-$version-macos-$architecture.dmg"
candidate="$task_dir/$asset"
hdiutil create -volname "出账日 $version" -srcfolder "$task_dir/root" -format UDZO -ov "$candidate" -quiet
sign_artifact "$candidate"
hdiutil verify "$candidate" -quiet
mkdir -p "$mount_dir"
hdiutil attach "$candidate" -readonly -nobrowse -mountpoint "$mount_dir" -quiet
mounted=1
codesign --verify --deep --strict "$mount_dir/出账日.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mount_dir/出账日.app/Contents/Info.plist")" == "$version" ]]
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]]
cmp "$mount_dir/出账日.app/Contents/MacOS/CheckList" "build/出账日.app/Contents/MacOS/CheckList"
cmp "$mount_dir/出账日.app/Contents/Resources/AppIcon.icns" Resources/AppIcon.icns
cmp "$mount_dir/出账日.app/Contents/Resources/Brand/logo.png" Resources/Brand/logo.png
cmp "$mount_dir/出账日.app/Contents/Resources/Brand/logo.svg" Resources/Brand/logo.svg
[[ -z "$(find "$mount_dir/出账日.app" \( -name '*.store*' -o -name '*.sqlite*' -o -name '*.log' -o -name '*.p12' -o -name '.DS_Store' \) -print)" ]]
hdiutil detach "$mount_dir" -quiet
mounted=0
(
    cd "$task_dir"
    shasum -a 256 "$asset" > "$asset.sha256"
    shasum -a 256 -c "$asset.sha256"
)
# Promote the verified DMG only after all checks have passed.
mv -f "$candidate" "$release_dir/$asset"
mv -f "$candidate.sha256" "$release_dir/$asset.sha256"
print -r -- "$release_dir/$asset"
cat "$release_dir/$asset.sha256"
