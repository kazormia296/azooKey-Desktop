#!/bin/bash
set -euo pipefail

package_id="com.miyakey.grimodex.inputmethod"
app_path=""
output_dir=""
version=""
installer_identity=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            app_path="$2"
            shift 2
            ;;
        --output)
            output_dir="$2"
            shift 2
            ;;
        --version)
            version="$2"
            shift 2
            ;;
        --sign)
            installer_identity="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$app_path" || -z "$output_dir" ]]; then
    echo "Usage: $0 --app /path/to/azooKeyMac.app --output /path/to/output --version 0.1.0 [--sign identity]" >&2
    exit 2
fi
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$bundle_identifier" != "com.miyakey.grimodex.inputmethod" ]]; then
    echo "Unexpected input method bundle identifier: $bundle_identifier" >&2
    exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid package version: $version" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/grimodex-ime-pkg.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

stage_dir="$work_dir/stage"
scripts_dir="$work_dir/scripts"
component_pkg="$work_dir/grimodex-ime-component.pkg"
mkdir -p "$stage_dir" "$scripts_dir" "$output_dir"

ditto "$app_path" "$stage_dir/azooKeyMac.app"
install -m 755 "$repo_root/pkg-scripts/postinstall" "$scripts_dir/postinstall"
install -m 755 \
    "$repo_root/Tools/write_converter_server_launch_agent.sh" \
    "$scripts_dir/write_converter_server_launch_agent.sh"

pkgbuild \
    --root "$stage_dir" \
    --scripts "$scripts_dir" \
    --component-plist "$repo_root/pkg.plist" \
    --identifier "$package_id" \
    --version "$version" \
    --install-location "/Library/Input Methods" \
    "$component_pkg"

output_pkg="$output_dir/grimodex-ime-macos-${version}.pkg"
productbuild_arguments=(--package "$component_pkg")
if [[ -n "$installer_identity" ]]; then
    productbuild_arguments+=(--sign "$installer_identity")
fi
productbuild "${productbuild_arguments[@]}" "$output_pkg"

echo "$output_pkg"
