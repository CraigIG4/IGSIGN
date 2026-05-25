#!/usr/bin/env bash
# IGSIGN deploy script — run from the project root on your laptop
# Usage: bash deploy/ship.sh
#
# Prerequisites:
#   1. Docker installed on the server (admin one-time step — see README below)
#   2. clawre969 in docker group on server
#   3. igsign.service installed in /etc/systemd/system/ (admin one-time step)

set -euo pipefail

DEPLOYER="clawre969"
SERVER="172.30.0.30"
APP_DIR="/home/${DEPLOYER}/apps/igsign"
BUILD_DIR="/tmp/igsign-build-$$"
TS=$(date +%Y%m%d-%H%M%S)

echo ""
echo "==> [1/6] Preparing directories on server..."
ssh "${DEPLOYER}@${SERVER}" "
  mkdir -p ${APP_DIR} && \
  mkdir -p /mnt/data/users/${DEPLOYER}/apps/igsign/data
"

echo "==> [2/6] Transferring source to server (excluding node_modules, .git, logs)..."
tar -czf - \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='.env*' \
  --exclude='tmp/cache' \
  --exclude='log/*.log' \
  --exclude='deploy' \
  -C . . \
  | ssh "${DEPLOYER}@${SERVER}" "
      mkdir -p ${BUILD_DIR} && \
      tar -xzf - -C ${BUILD_DIR}
    "

echo "==> [3/6] Building Docker image on server (~5 min first time, faster after)..."
ssh "${DEPLOYER}@${SERVER}" "
  docker build -t igsign:latest -t igsign:${TS} ${BUILD_DIR} && \
  rm -rf ${BUILD_DIR} && \
  echo 'Image built: igsign:latest'
"

echo "==> [4/6] Syncing compose config and secrets..."
scp docker-compose.prod.yml  "${DEPLOYER}@${SERVER}:${APP_DIR}/docker-compose.prod.yml"
scp .env.production           "${DEPLOYER}@${SERVER}:${APP_DIR}/.env.production"
ssh "${DEPLOYER}@${SERVER}" "chmod 600 ${APP_DIR}/.env.production"

echo "==> [5/6] Starting (or restarting) the stack..."
ssh "${DEPLOYER}@${SERVER}" "
  cd ${APP_DIR} && \
  docker compose -f docker-compose.prod.yml --env-file .env.production up -d
"

echo "==> [6/6] Waiting for web to become healthy (up to 4 minutes)..."
for i in $(seq 1 24); do
  STATUS=$(ssh "${DEPLOYER}@${SERVER}" \
    "docker inspect --format='{{.State.Health.Status}}' igsign-web-1 2>/dev/null || echo 'starting'")
  printf "    [%02d/24] %s\n" "${i}" "${STATUS}"
  [ "${STATUS}" = "healthy" ] && break
  sleep 10
done

echo ""
echo "==> Smoke test..."
HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://${SERVER}:3004/up" 2>/dev/null || echo "000")

if [ "${HTTP}" = "200" ]; then
  echo ""
  echo "✅  IGSIGN is live at https://${SERVER}:3004"
  echo "    Sign in at: https://${SERVER}:3004/sign_in"
  echo "    Health:     https://${SERVER}:3004/up"
else
  echo ""
  echo "⚠️  /up returned HTTP ${HTTP} — check logs:"
  echo "    ssh ${DEPLOYER}@${SERVER} 'cd ${APP_DIR} && docker compose -f docker-compose.prod.yml logs --tail=80'"
fi
