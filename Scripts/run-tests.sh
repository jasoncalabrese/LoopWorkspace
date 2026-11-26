#!/usr/bin/env bash
# Run the LoopKit, Loop, NightscoutService and OmnipodKit unit tests on an iOS simulator.
# Usage: Scripts/run-tests.sh [LoopKit|Loop|NightscoutService|OmnipodKit ...]   (default: all)
#
# Loop, NightscoutService and OmnipodKit tests import LoopKit and friends from other projects, so
# the LoopWorkspace scheme is built first into a shared DerivedData and every test run reuses it.
set -uo pipefail
cd "$(dirname "$0")/.."

SIM=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')
DEST="platform=iOS Simulator,name=$SIM"
LOG=build/test-logs; DD=build/DerivedData; mkdir -p "$LOG"
echo "Simulator: $SIM"

FAILED=0
# Progress while xcodebuild runs: each target as it starts building, each test suite as it
# finishes, and any failure as it happens. The full output goes to the log.
progress() {
  awk '
    match($0, /in target .[^'"'"']+. from project .[^'"'"']+./) {
      t = substr($0, RSTART + 11, RLENGTH - 11); sub(/'"'"' from project '"'"'/, " (", t); sub(/'"'"'$/, ")", t)
      if (!(t in seen)) { seen[t] = 1; print "    building " t; fflush() }
    }
    /^Test Suite .* (passed|failed) at / && !/\.xctest|All tests|Selected tests/ {
      split($0, q, "'"'"'"); r = ($0 ~ / failed at /) ? "FAILED" : "ok"; suite = q[2]
    }
    /^\t Executed [0-9]+ test/ && suite != "" { print "    " suite ": " r " (" $2 " tests)"; suite = ""; fflush() }
    /^\/[^ ]+:[0-9]+:([0-9]+:)? error: |^Test Case .* failed|Restarting after unexpected exit/ { print "    ! " $0; fflush() }
  '
}

ERRORS="^/[^ ]+:[0-9]+:([0-9]+:)? error: |^error: |^Test Case .* failed|Restarting after unexpected exit"

run() {  # name, xcodebuild action + args...
  local name=$1; shift
  local start=$SECONDS
  rm -f "$LOG/$name-retry.log"
  echo "$name"
  xcodebuild "$@" -destination "$DEST" -derivedDataPath "$DD" 2>&1 | tee "$LOG/$name.log" | progress
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    echo "$name: PASS ($((SECONDS - start))s)"
    return 0
  fi

  # Loop's Install Plugins phase doesn't wait for the plugin targets, so on a slow machine it can
  # copy a plugin before its Info.plist exists and Validate fails. Build once more: only the
  # copy reruns, now with the finished plugins.
  if [ "$1" = build ] && grep -q "did not contain an Info.plist" "$LOG/$name.log"; then
    echo "  plugins copied before they were built; building once more"
    xcodebuild "$@" -destination "$DEST" -derivedDataPath "$DD" 2>&1 | tee "$LOG/$name-retry.log" | progress
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "$name: PASS on second build ($((SECONDS - start))s)"
      return 0
    fi
  fi

  # Failed tests only (no build errors): rerun just those once, without rebuilding, so a timing
  # flake on a slow machine doesn't fail the run. Anything still failing fails. A hung or crashed
  # test host is already restarted by xcodebuild; its failed tests are retried the same way.
  local failed
  failed=$(sed -nE "s/^Test Case '-\[([^. ]+)\.([^ ]+) ([^]]+)\]' failed.*/\1\/\2\/\3/p" "$LOG/$name.log" | sort -u)
  local other
  other=$(grep -E "^/[^ ]+:[0-9]+:([0-9]+:)? error: " "$LOG/$name.log" | grep -v " error: -\[")
  if [ "$1" = test ] && [ -n "$failed" ] && [ -z "$other" ]; then
    echo "  retrying once: $(echo $failed)"
    local only=(); for t in $failed; do only+=(-only-testing:"$t"); done
    shift
    xcodebuild test-without-building "$@" "${only[@]}" -destination "$DEST" -derivedDataPath "$DD" 2>&1 | tee "$LOG/$name-retry.log" | progress
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "$name: PASS on retry ($((SECONDS - start))s; flaky: $(echo $failed))"
      return 0
    fi
  fi

  echo "$name: FAIL ($((SECONDS - start))s, $LOG/$name.log)"
  grep -hE "$ERRORS" "$LOG/$name.log" "$LOG/$name-retry.log" 2>/dev/null | sort -u | head -40
  FAILED=1
  return 1
}

TARGETS=${*:-LoopKit Loop NightscoutService OmnipodKit}
case " $TARGETS " in *" Loop "*|*" NightscoutService "*|*" OmnipodKit "*)
  run Build build -workspace LoopWorkspace.xcworkspace -scheme LoopWorkspace || exit 1 ;;
esac
for t in $TARGETS; do
  case $t in
    LoopKit)           run LoopKit           test -project LoopKit/LoopKit.xcodeproj -scheme Shared ;;
    Loop)              run LoopTests         test -workspace LoopWorkspace.xcworkspace -scheme LoopTests ;;
    NightscoutService) run NightscoutService test -project NightscoutService/NightscoutService.xcodeproj -scheme Shared ;;
    OmnipodKit)        run OmnipodKit        test -workspace LoopWorkspace.xcworkspace -scheme OmniTests ;;
    *) echo "unknown: $t"; FAILED=1 ;;
  esac
done
exit $FAILED
