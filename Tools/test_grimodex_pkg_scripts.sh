#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/grimodex-pkg-scripts.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

runtime_app_path="/Library/Input Methods/azooKeyMac.app"
runtime_server_path="${runtime_app_path}/Contents/MacOS/ConverterServer"
bundle_id="com.miyakey.grimodex.inputmethod"
legacy_bundle_id="dev.ensan.inputmethod.azooKeyMac"
legacy_service_name="dev.ensan.inputmethod.azooKeyMac.ConverterServer"
service_name="com.miyakey.grimodex.inputmethod.ConverterServer"

scripts_dir="${sandbox}/scripts"
mkdir -p "${scripts_dir}"
install -m 755 "${repo_root}/pkg-scripts/preinstall" "${scripts_dir}/preinstall"
install -m 755 "${repo_root}/pkg-scripts/postinstall" "${scripts_dir}/postinstall"
install -m 755 \
    "${repo_root}/Tools/write_converter_server_launch_agent.sh" \
    "${scripts_dir}/write_converter_server_launch_agent.sh"

write_bundle_id() {
    local path="$1"
    local identifier="$2"
    mkdir -p "$(dirname "${path}")"
    PLIST_PATH="${path}" BUNDLE_ID="${identifier}" python3 - <<'PY'
import os
import plistlib

with open(os.environ["PLIST_PATH"], "wb") as target:
    plistlib.dump({"CFBundleIdentifier": os.environ["BUNDLE_ID"]}, target)
PY
}

write_launch_agent_with_program() {
    local path="$1"
    local program="$2"
    local argument_zero="$3"
    mkdir -p "$(dirname "${path}")"
    PLIST_PATH="${path}" \
    PROGRAM="${program}" \
    ARGUMENT_ZERO="${argument_zero}" \
    python3 - <<'PY'
import os
import plistlib

with open(os.environ["PLIST_PATH"], "wb") as target:
    plistlib.dump(
        {
            "Label": "dev.ensan.inputmethod.azooKeyMac.ConverterServer",
            "Program": os.environ["PROGRAM"],
            "ProgramArguments": [os.environ["ARGUMENT_ZERO"]],
        },
        target,
    )
PY
}

make_app() {
    local target_volume="$1"
    local identifier="$2"
    local app_path="${target_volume}${runtime_app_path}"
    mkdir -p "${app_path}/Contents/MacOS"
    write_bundle_id "${app_path}/Contents/Info.plist" "${identifier}"
    touch "${app_path}/Contents/MacOS/ConverterServer"
    chmod 755 "${app_path}/Contents/MacOS/ConverterServer"
}

legacy_volume="${sandbox}/legacy-volume"
make_app "${legacy_volume}" "${legacy_bundle_id}"
"${scripts_dir}/preinstall" ignored ignored "${legacy_volume}"
test -x "${legacy_volume}${runtime_server_path}"

upgrade_volume="${sandbox}/upgrade-volume"
make_app "${upgrade_volume}" "${bundle_id}"
"${scripts_dir}/preinstall" ignored ignored "${upgrade_volume}"
test -x "${upgrade_volume}${runtime_server_path}"

unrelated_volume="${sandbox}/unrelated-volume"
make_app "${unrelated_volume}" "com.example.unrelated-input-method"
if "${scripts_dir}/preinstall" ignored ignored "${unrelated_volume}" 2>/dev/null; then
    echo "preinstall replaced an unrelated input method" >&2
    exit 1
fi
test -x "${unrelated_volume}${runtime_server_path}"

postinstall_volume="${sandbox}/postinstall-volume"
make_app "${postinstall_volume}" "${bundle_id}"
system_agent_dir="${postinstall_volume}/Library/LaunchAgents"
alice_agent_dir="${postinstall_volume}/Users/alice/Library/LaunchAgents"
bob_agent_dir="${postinstall_volume}/Users/bob/Library/LaunchAgents"
carol_agent_dir="${postinstall_volume}/Users/carol/Library/LaunchAgents"
dave_agent_dir="${postinstall_volume}/Users/dave/Library/LaunchAgents"
mkdir -p \
    "${system_agent_dir}" \
    "${alice_agent_dir}" \
    "${bob_agent_dir}" \
    "${carol_agent_dir}" \
    "${dave_agent_dir}"
"${scripts_dir}/write_converter_server_launch_agent.sh" \
    "${system_agent_dir}/${legacy_service_name}.plist" \
    "${runtime_server_path}" \
    "${legacy_service_name}"
"${scripts_dir}/write_converter_server_launch_agent.sh" \
    "${alice_agent_dir}/${legacy_service_name}.plist" \
    "${runtime_server_path}" \
    "${legacy_service_name}"
"${scripts_dir}/write_converter_server_launch_agent.sh" \
    "${bob_agent_dir}/${legacy_service_name}.plist" \
    "/Users/bob/Library/Input Methods/azooKeyMac.app/Contents/MacOS/ConverterServer" \
    "${legacy_service_name}"
write_launch_agent_with_program \
    "${carol_agent_dir}/${legacy_service_name}.plist" \
    "/Users/carol/Library/Input Methods/azooKeyMac.app/Contents/MacOS/ConverterServer" \
    "${runtime_server_path}"
write_launch_agent_with_program \
    "${dave_agent_dir}/${legacy_service_name}.plist" \
    "${runtime_server_path}" \
    "/Users/dave/Library/Input Methods/azooKeyMac.app/Contents/MacOS/ConverterServer"

"${scripts_dir}/postinstall" ignored ignored "${postinstall_volume}"
test -f "${system_agent_dir}/${service_name}.plist"
test ! -e "${system_agent_dir}/${legacy_service_name}.plist"
test ! -e "${alice_agent_dir}/${legacy_service_name}.plist"
test -f "${bob_agent_dir}/${legacy_service_name}.plist"
test -f "${carol_agent_dir}/${legacy_service_name}.plist"
test ! -e "${dave_agent_dir}/${legacy_service_name}.plist"
test "$(
    plutil -extract ProgramArguments.0 raw \
        "${system_agent_dir}/${service_name}.plist"
)" = "${runtime_server_path}"

echo "Grimodex package script contracts passed."
