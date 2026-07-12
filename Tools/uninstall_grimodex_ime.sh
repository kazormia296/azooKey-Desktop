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

owns_system_app=false
owns_user_app=false
if is_grimodex_app "${system_app}"; then
    owns_system_app=true
fi
if is_grimodex_app "${user_app}"; then
    owns_user_app=true
fi

launchctl bootout "${gui_domain}/${service_name}" >/dev/null 2>&1 || true
launchctl bootout "${gui_domain}" "${system_agent}" >/dev/null 2>&1 || true
launchctl bootout "${gui_domain}" "${user_agent}" >/dev/null 2>&1 || true

if [ "$(id -u)" -ne 0 ] && { [ -e "${system_agent}" ] || [ "${owns_system_app}" = true ]; }; then
    echo "System installation found. Re-run with sudo: sudo $0 ${target_user}" >&2
    exit 1
fi

rm -f "${user_agent}" "${consumer_handshake}"
if [ "${owns_user_app}" = true ]; then
    rm -rf "${user_app}"
elif [ -e "${user_app}" ]; then
    echo "Leaving non-Grimodex app untouched: ${user_app}" >&2
fi

if [ "${owns_system_app}" = true ] || [ "${owns_user_app}" = true ]; then
    launchctl bootout "${gui_domain}/${legacy_service_name}" >/dev/null 2>&1 || true
    launchctl bootout "${gui_domain}" "${legacy_system_agent}" >/dev/null 2>&1 || true
    launchctl bootout "${gui_domain}" "${legacy_user_agent}" >/dev/null 2>&1 || true
    if [ "$(id -u)" -eq 0 ]; then
        rm -f "${legacy_system_agent}"
    fi
    rm -f "${legacy_user_agent}"
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
