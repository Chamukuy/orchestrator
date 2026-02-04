#!/usr/bin/env bash
set -euo pipefail

# check-replication.sh
# 用法：./ops/check-replication.sh <slave_host> <ssh_user>

SLAVE_HOST=${1:-}
SSH_USER=${2:-}

if [[ -z "$SLAVE_HOST" || -z "$SSH_USER" ]]; then
  echo "Usage: $0 <slave_host> <ssh_user>"
  exit 2
fi

ssh -o StrictHostKeyChecking=no "$SSH_USER@$SLAVE_HOST" \
  "docker compose -f ~/orchestrator_dist/docker-compose.yml exec -T mysql-slave mysql -uroot -proot -e \"SHOW SLAVE STATUS\\G\"" 
