#!/bin/bash
# Foundry Dashboard — starts the live status server
# Usage: ./dashboard.sh [--no-open]

FACTORY_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$FACTORY_DIR/dashboard/server.js"
PORT=4040
URL="http://localhost:$PORT"

if [ ! -f "$SERVER" ]; then
  echo "dashboard/server.js not found"
  exit 1
fi

# Kill any existing dashboard on this port
lsof -ti:$PORT | xargs kill -9 2>/dev/null || true

echo "Starting Foundry Dashboard..."
node "$SERVER" &
SERVER_PID=$!

# Wait for server to be ready
for i in $(seq 1 10); do
  sleep 0.3
  if curl -s "$URL" > /dev/null 2>&1; then
    break
  fi
done

echo "  → $URL"
echo "  PID: $SERVER_PID"

# Open in browser unless --no-open
if [[ "$*" != *"--no-open"* ]]; then
  open "$URL" 2>/dev/null || echo "  (open $URL in your browser)"
fi

# Keep running (Ctrl-C to stop)
wait $SERVER_PID
