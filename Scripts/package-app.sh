#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
output_dir="$project_dir/dist"
app_dir="$output_dir/MLX Desk.app"
contents_dir="$app_dir/Contents"

cd "$project_dir"
swift build -c release
"$project_dir/Scripts/generate-licenses.sh"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/bin/rm -rf "$app_dir/MLXDesk_MLXDesk.bundle"
cp ".build/release/MLXDesk" "$contents_dir/MacOS/MLXDesk"
if ! otool -l "$contents_dir/MacOS/MLXDesk" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$contents_dir/MacOS/MLXDesk"
fi
# mlx-swift's device.cpp checks Contents/MacOS/mlx.metallib (colocated with the
# executable) before anything else -- without this, native model loading throws
# "Failed to load the default metallib" the moment a model is started, even
# though the app launches and looks fine right up to that point.
metallib=$(find .build -ipath '*release*mlx-swift_Cmlx.bundle*' -name 'default.metallib' | head -1)
if [[ -n "$metallib" ]]; then
    cp "$metallib" "$contents_dir/MacOS/mlx.metallib"
else
    echo "warning: default.metallib not found in the release build -- native model loading will fail at runtime" >&2
fi
cp "PRIVACY.md" "DISTRIBUTION.md" "THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/"
for localization in "$project_dir"/Sources/MLXDesk/Resources/*.lproj; do
    [[ -d "$localization" ]] || continue
    ditto "$localization" "$contents_dir/Resources/${localization:t}"
done
sparkle_framework=$(find .build -name Sparkle.framework -type d | head -1)
if [[ -n "$sparkle_framework" ]]; then
    mkdir -p "$contents_dir/Frameworks"
    ditto "$sparkle_framework" "$contents_dir/Frameworks/Sparkle.framework"
fi
if [[ -x "$project_dir/../llmfit/target/release/llmfit" ]]; then
    cp "$project_dir/../llmfit/target/release/llmfit" "$contents_dir/Resources/llmfit"
fi

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MLXDesk</string>
<key>CFBundleIdentifier</key><string>com.local.MLXDesk</string>
<key>CFBundleName</key><string>MLX Desk</string>
<key>CFBundleDisplayName</key><string>MLX Desk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>SUFeedURL</key><string>https://example.invalid/mlx-desk/appcast.xml</string>
<key>SUPublicEDKey</key><string></string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026</string>
</dict></plist>
PLIST
if [[ -n "${UPDATE_FEED_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $UPDATE_FEED_URL" "$contents_dir/Info.plist"
fi
if [[ -n "${UPDATE_PUBLIC_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $UPDATE_PUBLIC_KEY" "$contents_dir/Info.plist"
fi

identity=${SIGNING_IDENTITY:--}
if [[ "$identity" == "-" ]]; then
    if [[ -d "$contents_dir/Frameworks/Sparkle.framework" ]]; then
        codesign --force --deep --sign - "$contents_dir/Frameworks/Sparkle.framework"
    fi
    # .metallib carries a fat-binary-style header, so codesign's deep verifier
    # treats it as a nested code object -- like Sparkle.framework above, it needs
    # its own signature or `codesign --verify --deep` fails on an otherwise-fine app.
    if [[ -f "$contents_dir/MacOS/mlx.metallib" ]]; then
        codesign --force --sign - "$contents_dir/MacOS/mlx.metallib"
    fi
    codesign --force --sign - "$app_dir"
else
    if [[ -d "$contents_dir/Frameworks/Sparkle.framework" ]]; then
        codesign --force --deep --options runtime --timestamp --sign "$identity" "$contents_dir/Frameworks/Sparkle.framework"
    fi
    if [[ -f "$contents_dir/MacOS/mlx.metallib" ]]; then
        codesign --force --options runtime --timestamp --sign "$identity" "$contents_dir/MacOS/mlx.metallib"
    fi
    codesign --force --deep --options runtime --timestamp --sign "$identity" "$app_dir"
fi
codesign --verify --deep --strict --verbose=2 "$app_dir"
ditto -c -k --keepParent "$app_dir" "$output_dir/MLX-Desk.zip"
echo "Created $app_dir and $output_dir/MLX-Desk.zip"
