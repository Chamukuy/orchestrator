#!/bin/bash

# 一主两从 MySQL + Orchestrator 部署脚本
# 使用方法: ./deploy-master-slave.sh [start|stop|status|logs|reset]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.master-slave.yml"
ORCHESTRATOR_CONF="${SCRIPT_DIR}/conf/orchestrator-master-slave.conf.json"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 函数：打印带颜色的消息
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 函数：检查文件存在
check_files() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "找不到 Docker Compose 文件: $COMPOSE_FILE"
        exit 1
    fi
    if [ ! -f "$ORCHESTRATOR_CONF" ]; then
        log_error "找不到 Orchestrator 配置文件: $ORCHESTRATOR_CONF"
        exit 1
    fi
}

# 函数：启动环境
start() {
    log_info "启动一主两从 MySQL + Orchestrator 拓扑..."
    check_files
    
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.master-slave.yml up -d --build
    
    log_info "等待服务启动..."
    sleep 10
    
    log_info "验证服务状态..."
    docker compose -f docker-compose.master-slave.yml ps
    
    log_success "环境启动完成！"
    log_info "Orchestrator Web 界面: http://localhost:3000"
    log_info "Master: localhost:3306"
    log_info "Slave 1: localhost:3307"
    log_info "Slave 2: localhost:3308"
}

# 函数：停止环境
stop() {
    log_info "停止所有容器..."
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.master-slave.yml down
    log_success "环境已停止"
}

# 函数：查看状态
status() {
    log_info "容器状态："
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.master-slave.yml ps
    
    log_info "检查 Orchestrator 服务..."
    if curl -s http://localhost:3000/api/status > /dev/null 2>&1; then
        log_success "Orchestrator 服务运行正常"
        curl -s http://localhost:3000/api/status | jq .
    else
        log_warning "Orchestrator 服务不可用"
    fi
}

# 函数：查看日志
logs() {
    SERVICE=${1:-all}
    cd "$SCRIPT_DIR"
    if [ "$SERVICE" == "all" ]; then
        docker compose -f docker-compose.master-slave.yml logs -f
    else
        docker compose -f docker-compose.master-slave.yml logs -f "$SERVICE"
    fi
}

# 函数：初始化主从复制
init_replication() {
    log_info "初始化主从复制..."
    
    cd "$SCRIPT_DIR"
    
    # 创建复制用户和 Orchestrator 用户
    log_info "在 Master 上创建复制用户..."
    docker compose -f docker-compose.master-slave.yml exec -T mysql-master mysql -uroot -proot <<EOF
-- 创建复制用户
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'repl_password';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
GRANT REPLICATION CLIENT ON *.* TO 'repl_user'@'%';

-- 创建 Orchestrator 用户
CREATE USER IF NOT EXISTS 'orc_client_user'@'%' IDENTIFIED BY 'orc_client_password';
GRANT SELECT, PROCESS, REPLICATION CLIENT, REPLICATION SLAVE, SUPER ON *.* TO 'orc_client_user'@'%';

-- 创建 Orchestrator 后端用户
CREATE USER IF NOT EXISTS 'orc_server_user'@'%' IDENTIFIED BY 'orc_server_password';
GRANT ALL PRIVILEGES ON orchestrator.* TO 'orc_server_user'@'%';

FLUSH PRIVILEGES;
EOF
    
    log_success "Master 用户创建完成"
    
    # 配置 Slave 1
    log_info "配置 Slave 1..."
    docker compose -f docker-compose.master-slave.yml exec -T mysql-slave-1 mysql -uroot -proot <<EOF
CHANGE MASTER TO
  MASTER_HOST='mysql-master',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password',
  MASTER_PORT=3306,
  MASTER_AUTO_POSITION=1,
  GET_MASTER_PUBLIC_KEY=1;

START SLAVE;
EOF
    
    log_success "Slave 1 配置完成"
    
    # 配置 Slave 2
    log_info "配置 Slave 2..."
    docker compose -f docker-compose.master-slave.yml exec -T mysql-slave-2 mysql -uroot -proot <<EOF
CHANGE MASTER TO
  MASTER_HOST='mysql-master',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password',
  MASTER_PORT=3306,
  MASTER_AUTO_POSITION=1,
  GET_MASTER_PUBLIC_KEY=1;

START SLAVE;
EOF
    
    log_success "Slave 2 配置完成"
    
    # 验证复制状态
    log_info "验证复制状态..."
    sleep 2
    
    log_info "=== Slave 1 复制状态 ==="
    docker compose -f docker-compose.master-slave.yml exec -T mysql-slave-1 mysql -uroot -proot -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"
    
    log_info "=== Slave 2 复制状态 ==="
    docker compose -f docker-compose.master-slave.yml exec -T mysql-slave-2 mysql -uroot -proot -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"
}

# 函数：重置环境
reset() {
    log_warning "将删除所有数据并重置环境..."
    read -p "确认删除所有数据？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$SCRIPT_DIR"
        docker compose -f docker-compose.master-slave.yml down -v
        log_success "环境已重置"
    else
        log_info "操作已取消"
    fi
}

# 函数：显示帮助信息
show_help() {
    cat <<EOF
使用方法: $(basename "$0") [命令]

命令:
  start           启动一主两从 MySQL + Orchestrator 环境
  stop            停止所有容器
  status          查看环境状态
  logs [SERVICE]  查看容器日志（SERVICE 可选：master, slave-1, slave-2, orchestrator）
  init            初始化主从复制配置
  reset           重置环境（删除所有数据）
  help            显示此帮助信息

示例:
  $(basename "$0") start              # 启动环境
  $(basename "$0") logs orchestrator  # 查看 Orchestrator 日志
  $(basename "$0") status             # 查看状态

EOF
}

# 主程序
case "${1:-help}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status
        ;;
    logs)
        logs "$2"
        ;;
    init)
        init_replication
        ;;
    reset)
        reset
        ;;
    help)
        show_help
        ;;
    *)
        log_error "未知的命令: $1"
        show_help
        exit 1
        ;;
esac
