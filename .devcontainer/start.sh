#!/bin/bash
# IGSIGN startup script — auto-runs on every Codespace wake/start
# No manual steps needed. URL is always printed to /tmp/tunnel.log

set -e
echo ''
echo '╔══════════════════════════════════════════╗'
echo '║         IGSIGN Auto-Start                ║'
echo '╚══════════════════════════════════════════╝'

# ── 1. PostgreSQL ─────────────────────────────────────────────────────────────
echo '>> PostgreSQL...'
sudo service postgresql start 2>&1 | tail -1 || sudo pg_ctlcluster 16 main start 2>&1 | tail -1 || true
sleep 1

# ── 2. Kill stale processes from previous session ─────────────────────────────
echo '>> Cleaning up stale processes...'
pkill -f 'rails s'       2>/dev/null || true
pkill -f 'rails server'  2>/dev/null || true
pkill -f 'puma'          2>/dev/null || true
pkill -f 'cloudflared'   2>/dev/null || true
tmux kill-server         2>/dev/null || true
sleep 1

# ── 3. Ensure cloudflared binary is present ───────────────────────────────────
if [ ! -f /tmp/cloudflared ]; then
  echo '>> Downloading cloudflared...'
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
       -o /tmp/cloudflared && chmod +x /tmp/cloudflared
fi

# ── 4. Install deps / migrate (idempotent) ───────────────────────────────────
cd /workspaces/docuseal
echo '>> Bundle install (checking)...'
bundle check || bundle install --quiet

echo '>> Migrations...'
bundle exec rails db:migrate --quiet 2>&1 | grep -v 'already' || true

# ── 5. Start Rails via tmux ───────────────────────────────────────────────────
echo '>> Starting Rails on :3000...'
tmux new-session -d -s igsign -n rails
tmux send-keys -t igsign:rails \
  'cd /workspaces/docuseal && bundle exec rails s -b 0.0.0.0 -p 3000 2>&1 | tee /tmp/rails.log' Enter

# ── 6. Start Cloudflare tunnel once Rails is ready ───────────────────────────
echo '>> Starting Cloudflare tunnel (waiting 18s for Rails)...'
tmux new-window -t igsign -n tunnel
tmux send-keys -t igsign:tunnel \
  'sleep 18 && /tmp/cloudflared tunnel --url http://localhost:3000 --no-autoupdate 2>&1 | tee /tmp/tunnel.log' Enter

# ── 7. Print URL once tunnel is up ────────────────────────────────────────────
# Background watcher: waits for URL and writes it to a well-known file
tmux new-window -t igsign -n url-watcher
tmux send-keys -t igsign:url-watcher \
  'for i in $(seq 1 30); do URL=$(grep -o "https://[a-z0-9-]*\.trycloudflare\.com" /tmp/tunnel.log 2>/dev/null | tail -1); if [ -n "$URL" ]; then echo "$URL" > /tmp/igsign_url.txt; echo ""; echo "╔══════════════════════════════════════════════════════════╗"; echo "║  IGSIGN IS LIVE:"; echo "║  '"'"'$URL'"'"'"; echo "╚══════════════════════════════════════════════════════════╝"; break; fi; sleep 2; done' Enter

echo ''
echo '>> IGSIGN starting up. URL will be ready in ~20 seconds.'
echo '>> Run this to get your URL at any time:'
echo ">>   gh cs ssh -c expert-eureka-xrwx547g5444c977j -- 'cat /tmp/igsign_url.txt'"
echo ''
