#!/usr/bin/env fish

set -l root (path resolve (dirname (status filename))/..)
set -l app "$HOME/Applications/Doma.app"
set -l contents "$app/Contents"

swift build -c release --package-path "$root"; or exit 1
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$root/.build/release/Doma" "$contents/MacOS/Doma"
cp "$root/Resources/Info.plist" "$contents/Info.plist"
chmod 755 "$contents/MacOS/Doma"
codesign --force --deep --sign - "$app"; or exit 1

echo "$app"
