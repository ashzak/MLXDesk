#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
"$project_dir/Scripts/package-app.sh"
"$project_dir/Scripts/create-dmg.sh"
if [[ -n "${NOTARY_PROFILE:-}" && "${SIGNING_IDENTITY:--}" != "-" ]]; then
    xcrun notarytool submit "$project_dir/dist/MLX-Desk.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$project_dir/dist/MLX-Desk.dmg"
    spctl --assess --type open --context context:primary-signature -v "$project_dir/dist/MLX-Desk.dmg"
else
    echo "Preview complete. Notarization skipped because NOTARY_PROFILE and SIGNING_IDENTITY are not configured."
fi
