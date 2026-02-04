#!/usr/bin/env bash
set -euo pipefail

# gather-logs.sh
# 用法：./ops/gather-logs.sh <host> <ssh_user> <outdir>

HOST=${1:-}
SSH_USER=${2:-}
OUTDIR=${3:-./logs}

if [[ -z "$HOST" || -z "$SSH_USER" ]]; then
  echo "Usage: $0 <host> <ssh_user> [outdir]"
  exit 2
fi

mkdir -p "$OUTDIR"
OUTFILE="$OUTDIR/${HOST}-logs.txt"

echo "收集 $HOST 上的 Docker Compose 日志到 $OUTFILE"
ssh -o StrictHostKeyChecking=no "$SSH_USER@$HOST" "cd ~/orchestrator_dist && docker compose logs --no-color" > "$OUTFILE"
echo "完成"
