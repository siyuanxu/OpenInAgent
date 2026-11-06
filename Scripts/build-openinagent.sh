#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
source_dir="$project_dir/Tools/OpenInAgent"
work_base="${OPENINAGENT_WORK_DIR:-${TMPDIR:-/tmp}/OpenInAgent}"
/bin/mkdir -p "$work_base"
build_root="$(/usr/bin/mktemp -d "$work_base/openinagent-build.XXXXXX")"
export TMPDIR="$build_root" TMP="$build_root" TEMP="$build_root"
app="$build_root/OpenInAgent.app"
appex="$app/Contents/PlugIns/OpenInAgentFinderExtension.appex"
module_cache="$build_root/ModuleCache"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
version_file="$source_dir/VERSION"
marketing_version="$(/usr/bin/sed -n 's/^MARKETING_VERSION=//p' "$version_file")"
build_version="$(/usr/bin/sed -n 's/^BUILD_VERSION=//p' "$version_file")"
architectures=(arm64 x86_64)

[[ -n "$marketing_version" && -n "$build_version" ]] || {
  print -u2 -- "版本文件无效：$version_file"
  exit 1
}

/bin/mkdir -p \
  "$module_cache" \
  "$app/Contents/MacOS" \
  "$app/Contents/Resources" \
  "$appex/Contents/MacOS" \
  "$appex/Contents/Resources"

/usr/bin/ditto "$source_dir/Resources/HostInfo.plist" "$app/Contents/Info.plist"
/usr/bin/ditto "$source_dir/Resources/ExtensionInfo.plist" "$appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$appex/Contents/Info.plist"
/usr/bin/ditto "$project_dir/Scripts/codex-project" "$app/Contents/Resources/openinagent"
/bin/chmod 755 "$app/Contents/Resources/openinagent"

# Build artifacts never embed this computer's File Provider paths.

icon_generator="$build_root/OpenInAgentIconGenerator"
asset_catalog="$build_root/OpenInAgent.xcassets"
iconset="$asset_catalog/AppIcon.appiconset"
xcrun swiftc \
  -sdk "$sdk" \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$module_cache/icon-generator" \
  -O \
  -framework AppKit \
  "$source_dir/Icon/IconGenerator.swift" \
  -o "$icon_generator"
"$icon_generator" "$iconset" >/dev/null
/usr/bin/ditto "$source_dir/Resources/AppIconContents.json" "$iconset/Contents.json"
xcrun actool \
  --compile "$app/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$build_root/AppIconPartial.plist" \
  "$asset_catalog" >/dev/null

host_slices=()
extension_slices=()
for architecture in "${architectures[@]}"; do
  target="$architecture-apple-macos14.0"
  host_slice="$build_root/OpenInAgent.$architecture"
  extension_slice="$build_root/OpenInAgentFinderExtension.$architecture"

  xcrun swiftc \
    -sdk "$sdk" \
    -target "$target" \
    -module-cache-path "$module_cache/$architecture" \
    -O \
    -file-prefix-map "$project_dir=/OpenInAgent" \
    -debug-prefix-map "$project_dir=/OpenInAgent" \
    -framework AppKit \
    -framework FinderSync \
    "$source_dir/Shared/AgentPreferences.swift" \
    "$source_dir/Host/AgentLauncher.swift" \
    "$source_dir/Host/DSHWorkspaceBridge.swift" \
    "$source_dir/Host/AppDelegate.swift" \
    "$source_dir/Host/ExtensionStatus.swift" \
    "$source_dir/Host/FinderDirectoryResolver.swift" \
    "$source_dir/Host/MainWindowController.swift" \
    "$source_dir/Host/SettingsWindowController.swift" \
    "$source_dir/Host/main.swift" \
    -o "$host_slice"

  xcrun swiftc \
    -sdk "$sdk" \
    -target "$target" \
    -module-cache-path "$module_cache/$architecture" \
    -O \
    -file-prefix-map "$project_dir=/OpenInAgent" \
    -debug-prefix-map "$project_dir=/OpenInAgent" \
    -parse-as-library \
    -application-extension \
    -module-name OpenInAgentFinderExtension \
    -framework AppKit \
    -framework FinderSync \
    -Xlinker -e \
    -Xlinker _NSExtensionMain \
    "$source_dir/Shared/AgentPreferences.swift" \
    "$source_dir/Extension/FinderSync.swift" \
    -o "$extension_slice"

  host_slices+=("$host_slice")
  extension_slices+=("$extension_slice")
done

/usr/bin/lipo -create "${host_slices[@]}" -output "$app/Contents/MacOS/OpenInAgent"
/usr/bin/lipo -create "${extension_slices[@]}" -output "$appex/Contents/MacOS/OpenInAgentFinderExtension"

# Default to a local ad-hoc signature: no personal certificate is embedded.
# A distributor may explicitly supply their own signing identity.
signing_identity="${OPENINAGENT_SIGNING_IDENTITY:--}"

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  --options runtime \
  --entitlements "$source_dir/Resources/Extension.entitlements" \
  "$appex"
/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  --options runtime \
  --entitlements "$source_dir/Resources/Host.entitlements" \
  "$app"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist" "$appex/Contents/Info.plist" >/dev/null
/usr/bin/lipo "$app/Contents/MacOS/OpenInAgent" -verify_arch arm64
/usr/bin/lipo "$app/Contents/MacOS/OpenInAgent" -verify_arch x86_64
/usr/bin/lipo "$appex/Contents/MacOS/OpenInAgentFinderExtension" -verify_arch arm64
/usr/bin/lipo "$appex/Contents/MacOS/OpenInAgentFinderExtension" -verify_arch x86_64

print -- "$app"
