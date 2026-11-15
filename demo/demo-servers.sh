#!/bin/zsh
# Starts three fake dev servers so PortBar has something good to show in a screen recording.
#
#   ./demo/demo-servers.sh        start them; press Ctrl-C to stop them all
#
# Each runs as `node` from its own project folder with a package.json, so PortBar labels the rows
# with a real project name. One of them (legacy-reports) ignores SIGTERM, so Stop leaves it running
# and the row offers Force Quit.
set -u
cd "$(dirname "$0")"
SERVER="$PWD/server.js"

command -v node >/dev/null || { echo "node is required (brew install node)"; exit 1; }

# name  port  extra-flag
typeset -a DEMOS=(
  "storefront-web 3000"
  "docs-site 4321"
  "legacy-reports 4000 --stubborn"
)

for demo in "${DEMOS[@]}"; do
  port=${${=demo}[2]}
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $port is already in use; free it and try again."; exit 1
  fi
done

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/portbar-demo.XXXXXX")"
typeset -a PIDS=() STUBBORN=()

cleanup() {
  trap - INT TERM EXIT
  echo; echo "Stopping demo servers..."
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  sleep 0.5
  for pid in "${PIDS[@]}"; do kill -9 "$pid" 2>/dev/null; done   # the stubborn one needs this
  rm -rf "$ROOT"
}
trap cleanup INT TERM EXIT

for demo in "${DEMOS[@]}"; do
  words=(${=demo})
  name=$words[1]; port=$words[2]; flag=${words[3]:-}
  mkdir -p "$ROOT/$name"
  printf '{ "name": "%s", "private": true, "version": "1.0.0" }\n' "$name" > "$ROOT/$name/package.json"
  # Run from the project folder (PortBar reads each process's working directory).
  (cd "$ROOT/$name" && exec node "$SERVER" "$port" "$name" $flag >/dev/null) &
  PIDS+=($!)
  [[ -n "$flag" ]] && STUBBORN+=("$name")
  echo "  :$port  $name${flag:+  (ignores SIGTERM, use Force Quit)}"
done

echo
echo "Demo servers running. Press Ctrl-C to stop them all."
wait
