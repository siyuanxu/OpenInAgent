#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
work_base="${OPENINAGENT_WORK_DIR:-${TMPDIR:-/tmp}/OpenInAgent}"
/bin/mkdir -p "$work_base"
test_root="$(/usr/bin/mktemp -d "$work_base/openinagent-tests.XXXXXX")"
export TMPDIR="$test_root" TMP="$test_root" TEMP="$test_root"
/bin/zsh -n "$script_dir/build-openinagent.sh" "$script_dir/install-openinagent.sh" \
  "$script_dir/package-openinagent.sh" "$script_dir/codex-project"
for file in "$project_dir"/Tools/OpenInAgent/Resources/*.plist \
            "$project_dir"/Tools/OpenInAgent/Resources/*.entitlements; do
  /usr/bin/plutil -lint "$file" >/dev/null
done
xcrun swiftc -module-cache-path "$test_root/ModuleCache" \
  "$project_dir/Tools/OpenInAgent/Shared/AgentPreferences.swift" \
  "$project_dir/Tests/AgentPreferencesTests.swift" -o "$test_root/preferences-tests"
"$test_root/preferences-tests"
