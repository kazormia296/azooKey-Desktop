#!/bin/sh
set -eu

service_name="com.miyakey.grimodex.inputmethod.ConverterServer"
legacy_service_name="dev.ensan.inputmethod.azooKeyMac.ConverterServer"
package_id="com.miyakey.grimodex.inputmethod"
bundle_id="com.miyakey.grimodex.inputmethod"
target_user="${1:-${SUDO_USER:-}}"

if [ -z "${target_user}" ]; then
    target_user="$(stat -f %Su /dev/console)"
fi
if [ -z "${target_user}" ] || [ "${target_user}" = "root" ] || [ "${target_user}" = "_mbsetupuser" ]; then
    echo "Usage: sudo $0 macOS-user" >&2
    exit 2
fi

target_uid="$(id -u "${target_user}")"
target_home="$(dscl . -read "/Users/${target_user}" NFSHomeDirectory | awk '{print $2}')"
case "${target_home}" in
    /Users/*) ;;
    *)
        echo "Refusing unsafe home directory for ${target_user}: ${target_home}" >&2
        exit 1
        ;;
esac
gui_domain="gui/${target_uid}"
system_agent="/Library/LaunchAgents/${service_name}.plist"
user_agent="${target_home}/Library/LaunchAgents/${service_name}.plist"
legacy_system_agent="/Library/LaunchAgents/${legacy_service_name}.plist"
legacy_user_agent="${target_home}/Library/LaunchAgents/${legacy_service_name}.plist"
system_app="/Library/Input Methods/azooKeyMac.app"
user_app="${target_home}/Library/Input Methods/azooKeyMac.app"
consumer_handshake="${target_home}/Library/Application Support/com.miyakey.grimodex/ime/consumers/azookey-grimodex.json"

is_grimodex_app() {
    [ -f "$1/Contents/Info.plist" ] &&
        [ "$(plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null || true)" = "${bundle_id}" ]
}

agent_program() {
    plutil -extract Program raw "$1" 2>/dev/null ||
        plutil -extract ProgramArguments.0 raw "$1" 2>/dev/null || true
}

owns_system_app=false
owns_user_app=false
if is_grimodex_app "${system_app}"; then
    owns_system_app=true
fi
if is_grimodex_app "${user_app}"; then
    owns_user_app=true
fi

if [ "$(id -u)" -ne 0 ] && { [ -e "${system_agent}" ] || [ "${owns_system_app}" = true ]; }; then
    echo "System installation found. Re-run with sudo: sudo $0 ${target_user}" >&2
    exit 1
fi

legacy_system_agent_owned=false
legacy_user_agent_owned=false
if [ "${owns_system_app}" = true ] &&
    [ "$(agent_program "${legacy_system_agent}")" = "${system_app}/Contents/MacOS/ConverterServer" ]; then
    legacy_system_agent_owned=true
fi
legacy_user_program="$(agent_program "${legacy_user_agent}")"
if { [ "${owns_system_app}" = true ] &&
    [ "${legacy_user_program}" = "${system_app}/Contents/MacOS/ConverterServer" ]; } ||
    { [ "${owns_user_app}" = true ] &&
        [ "${legacy_user_program}" = "${user_app}/Contents/MacOS/ConverterServer" ]; }; then
    legacy_user_agent_owned=true
fi

launchctl bootout "${gui_domain}/${service_name}" >/dev/null 2>&1 || true
launchctl bootout "${gui_domain}" "${system_agent}" >/dev/null 2>&1 || true
launchctl bootout "${gui_domain}" "${user_agent}" >/dev/null 2>&1 || true

rm -f "${user_agent}" "${consumer_handshake}"
if [ "${owns_user_app}" = true ]; then
    rm -rf "${user_app}"
elif [ -e "${user_app}" ]; then
    echo "Leaving non-Grimodex app untouched: ${user_app}" >&2
fi

if [ "${legacy_system_agent_owned}" = true ] || [ "${legacy_user_agent_owned}" = true ]; then
    launchctl bootout "${gui_domain}/${legacy_service_name}" >/dev/null 2>&1 || true
fi
if [ "${legacy_system_agent_owned}" = true ]; then
    launchctl bootout "${gui_domain}" "${legacy_system_agent}" >/dev/null 2>&1 || true
    rm -f "${legacy_system_agent}"
elif [ -e "${legacy_system_agent}" ]; then
    echo "Leaving non-Grimodex legacy LaunchAgent untouched: ${legacy_system_agent}" >&2
fi
if [ "${legacy_user_agent_owned}" = true ]; then
    launchctl bootout "${gui_domain}" "${legacy_user_agent}" >/dev/null 2>&1 || true
    rm -f "${legacy_user_agent}"
elif [ -e "${legacy_user_agent}" ]; then
    echo "Leaving user-local upstream LaunchAgent untouched: ${legacy_user_agent}" >&2
fi

if [ "$(id -u)" -eq 0 ]; then
    rm -f "${system_agent}"
    if [ "${owns_system_app}" = true ]; then
        rm -rf "${system_app}"
    elif [ -e "${system_app}" ]; then
        echo "Leaving non-Grimodex app untouched: ${system_app}" >&2
    fi
    pkgutil --forget "${package_id}" >/dev/null 2>&1 || true
fi

echo "Uninstalled Grimodex IME for macOS for ${target_user}."
