#!/usr/bin/env bash
# Empirical verification contract for neo_win_pipes — see CLAUDE.md's
# "Empirical Verification Contract" section. Builds the workspace, runs
# the full test suite, then actually launches a real binary and captures
# a screenshot of it into artifacts/verify/ — because none of that proves
# anything renders correctly, and this project has repeatedly shipped
# real bugs (a hidden 3D preview, a silently-blank egui pass, a device-
# loss crash, a torus joint with a visible seam) that only building and
# testing never caught. Exits non-zero on any failure.
#
# Usage:
#   ./scripts/verify.sh                          # launches pipes-settings, screenshots it
#   ./scripts/verify.sh --target pipes-app        # launches the fullscreen screensaver instead
#   ./scripts/verify.sh --simulate-device-loss    # forces a real GPU device loss in pipes-settings
#                                                  # and confirms Renderer::recover_if_needed
#                                                  # actually recovers (see docs/ROADMAP.md);
#                                                  # always uses pipes-settings, never pipes-app
#                                                  # (see the check below for why)
#
# If `cargo build` fails looking for a linker on Windows-on-ARM64, dot-source
# scripts/dev-shell.ps1 first (see docs/DEVELOPMENT.md).

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

TARGET="pipes-settings"
SIMULATE_DEVICE_LOSS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --target=*)
            TARGET="${1#*=}"
            shift
            ;;
        --simulate-device-loss)
            SIMULATE_DEVICE_LOSS=1
            shift
            ;;
        *)
            echo "verify.sh: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

if [ "$TARGET" != "pipes-settings" ] && [ "$TARGET" != "pipes-app" ]; then
    echo "verify.sh: --target must be 'pipes-settings' or 'pipes-app', got '$TARGET'" >&2
    exit 2
fi

ARTIFACT_DIR="$REPO_ROOT/artifacts/verify"
mkdir -p "$ARTIFACT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$ARTIFACT_DIR/${STAMP}-run.log"
APP_LOG="$ARTIFACT_DIR/${STAMP}-${TARGET}.log"
SCREENSHOT="$ARTIFACT_DIR/${STAMP}-${TARGET}.png"

# Everything after this also goes to RUN_LOG, so a failed run's full
# transcript is itself an artifact, not just whatever scrolled past.
exec > >(tee "$RUN_LOG") 2>&1

EXE_NAME="${TARGET}.exe"
EXE_PATH="$REPO_ROOT/target/debug/$EXE_NAME"

cleanup() {
    taskkill //F //IM "$EXE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    echo ""
    echo "VERIFY FAILED: $1"
    exit 1
}

echo "=== [1/4] cargo build --workspace ==="
cargo build --workspace || fail "build failed"

echo ""
echo "=== [2/4] cargo test --workspace ==="
cargo test --workspace || fail "test suite failed"

echo ""
echo "=== [3/4] Launch $TARGET and capture a screenshot ==="
cleanup
rm -f "$APP_LOG"

if [ "$SIMULATE_DEVICE_LOSS" = "1" ]; then
    if [ "$TARGET" != "pipes-settings" ]; then
        fail "--simulate-device-loss only runs against pipes-settings — pipes-app's fullscreen /s mode has a known environment-specific instability unrelated to app code (see CLAUDE.md), which would make this check flaky for the wrong reason."
    fi
    echo "Launching with PIPES_SIMULATE_DEVICE_LOSS=30 (destroys the GPU device 30 frames in)."
    PIPES_SIMULATE_DEVICE_LOSS=30 "$EXE_PATH" >"$APP_LOG" 2>&1 &
else
    "$EXE_PATH" >"$APP_LOG" 2>&1 &
fi
APP_PID=$!

# Give it time to open a window and render a few real frames before the
# screenshot — too short and PrintWindow catches an unrendered/blank
# window, which would be a false "pass" for basically no reason.
sleep 8

if ! kill -0 "$APP_PID" 2>/dev/null; then
    fail "$TARGET exited before a screenshot could be taken — see $APP_LOG"
fi

powershell -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/scripts/capture_window.ps1" \
    -ProcessName "$TARGET" -OutFile "$SCREENSHOT"
CAPTURE_STATUS=$?

if [ "$SIMULATE_DEVICE_LOSS" = "1" ]; then
    # The simulated loss + recovery needs a moment to actually happen
    # after the screenshot above (which is taken before frame 30 in a
    # typical run) — wait, then take a second, post-recovery screenshot.
    sleep 4
    RECOVERY_SCREENSHOT="$ARTIFACT_DIR/${STAMP}-${TARGET}-post-recovery.png"
    powershell -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/scripts/capture_window.ps1" \
        -ProcessName "$TARGET" -OutFile "$RECOVERY_SCREENSHOT"
fi

cleanup

if [ "$CAPTURE_STATUS" -ne 0 ] || [ ! -s "$SCREENSHOT" ]; then
    fail "screenshot capture failed (see above) — app log: $APP_LOG"
fi
echo "Screenshot: $SCREENSHOT"

echo ""
echo "=== [4/4] Check the app log for panics / unhandled crashes ==="
if grep -qi "panicked" "$APP_LOG"; then
    if [ "$SIMULATE_DEVICE_LOSS" = "1" ] && grep -qi "panic caught by a device-loss guard" "$APP_LOG"; then
        echo "Found a panic, but it's the expected device-loss-guard-caught one."
    else
        fail "an unhandled panic appears in $APP_LOG"
    fi
fi

if [ "$SIMULATE_DEVICE_LOSS" = "1" ]; then
    if ! grep -qi "GPU device recovered" "$APP_LOG"; then
        fail "PIPES_SIMULATE_DEVICE_LOSS was set but no 'GPU device recovered' line appeared in $APP_LOG — hot recovery did not actually run"
    fi
    echo "Confirmed: 'GPU device recovered' appears in the log — hot recovery ran for real."
    echo "Post-recovery screenshot: $RECOVERY_SCREENSHOT"
fi

echo ""
echo "VERIFY PASSED"
echo "Artifacts:"
echo "  - $RUN_LOG"
echo "  - $APP_LOG"
echo "  - $SCREENSHOT"
if [ "$SIMULATE_DEVICE_LOSS" = "1" ]; then
    echo "  - $RECOVERY_SCREENSHOT"
fi
