#!/usr/bin/env fish

set -l root (path resolve (dirname (status filename))/..)
set -l app "$HOME/Applications/Doma.app"

set -l built_app ("$root/scripts/build-app.sh" | tail -n 1); or exit 1
rm -rf "$app"
/usr/bin/ditto "$built_app" "$app"; or exit 1

echo "$app"
