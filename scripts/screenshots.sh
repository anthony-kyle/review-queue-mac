#!/bin/bash
# Captures each screen of the built app's screenshot mode, on demo data, to a PNG in the output folder. Each shot's
# process is brought to the front through System Events, since glass only shows its tints in the active app.
set -euo pipefail

app="${1:-build/ReviewQueue.app}"
out="${2:-docs/images}"
log="$(mktemp -t review-queue-screenshots)"
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -f "$log"' EXIT
mkdir -p "$out"

shots="$("$app/Contents/MacOS/ReviewQueue" --screenshots list)"
[ -n "$shots" ] || { echo "screenshot mode listed no shots" >&2; exit 1; }

for shot in $shots; do
	: >"$log"
	"$app/Contents/MacOS/ReviewQueue" --screenshots "$shot" >"$log" &
	pid=$!
	for _ in $(seq 1 40); do
		[ -s "$log" ] && break
		kill -0 "$pid" 2>/dev/null || { echo "$shot: screenshot mode exited early" >&2; exit 1; }
		osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
		sleep 0.25
	done
	id="$(head -n 1 "$log")"
	[ -n "$id" ] || { echo "$shot: no window reported" >&2; exit 1; }
	screencapture -x -o -l "$id" "$out/$shot.png"
	kill "$pid"
	wait "$pid" 2>/dev/null || true
	pid=""
	echo "$out/$shot.png"
done
