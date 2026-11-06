#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_script="$script_dir/build-openinagent.sh"
version_file="$project_dir/Tools/OpenInAgent/VERSION"
marketing_version="$(/usr/bin/sed -n 's/^MARKETING_VERSION=//p' "$version_file")"
distribution_dir="$project_dir/dist"
disk_image="$distribution_dir/OpenInAgent-$marketing_version.dmg"
staging_dir=""

cleanup() {
  [[ -z "$staging_dir" || ! -e "$staging_dir" ]] || /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT HUP INT TERM

[[ -n "$marketing_version" ]] || {
  print -u2 -- "版本文件无效：$version_file"
  exit 1
}

# Public packages must not include a personal code-signing certificate.
if [[ "${OPENINAGENT_SIGNING_IDENTITY:--}" != "-" ]]; then
  print -u2 -- "公开脱敏包仅接受 ad-hoc 签名。请清除 OPENINAGENT_SIGNING_IDENTITY 后重试。"
  exit 1
fi
built_app="$(OPENINAGENT_SIGNING_IDENTITY=- "$build_script")"
[[ -d "$built_app" ]] || {
  print -u2 -- "构建未产生 App：$built_app"
  exit 1
}

/bin/mkdir -p "$distribution_dir"
work_base="${OPENINAGENT_WORK_DIR:-${TMPDIR:-/tmp}/OpenInAgent}"
/bin/mkdir -p "$work_base"
staging_dir="$(/usr/bin/mktemp -d "$work_base/openinagent-package.XXXXXX")"
export TMPDIR="$staging_dir" TMP="$staging_dir" TEMP="$staging_dir"
/usr/bin/ditto "$built_app" "$staging_dir/OpenInAgent.app"
/usr/bin/xattr -cr "$staging_dir/OpenInAgent.app"
/bin/ln -s /Applications "$staging_dir/Applications"
cat > "$staging_dir/安装说明.txt" <<'EOF'
OpenInAgent

要求 macOS 14 或更新版本，支持 Apple Silicon 和 Intel。

1. 首次安装：将 OpenInAgent.app 拖到“应用程序”，然后打开。
   升级：替换原安装位置中的 App；通过源码脚本安装的版本位于 ~/Applications。
   请勿同时在 /Applications 和 ~/Applications 保留两份，以免重复注册 Finder 扩展。
   如旧版应用标识不同，请先停用其扩展并保留备份，再换用本独立版本。
2. 点击“管理 Finder 扩展…”并启用 OpenInAgent。
3. 在 Finder 选择“显示 → 自定工具栏…”，将 OpenInAgent 拖入工具栏。
4. 在“显示设置…”中选择需要显示的入口，选择会自动保存。

默认显示 Codex、DSH 和终端。OneDrive 目录请使用 Finder 工具栏入口。

本包使用 ad-hoc 本地签名，不包含个人签名证书，未做 Apple 公证。
首次从互联网下载并打开时，macOS 可能要求你在“隐私与安全性”中确认来源。
本项目不提供关闭 Gatekeeper 或 SIP 的安装步骤。
命令行及兼容服务可从同一版本源码运行 Scripts/install-openinagent.sh 安装；
从源码构建需要 Xcode，无需个人 Apple 开发证书。
EOF

/usr/bin/hdiutil create \
  -volname "OpenInAgent" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -ov \
  "$disk_image" >/dev/null

/usr/bin/hdiutil verify "$disk_image" >/dev/null
/usr/bin/shasum -a 256 "$disk_image"
print -- "$disk_image"
