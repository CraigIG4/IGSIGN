#!/bin/bash
# IGSIGN startup script — auto-runs on every Codespace wake/start
# No manual steps needed. URL is printed to /tmp/igsign_url.txt

set -e
echo ""
echo "=== IGSIGN Auto-Start ==="

# 1. PostgreSQL
echo ">> PostgreSQL..."
sudo service postgresql start 2>&1 | tail -1 || sudo pg_ctlcluster 16 main start 2>&1 | tail -1 || true
sleep 1

# 2. Kill stale processes from previous session
echo ">> Cleaning up stale processes..."
pkill -f 'rails s'       2>/dev/null || true
pkill -f 'rails server'  2>/dev/null || true
pkill -f 'puma'          2>/dev/null || true
pkill -f 'cloudflared'   2>/dev/null || true
tmux kill-server         2>/dev/null || true
sleep 1

# 3. Ensure LibreOffice is available for Word/Excel upload conversion
if ! which soffice > /dev/null 2>&1; then
  echo ">> Installing LibreOffice (first-time setup ~1 min)..."
  sudo apt-get install -y libreoffice-writer-nogui libreoffice-core-nogui -q 2>&1 | tail -3
fi

# 4. Ensure cloudflared binary is present
if [ ! -f /tmp/cloudflared ]; then
  echo ">> Downloading cloudflared..."
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
       -o /tmp/cloudflared && chmod +x /tmp/cloudflared
fi

# 5. Install deps / migrate (idempotent)
cd /workspaces/docuseal
echo ">> Bundle install (checking)..."
bundle check || bundle install --quiet

echo ">> Migrations..."
bundle exec rails db:migrate --quiet 2>&1 | grep -v 'already' || true

# 6. Start Rails via tmux
echo ">> Starting Rails on :3000..."
tmux new-session -d -s igsign -n rails
tmux send-keys -t igsign:rails \
  'cd /workspaces/docuseal && bundle exec rails s -b 0.0.0.0 -p 3000 2>&1 | tee /tmp/rails.log' Enter

# 7. Start Cloudflare tunnel once Rails is ready
echo ">> Starting Cloudflare tunnel (waiting 18s for Rails)..."
tmux new-window -t igsign -n tunnel
tmux send-keys -t igsign:tunnel \
  'sleep 18 && /tmp/cloudflared tunnel --url http://localhost:3000 --no-autoupdate 2>&1 | tee /tmp/tunnel.log' Enter

# 8. URL watcher — writes URL to /tmp/igsign_url.txt once tunnel is up
tmux new-window -t igsign -n url-watcher
tmux send-keys -t igsign:url-watcher \
  'for i in $(seq 1 30); do URL=$(grep -o "https://[a-z0-9-]*\.trycloudflare\.com" /tmp/tunnel.log 2>/dev/null | tail -1); if [ -n "$URL" ]; then echo "$URL" > /tmp/igsign_url.txt; echo ""; echo ">>> IGSIGN LIVE: $URL <<<"; break; fi; sleep 2; done' Enter

echo ""
echo ">> IGSIGN starting. URL ready in ~20s."
echo ">> To get your URL: cat /tmp/igsign_url.txt"
echo ""
