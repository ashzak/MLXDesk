#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
app="$project_dir/dist/MLX Desk.app"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
[[ -d "$app" ]] || "$project_dir/Scripts/package-app.sh"
ditto "$app" "$staging/MLX Desk.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "MLX Desk" -srcfolder "$staging" -ov -format UDZO "$project_dir/dist/MLX-Desk.dmg"
echo "Created $project_dir/dist/MLX-Desk.dmg"
