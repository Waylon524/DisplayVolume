#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project_key="$(printf '%s' "$root" | shasum -a 256 | cut -c 1-16)"
bundle="${TMPDIR:-/private/tmp}/display-volume-$project_key/DisplayVolume.app"
binary="$bundle/Contents/MacOS/DisplayVolume"
installed="/Applications/DisplayVolume.app"
name="DisplayVolume"
identifier="io.waylon.display-volume"
mode="${1:-run}"

build() {
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$root/Sources/Info.plist" "$bundle/Contents/"
    cp "$root/LICENSE" "$root/ThirdPartyNotices.txt" "$bundle/Contents/Resources/"
    xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=13.0 -O2 -fobjc-arc \
        -Wall -Wextra -Wno-unused-parameter \
        "$root/Sources/main.m" "$root/Sources/Monitor.m" "$root/Sources/VolumeHUD.m" \
        -framework AppKit -framework Carbon -framework CoreAudio -framework CoreGraphics \
        -framework IOKit -framework ServiceManagement -framework QuartzCore -o "$binary"
    xattr -rd com.apple.FinderInfo "$bundle" 2>/dev/null || true
    codesign --force --sign - --identifier "$identifier" "$bundle"
    codesign --verify --strict "$bundle"
}

stop() {
    if pgrep -x "$name" >/dev/null; then
        pkill -TERM -x "$name"
        for attempt in {1..25}; do
            pgrep -x "$name" >/dev/null || return 0
            sleep 0.2
        done
        echo "DisplayVolume is still running." >&2
        return 1
    fi
}

case "$mode" in
    --build) build ;;
    --stop) stop ;;
    --install)
        if [ -e "$installed" ]; then
            if [ -L "$installed" ] ||
               [ "$(plutil -extract CFBundleIdentifier raw -o - "$installed/Contents/Info.plist")" != "$identifier" ]; then
                echo "$installed belongs to another application." >&2
                exit 1
            fi
        fi
        build
        stop
        ditto "$bundle" "$installed"
        codesign --verify --strict "$installed"
        open -g "$installed"
        "$installed/Contents/MacOS/$name" --enable-login
        ;;
    --probe)
        "$binary" --probe
        ;;
    run|--verify|--logs|--telemetry|--debug)
        stop
        build
        if [ "$mode" = "--debug" ]; then
            exec lldb -- "$binary"
        fi
        open -g "$bundle"
        case "$mode" in
            --verify)
                for attempt in {1..25}; do
                    if pgrep -x "$name"; then exit 0; fi
                    sleep 0.2
                done
                echo "DisplayVolume did not start." >&2
                exit 1
                ;;
            --logs|--telemetry) exec /usr/bin/log stream --style compact --predicate "subsystem == \"$identifier\"" ;;
        esac
        ;;
    *)
        echo "Usage: $0 [--build|--install|--stop|--probe|--verify|--logs|--telemetry|--debug]" >&2
        exit 2
        ;;
esac
