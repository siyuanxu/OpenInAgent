#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_script="$script_dir/build-openinagent.sh"
install_home="${OPENINAGENT_INSTALL_HOME:-$HOME}"
applications_dir="$install_home/Applications"
installed_app="$applications_dir/OpenInAgent.app"
extension_id="org.openinagent.OpenInAgent.FinderExtension"
relative_appex="Contents/PlugIns/OpenInAgentFinderExtension.appex"
services_dir="$install_home/Library/Services"
fallback_service_source="$project_dir/Scripts/CodexProjectQuickAction/在Codex中打开.workflow"
fallback_service="$services_dir/在 Codex 中打开（OpenInAgent）.workflow"
support_dir="$install_home/Library/Application Support/OpenInAgent"
cli_dir="$install_home/.local/bin"
installed_cli="$cli_dir/openinagent"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
stage_app=""
stage_service=""
stage_cli=""
old_app=""
old_fallback_service=""
old_cli=""
new_app_installed=false
new_service_installed=false
new_cli_installed=false
installation_committed=false

if [[ -e "$installed_app" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "org.openinagent.OpenInAgent" ]]; then
    print -u2 -- "目标位置存在不同标识的同名应用。请先停用其 Finder 扩展、保留备份并移开旧应用，再安装本独立版本：$installed_app"
    exit 1
  fi
fi

cleanup() {
  exit_status=$?
  trap - EXIT HUP INT TERM

  if [[ "$installation_committed" != true ]]; then
    if [[ "$new_app_installed" == true ]]; then
      /usr/bin/pluginkit -e ignore -i "$extension_id" >/dev/null 2>&1 || true
      if [[ -d "$installed_app/$relative_appex" ]]; then
        /usr/bin/pluginkit -r "$installed_app/$relative_appex" >/dev/null 2>&1 || true
      fi
    fi
    if [[ -n "$old_app" && -e "$old_app" ]]; then
      restored=true
      # The old_app path exists only after the previous installation has been
      # moved aside. Remove anything at the canonical destination before
      # restoring it, including a new App moved there just before a signal.
      [[ ! -e "$installed_app" ]] || /bin/rm -rf "$installed_app" || restored=false
      /bin/mv "$old_app" "$installed_app" || restored=false
      if [[ -d "$installed_app" ]]; then
        restored_appex="$installed_app/$relative_appex"
        "$lsregister" -f "$installed_app" >/dev/null 2>&1 || restored=false
        /usr/bin/pluginkit -a "$restored_appex" >/dev/null 2>&1 || restored=false
        /usr/bin/pluginkit -e use -i "$extension_id" >/dev/null 2>&1 || restored=false
      fi

      if [[ "$restored" == true ]]; then
        print -u2 -- "安装未完成；旧版 App 及 Finder Extension 已恢复。"
      else
        print -u2 -- "安装未完成；旧版文件已尽力恢复，但 Finder Extension 需要手动重新启用。"
      fi
    elif [[ "$new_app_installed" == true && -e "$installed_app" ]]; then
      /bin/rm -rf "$installed_app" || true
    fi

    if [[ -n "$old_fallback_service" && -e "$old_fallback_service" ]]; then
      [[ ! -e "$fallback_service" ]] || /bin/rm -rf "$fallback_service" || true
      /bin/mv "$old_fallback_service" "$fallback_service" || \
        print -u2 -- "云盘兼容服务需要手动恢复：$old_fallback_service"
    elif [[ "$new_service_installed" == true && -e "$fallback_service" ]]; then
      /bin/rm -rf "$fallback_service" || true
    fi

    if [[ -n "$old_cli" && -e "$old_cli" ]]; then
      [[ ! -e "$installed_cli" ]] || /bin/rm -f "$installed_cli" || true
      /bin/mv "$old_cli" "$installed_cli" || \
        print -u2 -- "命令行入口需要手动恢复：$old_cli"
    elif [[ "$new_cli_installed" == true && -e "$installed_cli" ]]; then
      /bin/rm -f "$installed_cli" || true
    fi
  else
    [[ -z "$old_app" || ! -e "$old_app" ]] || /bin/rm -rf "$old_app" || true
    [[ -z "$old_fallback_service" || ! -e "$old_fallback_service" ]] || \
      /bin/rm -rf "$old_fallback_service" || true
    [[ -z "$old_cli" || ! -e "$old_cli" ]] || /bin/rm -f "$old_cli" || true
  fi

  [[ -z "$stage_app" || ! -e "$stage_app" ]] || /bin/rm -rf "$stage_app"
  [[ -z "$stage_service" || ! -e "$stage_service" ]] || /bin/rm -rf "$stage_service"
  [[ -z "$stage_cli" || ! -e "$stage_cli" ]] || /bin/rm -f "$stage_cli"
  return "$exit_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

built_app="$($build_script)"
[[ -d "$built_app" ]] || { print -u2 -- "构建未产生 App：$built_app"; exit 1; }

/bin/mkdir -p "$applications_dir" "$services_dir" "$support_dir/Backups" "$cli_dir"
stage_app="$applications_dir/.OpenInAgent.install.$$"
stage_service="$services_dir/.OpenInAgent Service.install.$$"
stage_cli="$cli_dir/.openinagent.install.$$"
/usr/bin/ditto "$built_app" "$stage_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$stage_app"
/usr/bin/ditto "$fallback_service_source" "$stage_service"
/usr/bin/plutil -lint "$stage_service/Contents/Info.plist" >/dev/null
/usr/bin/ditto "$built_app/Contents/Resources/openinagent" "$stage_cli"
/bin/chmod 755 "$stage_cli"

backup_dir=""
if [[ -e "$installed_app" || -e "$fallback_service" || -e "$installed_cli" ]]; then
  backup_dir="$support_dir/Backups/$(/bin/date '+%Y%m%d-%H%M%S')"
  /bin/mkdir -p "$backup_dir"
  [[ ! -e "$installed_app" ]] || /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$installed_app" "$backup_dir/OpenInAgent.app.zip"
  [[ ! -e "$fallback_service" ]] || /usr/bin/ditto "$fallback_service" "$backup_dir/在 Codex 中打开（OpenInAgent）.workflow"
  [[ ! -e "$installed_cli" ]] || /usr/bin/ditto "$installed_cli" "$backup_dir/openinagent"
  print -- "已备份旧版：$backup_dir"
fi

/usr/bin/killall OpenInAgent >/dev/null 2>&1 || true
if [[ -e "$installed_app" ]]; then
  old_app="$applications_dir/.OpenInAgent.old.$$"
  /bin/mv "$installed_app" "$old_app"
fi

# Mark the swap before mv so EXIT cleanup also covers a signal delivered after
# the filesystem move succeeds but before the next shell assignment runs.
new_app_installed=true
if ! /bin/mv "$stage_app" "$installed_app"; then
  print -u2 -- "无法安装 OpenInAgent；正在恢复原安装。"
  exit 1
fi
stage_app=""

appex="$installed_app/$relative_appex"

if ! "$lsregister" -f "$installed_app" ||
   ! /usr/bin/pluginkit -a "$appex" ||
   ! /usr/bin/pluginkit -e use -i "$extension_id"; then
  print -u2 -- "Finder Extension 注册或启用失败；正在回滚。"
  exit 1
fi

if [[ -e "$fallback_service" ]]; then
  old_fallback_service="$services_dir/.OpenInAgent Service.old.$$"
  /bin/mv "$fallback_service" "$old_fallback_service"
fi
new_service_installed=true
if ! /bin/mv "$stage_service" "$fallback_service"; then
  print -u2 -- "云盘兼容服务安装失败；正在回滚。"
  exit 1
fi
stage_service=""

if [[ -e "$installed_cli" ]]; then
  old_cli="$cli_dir/.openinagent.old.$$"
  /bin/mv "$installed_cli" "$old_cli"
fi
new_cli_installed=true
if ! /bin/mv "$stage_cli" "$installed_cli"; then
  print -u2 -- "命令行入口安装失败；正在回滚。"
  exit 1
fi
stage_cli=""

installation_committed=true
[[ -z "$old_app" || ! -e "$old_app" ]] || /bin/rm -rf "$old_app"
[[ -z "$old_fallback_service" || ! -e "$old_fallback_service" ]] || \
  /bin/rm -rf "$old_fallback_service"
[[ -z "$old_cli" || ! -e "$old_cli" ]] || /bin/rm -f "$old_cli"

/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
/usr/bin/killall Finder >/dev/null 2>&1 || true
/usr/bin/open "$installed_app"

print -- "已安装并启用：$installed_app"
print -- "Finder Extension：$extension_id"
print -- "命令行入口：$installed_cli"
print -- "Finder 工具栏：选择“显示 → 自定工具栏…”，把 OpenInAgent 拖入工具栏。"
print -- "默认打开入口：Codex、DSH、在终端中打开。"
print -- "点击“显示设置…”可选择入口；Finder 工具栏、本地右键和 App 打开方式同步更新。"
print -- "OneDrive：使用 Finder 工具栏入口；其 File Provider 不会转发空白区域右键菜单。"
