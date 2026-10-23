#!/bin/zsh
# Launches the built app N times via LaunchServices, checks it survives startup,
# then quits it gracefully (so macOS does not offer to "reopen windows").
# Usage: scripts/launch-test.sh [Debug|Release] [count]
config=${1:-Debug}; count=${2:-10}
app="build/DerivedData/Build/Products/$config/Clear.app"
alive=0
for i in $(seq $count); do
  open "$app"; sleep 4
  if pgrep -f "$config/Clear.app/Contents/MacOS/Clear" >/dev/null; then alive=$((alive+1)); echo -n "ok "; else echo -n "DEAD "; fi
  osascript -e 'tell application id "com.mungyubin.clear" to quit' >/dev/null 2>&1; sleep 2
  pkill -f "$config/Clear.app/Contents/MacOS/Clear" 2>/dev/null; sleep 1
done
echo; echo "$alive/$count launches survived"
