#!/bin/bash
set -euo pipefail

retry_command='curl -fsSL https://raw.githubusercontent.com/tzador/TalkToPrompt/main/install.sh | bash'

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'TalkToPrompt requires macOS 14 or later.' >&2
    exit 1
fi

macos_version="$(sw_vers -productVersion)"
if (( ${macos_version%%.*} < 14 )); then
    echo 'TalkToPrompt requires macOS 14 or later.' >&2
    exit 1
fi

xcode_version="$(xcodebuild -version 2>/dev/null || true)"
xcode_major="$(printf '%s\n' "$xcode_version" | awk '/^Xcode / {split($2, v, "."); print v[1]; exit}')"
if [[ ! "$xcode_major" =~ ^[0-9]+$ ]] || (( xcode_major < 26 )) ||
    ! xcrun --find swift >/dev/null 2>&1 ||
    ! command -v git >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    cat >&2 <<EOF
TalkToPrompt requires full Xcode 26 or later. Standalone Command Line Tools are not sufficient.

1. Install Xcode 26 or later from the Mac App Store.
2. Open Xcode, accept its license, and finish first-time setup.
3. Select its developer tools (adjust the path if Xcode is installed elsewhere):
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
4. Retry:
   $retry_command
EOF
    exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/talktoprompt-install.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

echo 'Downloading TalkToPrompt source…'
git clone --depth 1 --branch main https://github.com/tzador/TalkToPrompt.git "$work_dir/source"

echo 'Building TalkToPrompt (this may take a few minutes)…'
# Local ad hoc signing requires no Apple account or signing certificate.
make -C "$work_dir/source" build CONFIGURATION=Release SIGNING_IDENTITY=-

app_path="$work_dir/source/build/Build/Products/Release/TalkToPrompt.app"
installed_app='/Applications/TalkToPrompt.app'
if [[ ! -d "$app_path" ]]; then
    echo 'Build did not produce TalkToPrompt.app.' >&2
    exit 1
fi

echo 'Installing to /Applications…'
pkill -x TalkToPrompt 2>/dev/null || true
if [[ -w /Applications ]] && [[ ! -e "$installed_app" || -w "$installed_app" ]]; then
    ditto "$app_path" "$installed_app"
else
    echo 'Administrator permission is needed to copy the app to /Applications.'
    sudo ditto "$app_path" "$installed_app"
fi

open "$installed_app"
echo 'TalkToPrompt is installed and launched. Follow the setup wizard to grant permissions and enter your OpenAI API key.'
