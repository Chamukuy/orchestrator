#!/usr/bin/env bash
set -euo pipefail

# check-orchestrator.sh
# 用法：./ops/check-orchestrator.sh <orch_host>

ORCH_HOST=${1:-localhost}

curl -sS "http://${ORCH_HOST}:3000/api/status" | jq .
