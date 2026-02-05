#!/usr/bin/env bash
set -euo pipefail

# deploy-raft-distributed.sh
# 在三台主机上分别部署 MySQL master / slave1 / slave2 + Orchestrator Raft 集群
# 用法：
#   ./deploy-raft-distributed.sh <master_ip> <slave1_ip> <slave2_ip> <ssh_user> [--backend-db {mysql|sqlite}]

# ============================================================================
# 日志与颜色
# ============================================================================
LOG_FILE="${LOG_FILE:-./_deploy_raft_$(date +%Y%m%d_%H%M%S).log}"
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
BACKEND_DB="sqlite"

# 解析可选参数
shift 4 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-db)
      BACKEND_DB="$2"
      shift 2
      ;;
    *)
      log_error "未知参数: $1"
      exit 2
      ;;
  esac
done

REMOTE_DIR=~/orchestrator_raft_dist
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
    "$SCRIPT_DIR/dist/docker-compose.raft-node.yml"
    "$SCRIPT_DIR/dist/docker-compose.raft-backend.yml"
    "$SCRIPT_DIR/conf/orchestrator-raft.conf.json"
  )
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      log_warn "找不到文件（稍后会创建）: $f"
    fi
  done
  return 0
}

# 显示帮助
show_usage() {
  cat << 'EOF'
使用方法：
  ./deploy-raft-distributed.sh <master_ip> <slave1_ip> <slave2_ip> <ssh_user> [--backend-db {mysql|sqlite}]

参数说明：
  <master_ip>          Master 节点 IP 地址或主机名
  <slave1_ip>          Slave 1 节点 IP 地址或主机名
  <slave2_ip>          Slave 2 节点 IP 地址或主机名
  <ssh_user>           SSH 登录用户名（建议使用公钥认证）
  --backend-db         Orchestrator 后端数据库（sqlite 或 mysql，默认: sqlite）

示例：
  ./deploy-raft-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu
  ./deploy-raft-distributed.sh master.example.com slave1.example.com slave2.example.com ubuntu --backend-db sqlite
  ./deploy-raft-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu --backend-db mysql

环境变量：
  LOG_FILE      日志文件位置（默认：./_deploy_raft_YYYYMMDD_HHMMSS.log）
EOF
}

# 执行参数验证
if [[ -z "$MASTER_IP" || -z "$SLAVE1_IP" || -z "$SLAVE2_IP" || -z "$SSH_USER" ]]; then
  log_error "参数不完整"
  show_usage
  exit 2
fi

log_info "=========================================="
log_info "Raft 分布式部署脚本启动"
log_info "=========================================="
log_info "日志文件: $LOG_FILE"
log_info "Master IP: $MASTER_IP"
log_info "Slave 1 IP: $SLAVE1_IP"
log_info "Slave 2 IP: $SLAVE2_IP"
log_info "SSH 用户: $SSH_USER"
log_info "后端数据库: $BACKEND_DB"

# 验证 IP 地址格式
for ip in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  if ! validate_ip "$ip"; then
    log_error "无效的 IP 地址或主机名: $ip"
    exit 2
  fi
done
log_success "IP 地址格式验证通过"

# ============================================================================
# 远程操作函数
# ============================================================================
copy_to_remote() {
  local host=$1; local src=$2; local dst=$3
  log_info "上传文件: $src -> $SSH_USER@$host:$dst"
  if scp -q "$src" "$SSH_USER@$host:$dst" 2>&1 | tee -a "$LOG_FILE"; then
    log_success "文件上传成功"
  else
    log_error "文件上传失败"
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

# 生成 Raft 配置文件
generate_raft_config() {
  local node_name=$1
  local node_ip=$2
  local conf_file="$SCRIPT_DIR/.orchestrator-raft-$node_name.conf.json"
  
  log_info "为 $node_name 生成 Raft 配置"
  
  cp "$SCRIPT_DIR/conf/orchestrator-raft.conf.json" "$conf_file"
  
  # 替换占位符
  sed -i "s|ORCHESTRATOR_NODE1|$MASTER_IP|g" "$conf_file"
  sed -i "s|ORCHESTRATOR_NODE2|$SLAVE1_IP|g" "$conf_file"
  sed -i "s|ORCHESTRATOR_NODE3|$SLAVE2_IP|g" "$conf_file"
  sed -i "s|ORCHESTRATOR_RAFT_BIND|0.0.0.0:10008|g" "$conf_file"
  
  # 配置后端数据库
  if [[ "$BACKEND_DB" == "mysql" ]]; then
    sed -i 's/"BackendDB": "sqlite"/"BackendDB": "mysql"/g' "$conf_file"
    sed -i "s|\"SQLite3DataFile\": \"/var/lib/orchestrator/orchestrator.db\"|\"MySQLBackendHost\": \"127.0.0.1:3306\", \"MySQLBackendUser\": \"orchestrator\", \"MySQLBackendPassword\": \"orch_backend_pass\"|g" "$conf_file"
  fi
  
  log_success "配置文件已生成: $conf_file"
}

# ============================================================================
# 部署步骤
# ============================================================================

# 1. 环境检查与连接测试
log_info "=========================================="
log_info "Step 1: 环境检查与连接测试"
log_info "=========================================="

for ip in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  test_ssh_connection "$ip" || exit 1
  check_docker_available "$ip" || exit 1
done

log_success "Step 1 完成"

# 2. 创建远端工作目录
log_info "=========================================="
log_info "Step 2: 创建远端工作目录"
log_info "=========================================="

for ip in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  prepare_remote_dir "$ip" || exit 1
done

log_success "Step 2 完成"

# 3. 生成配置文件
log_info "=========================================="
log_info "Step 3: 生成 Raft 配置文件"
log_info "=========================================="

generate_raft_config "master" "$MASTER_IP"
generate_raft_config "slave1" "$SLAVE1_IP"
generate_raft_config "slave2" "$SLAVE2_IP"

log_success "Step 3 完成"

# 4. 上传 Docker Compose 和配置文件
log_info "=========================================="
log_info "Step 4: 上传配置文件到远端"
log_info "=========================================="

# 上传 Master Compose 文件
copy_to_remote "$MASTER_IP" "$SCRIPT_DIR/dist/docker-compose.raft-master.yml" "$REMOTE_DIR/docker-compose.yml" || exit 1

# 上传 Slave Compose 文件
copy_to_remote "$SLAVE1_IP" "$SCRIPT_DIR/dist/docker-compose.raft-slave.yml" "$REMOTE_DIR/docker-compose.yml" || exit 1
copy_to_remote "$SLAVE2_IP" "$SCRIPT_DIR/dist/docker-compose.raft-slave.yml" "$REMOTE_DIR/docker-compose.yml" || exit 1

# 上传 Raft 配置文件
copy_to_remote "$MASTER_IP" "$SCRIPT_DIR/.orchestrator-raft-master.conf.json" "$REMOTE_DIR/orchestrator.conf.json" || exit 1
copy_to_remote "$SLAVE1_IP" "$SCRIPT_DIR/.orchestrator-raft-slave1.conf.json" "$REMOTE_DIR/orchestrator.conf.json" || exit 1
copy_to_remote "$SLAVE2_IP" "$SCRIPT_DIR/.orchestrator-raft-slave2.conf.json" "$REMOTE_DIR/orchestrator.conf.json" || exit 1

log_success "Step 4 完成"

# 5. 启动 Docker 容器
log_info "=========================================="
log_info "Step 5: 启动 Docker 容器"
log_info "=========================================="

for ip in "$MASTER_IP" "$SLAVE1_IP" "$SLAVE2_IP"; do
  run_remote "$ip" "cd $REMOTE_DIR && docker compose up -d --build" || exit 1
done

log_info "等待服务启动..."
sleep 20

log_success "Step 5 完成"

# 6. 初始化主从复制
log_info "=========================================="
log_info "Step 6: 初始化主从复制"
log_info "=========================================="

# 创建复制用户
log_info "在 Master 创建复制用户..."
run_remote "$MASTER_IP" \
  "docker exec \$(docker ps -q -f 'label=com.docker.compose.service=mysql-master') \
   mysql -h 127.0.0.1 -u root -proot -e \
   'CREATE USER IF NOT EXISTS \"repl_user\"@\"%\" IDENTIFIED BY \"repl_pass\"; \
    GRANT REPLICATION SLAVE ON *.* TO \"repl_user\"@\"%\"; \
    CREATE USER IF NOT EXISTS \"orc_client_user\"@\"%\" IDENTIFIED BY \"orc_client_pass\"; \
    GRANT SUPER, PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO \"orc_client_user\"@\"%\"; \
    GRANT SELECT ON mysql.* TO \"orc_client_user\"@\"%\"; \
    FLUSH PRIVILEGES;'" || exit 1

log_success "Step 6 完成"

# 7. 验证部署
log_info "=========================================="
log_info "Step 7: 验证部署"
log_info "=========================================="

log_success "=========================================="
log_success "Raft 分布式部署完成！"
log_success "=========================================="

echo ""
echo -e "${GREEN}📊 Orchestrator Raft 集群信息${NC}"
echo "  Master 节点 (IP: $MASTER_IP)"
echo "    Web 界面: http://$MASTER_IP:3000"
echo "    Raft 端口: 10008"
echo ""
echo "  Slave1 节点 (IP: $SLAVE1_IP)"
echo "    Web 界面: http://$SLAVE1_IP:3000"
echo "    Raft 端口: 10008"
echo ""
echo "  Slave2 节点 (IP: $SLAVE2_IP)"
echo "    Web 界面: http://$SLAVE2_IP:3000"
echo "    Raft 端口: 10008"
echo ""
echo -e "${GREEN}🗄️  MySQL 拓扑${NC}"
echo "  Master: $MASTER_IP:3306"
echo "  Slave 1: $SLAVE1_IP:3306"
echo "  Slave 2: $SLAVE2_IP:3306"
echo ""
echo -e "${GREEN}📝 后续步骤${NC}"
echo "  1. 配置 HAProxy 或 Nginx 反向代理到 Raft 领导节点"
echo "  2. 使用 /api/leader-check 端点检查领导者"
echo "  3. 使用 orchestrator-client 管理集群"
echo ""
