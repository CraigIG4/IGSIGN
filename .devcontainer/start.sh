#!/bin/bash
# IGSIGN startup script — auto-runs on Codespace wake

set -e

echo '=== IGSIGN Auto-Start ==='

# 1. Start PostgreSQL
echo '>> Starting PostgreSQL...'
sudo service postgresql start 2>&1 | tail -1 || true
sleep 1

# 2. Kill any stale Rails/Puma/Redis processes from previous session
pkill -f 'rails s' 2>/dev/null || true
pkill -f 'puma' 2>/dev/null || true
# Note: do NOT kill redis-server — let puma plugin manage it

# 3. Kill any stale tmux sessions
tmux kill-server 2>/dev/null || true
sleep 1

# 4. Start Rails in a new tmux session (puma plugin handles Redis)
echo '>> Starting Rails in tmux...'
cd /workspaces/docuseal
tmux new-session -d -s igsign -n rails
tmux send-keys -t igsign:rails 'cd /workspaces/docuseal && bundle exec rails s -b 0.0.0.0 -p 3000 2>&1 | tee /tmp/rails.log' Enter

echo '=== IGSIGN starting (check /tmp/rails.log for status) ==='
