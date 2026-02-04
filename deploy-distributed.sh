#!/usr/bin/env bash
set -euo pipefail

# deploy-distributed.sh
# 在三台主机上分别部署 MySQL master / slave1 / slave2，并可选在 master 部署 Orchestrator
# 用法：
#   ./deploy-distributed.sh <master_ip> <slave1_ip> <slave2_ip> <ssh_user> [--orch-on-master]

# ============================================================================
# 日志与颜色
# ============================================================================
LOG_FILE="${LOG_FILE:-./_deploy_$(date +%Y%m%d_%H%M%S).log}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $msg" | tee -a "$LOG_FILE"
  echo -e "${BLUE}[INFO]${NC} $msg"
}

log_success() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $msg" | tee -a "$LOG_FILE"
  echo -e "${GREEN}[SUCCESS]${NC} $msg"
}

log_warn() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $msg" | tee -a "$LOG_FILE"
  echo -e "${YELLOW}[WARN]${NC} $msg"
}

log_error() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $msg" | tee -a "$LOG_FILE"
  echo -e "${RED}[ERROR]${NC} $msg"
}

# ============================================================================
# 参数解析与验证
# ============================================================================
MASTER_IP=${1:-}
SLAVE1_IP=${2:-}
SLAVE2_IP=${3:-}
SSH_USER=${4:-}
ORCH_ON_MASTER=false
if [[ "${5:-}" == "--orch-on-master" ]]; then
  ORCH_ON_MASTER=true
fi

REMOTE_DIR=~/orchestrator_dist
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 验证 IP 地址格式
validate_ip() {
  local ip=$1
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || [[ $ip =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    return 0
  else
    return 1
  fi
}

# 验证必需文件
check_required_files() {
  local files=(
    "$SCRIPT_DIR/dist/docker-compose.master.yml"
    "$SCRIPT_DIR/dist/docker-compose.slave.yml"
    "$SCRIPT_DIR/conf/orchestrator-master-slave.conf.json"
  )
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      log_error "找不到必需文件: $f"
      return 1
    fi
  done
  log_success "所有必需文件检查通过"
  return 0
}

# 显示帮助
show_usage() {
  cat << 'EOF'
使用方法：
  ./deploy-distributed.sh <master_ip> <slave1_ip> <slave2_ip> <ssh_user> [--orch-on-master]

参数说明：
  <master_ip>      Master 节点 IP 地址或主机名
  <slave1_ip>      Slave 1 节点 IP 地址或主机名
  <slave2_ip>      Slave 2 节点 IP 地址或主机名
  <ssh_user>       SSH 登录用户名（建议使用公钥认证）
  --orch-on-master (可选) 在 Master 主机上部署 Orchestrator 容器

示例：
  ./deploy-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu --orch-on-master
  ./deploy-distributed.sh master.example.com slave1.example.com slave2.example.com ubuntu

环境变量：
  LOG_FILE      日志文件位置（默认：./_deploy_YYYYMMDD_HHMMSS.log）
EOF
}

# 执行参数验证
if [[ -z "$MASTER_IP" || -z "$SLAVE1_IP" || -z "$SLAVE2_IP" || -z "$SSH_USER" ]]; then
  log_error "参数不完整"
  show_usage
  exit 2
fi

log_info "=========================================="
log_info "分布式部署脚本启动"
log_info "=========================================="
log_info "日志文件: $LOG_FILE"
log_info "Master IP: $MASTER_IP"
log_info "Slave 1 IP: $SLAVE1_IP"
log_info "Slave 2 IP: $SLAVE2_IP"
log_info "SSH 用户: $SSH_USER"
log_info "Orchestrator on Master: $ORCH_ON_MASTER"

# 验证 IP 地址格式
for ip in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  if ! validate_ip "$ip"; then
    log_error "无效的 IP 地址或主机名: $ip"
    exit 2
  fi
done
log_success "IP 地址格式验证通过"

# 检查必需文件
if ! check_required_files; then
  exit 1
fi

# ============================================================================
# 远程操作函数
# ============================================================================
copy_to_remote() {
  local host=$1; local src=$2; local dst=$3
  log_info "上传文件: $src -> $SSH_USER@$host:$dst"
  if scp -q "$src" "$SSH_USER@$host:$dst" 2>&1 | tee -a "$LOG_FILE"; then
    log_success "文件上传成功: $dst"
  else
    log_error "文件上传失败: $dst"
    return 1
  fi
}

run_remote() {
  local host=$1; shift
  local cmd="$*"
  log_info "在 $host 执行: $cmd"
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$host" "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
    return 0
  else
    log_error "远程命令执行失败: $cmd (主机: $host)"
    return 1
  fi
}

test_ssh_connection() {
  local host=$1
  log_info "测试 SSH 连接: $SSH_USER@$host"
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$host" "echo 'SSH 连接成功'" 2>&1 | tee -a "$LOG_FILE"; then
    log_success "SSH 连接成功: $host"
    return 0
  else
    log_error "SSH 连接失败: $host"
    return 1
  fi
}

check_docker_available() {
  local host=$1
  log_info "检查 Docker 是否可用: $host"
  if ssh -o StrictHostKeyChecking=no "$SSH_USER@$host" "docker --version && docker compose --version" 2>&1 | tee -a "$LOG_FILE"; then
    log_success "Docker 检查通过: $host"
    return 0
  else
    log_error "Docker/Docker Compose 不可用或未安装: $host"
    return 1
  fi
}

prepare_remote_dir() {
  local host=$1
  log_info "在远端创建工作目录: $host"
  if run_remote "$host" "mkdir -p $REMOTE_DIR && echo '目录创建成功: $REMOTE_DIR'"; then
    log_success "目录准备完毕: $host"
    return 0
  else
    log_error "目录创建失败: $host"
    return 1
  fi
}

# ============================================================================
# 第 1 步：测试连接和环境检查
# ============================================================================
log_info "=========================================="
log_info "步骤 1: 环境检查与连接测试"
log_info "=========================================="

for host in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  if ! test_ssh_connection "$host"; then
    log_error "无法连接到主机: $host，请检查 SSH 配置"
    exit 1
  fi
done

for host in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  if ! check_docker_available "$host"; then
    log_error "主机 $host 上 Docker 不可用，请先安装 Docker 和 Docker Compose"
    exit 1
  fi
done

# ============================================================================
# 第 2 步：创建远端工作目录
# ============================================================================
log_info "=========================================="
log_info "步骤 2: 创建远端工作目录"
log_info "=========================================="

for host in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  if ! prepare_remote_dir "$host"; then
    log_error "无法在 $host 上创建工作目录，部署中止"
    exit 1
  fi
done

# ============================================================================
# 第 3 步：上传 Docker Compose 配置文件
# ============================================================================
log_info "=========================================="
log_info "步骤 3: 上传 Docker Compose 配置文件"
log_info "=========================================="

if ! copy_to_remote "$MASTER_IP" "$SCRIPT_DIR/dist/docker-compose.master.yml" "$REMOTE_DIR/docker-compose.yml"; then
  log_error "无法将 master 配置上传到 $MASTER_IP"
  exit 1
fi

if ! copy_to_remote "$SLAVE1_IP" "$SCRIPT_DIR/dist/docker-compose.slave.yml" "$REMOTE_DIR/docker-compose.yml"; then
  log_error "无法将 slave 配置上传到 $SLAVE1_IP"
  exit 1
fi

if ! copy_to_remote "$SLAVE2_IP" "$SCRIPT_DIR/dist/docker-compose.slave.yml" "$REMOTE_DIR/docker-compose.yml"; then
  log_error "无法将 slave 配置上传到 $SLAVE2_IP"
  exit 1
fi

# ============================================================================
# 第 4 步：上传并修改 Orchestrator 配置
# ============================================================================
log_info "=========================================="
log_info "步骤 4: 上传 Orchestrator 配置"
log_info "=========================================="

if $ORCH_ON_MASTER; then
  log_info "Orchestrator 将在 Master 主机上部署，使用本地 MySQL 作为后端"
  if ! copy_to_remote "$MASTER_IP" "$SCRIPT_DIR/conf/orchestrator-master-slave.conf.json" "$REMOTE_DIR/orchestrator.conf.json"; then
    log_error "无法上传 Orchestrator 配置到 Master"
    exit 1
  fi
else
  log_info "Orchestrator 配置 MySQLOrchestratorHost 将设置为 Master IP: $MASTER_IP"
  tmpconf=$(mktemp)
  trap "rm -f '$tmpconf'" EXIT
  if ! jq --arg host "$MASTER_IP" '.MySQLOrchestratorHost = $host' "$SCRIPT_DIR/conf/orchestrator-master-slave.conf.json" > "$tmpconf" 2>&1 | tee -a "$LOG_FILE"; then
    log_error "无法修改 Orchestrator 配置文件"
    exit 1
  fi
  if ! copy_to_remote "$MASTER_IP" "$tmpconf" "$REMOTE_DIR/orchestrator.conf.json"; then
    log_error "无法上传修改后的 Orchestrator 配置"
    exit 1
  fi
fi

# ============================================================================
# 第 5 步：启动 Docker 容器
# ============================================================================
log_info "=========================================="
log_info "步骤 5: 在各主机启动 Docker 容器"
log_info "=========================================="

for host in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  if ! run_remote "$host" "cd $REMOTE_DIR && docker compose up -d --build"; then
    log_error "无法在 $host 上启动 Docker 容器"
    exit 1
  fi
done

log_info "等待 15 秒让 MySQL 完成初始化..."
sleep 15

# ============================================================================
# 第 6 步：在 Master 上创建复制用户
# ============================================================================
log_info "=========================================="
log_info "步骤 6: 在 Master 上创建复制和 Orchestrator 用户"
log_info "=========================================="

create_users_sql="CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'repl_password'; 
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%'; 
GRANT REPLICATION CLIENT ON *.* TO 'repl_user'@'%'; 
CREATE USER IF NOT EXISTS 'orc_client_user'@'%' IDENTIFIED BY 'orc_client_password'; 
GRANT SELECT, PROCESS, REPLICATION CLIENT, REPLICATION SLAVE, SUPER ON *.* TO 'orc_client_user'@'%'; 
CREATE USER IF NOT EXISTS 'orc_server_user'@'%' IDENTIFIED BY 'orc_server_password'; 
CREATE DATABASE IF NOT EXISTS orchestrator; 
GRANT ALL PRIVILEGES ON orchestrator.* TO 'orc_server_user'@'%'; 
FLUSH PRIVILEGES;"

if ! run_remote "$MASTER_IP" "cd $REMOTE_DIR && docker compose exec -T mysql-master mysql -uroot -proot -e \"$create_users_sql\""; then
  log_error "无法在 Master 上创建用户"
  exit 1
fi

# ============================================================================
# 第 7 步：配置从节点复制
# ============================================================================
log_info "=========================================="
log_info "步骤 7: 配置 Slave 1 复制"
log_info "=========================================="

if ! run_remote "$SLAVE1_IP" "cd $REMOTE_DIR && docker compose exec -T mysql-slave mysql -uroot -proot -e \"CHANGE MASTER TO MASTER_HOST='$MASTER_IP', MASTER_USER='repl_user', MASTER_PASSWORD='repl_password', MASTER_PORT=3306, MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1; START SLAVE;\""; then
  log_error "无法配置 Slave 1"
  exit 1
fi

log_info "=========================================="
log_info "步骤 8: 配置 Slave 2 复制"
log_info "=========================================="

if ! run_remote "$SLAVE2_IP" "cd $REMOTE_DIR && docker compose exec -T mysql-slave mysql -uroot -proot -e \"CHANGE MASTER TO MASTER_HOST='$MASTER_IP', MASTER_USER='repl_user', MASTER_PASSWORD='repl_password', MASTER_PORT=3306, MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1; START SLAVE;\""; then
  log_error "无法配置 Slave 2"
  exit 1
fi

# ============================================================================
# 第 9 步：验证复制状态
# ============================================================================
log_info "=========================================="
log_info "步骤 9: 验证复制状态"
log_info "=========================================="

log_info "检查 Slave 1 复制状态..."
run_remote "$SLAVE1_IP" "docker compose -f $REMOTE_DIR/docker-compose.yml exec -T mysql-slave mysql -uroot -proot -e \"SHOW SLAVE STATUS\\G\" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'" || log_warn "无法获取 Slave 1 状态，但部署可能已成功"

log_info "检查 Slave 2 复制状态..."
run_remote "$SLAVE2_IP" "docker compose -f $REMOTE_DIR/docker-compose.yml exec -T mysql-slave mysql -uroot -proot -e \"SHOW SLAVE STATUS\\G\" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'" || log_warn "无法获取 Slave 2 状态，但部署可能已成功"

# ============================================================================
# 完成总结
# ============================================================================
log_success "=========================================="
log_success "分布式部署完成"
log_success "=========================================="
log_success "Master 地址: $MASTER_IP"
log_success "Slave 1 地址: $SLAVE1_IP"
log_success "Slave 2 地址: $SLAVE2_IP"
log_success "工作目录: $REMOTE_DIR"
log_success "日志文件: $LOG_FILE"
log_info ""
log_info "后续步骤："
log_info "1. 访问各主机验证 Docker 容器运行状态："
log_info "   ssh $SSH_USER@$MASTER_IP 'docker compose -f $REMOTE_DIR/docker-compose.yml ps'"
log_info ""
log_info "2. 通过运维脚本检查复制状态："
log_info "   ./ops/check-replication.sh $SLAVE1_IP $SSH_USER"
log_info "   ./ops/check-replication.sh $SLAVE2_IP $SSH_USER"
log_info ""
log_info "3. 收集日志进行故障排查："
log_info "   ./ops/gather-logs.sh $MASTER_IP $SSH_USER ./logs"
log_info ""
if $ORCH_ON_MASTER; then
  log_info "4. Orchestrator Web UI 将在 $MASTER_IP:3000 可用"
  log_info "   访问: http://$MASTER_IP:3000"
else
  log_info "4. Orchestrator 配置已上传到 $MASTER_IP:$REMOTE_DIR/orchestrator.conf.json"
  log_info "   若需启动 Orchestrator，请在 Master 主机上运行："
  log_info "   cd $REMOTE_DIR && docker compose up -d --build"
fi
log_info ""
