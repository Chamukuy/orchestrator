#!/usr/bin/env bash

# deploy-raft.sh
# 一主两从 MySQL + Orchestrator Raft 集群本地部署脚本
# 使用方法: ./deploy-raft.sh [start|stop|status|logs|init|reset]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.raft.yml"
RAFT_CONF="${SCRIPT_DIR}/conf/orchestrator-raft.conf.json"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
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

# 检查文件存在
check_files() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "找不到 Docker Compose 文件: $COMPOSE_FILE"
        exit 1
    fi
    if [ ! -f "$RAFT_CONF" ]; then
        log_error "找不到 Orchestrator Raft 配置文件: $RAFT_CONF"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安装"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose 未安装"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_warning "jq 未安装，某些功能可能无法使用"
    fi
    
    log_success "依赖检查完成"
}

# 修改配置文件（替换占位符）
prepare_config() {
    log_info "准备 Raft 配置..."
    
    # 为本地部署创建临时配置
    local temp_conf="${SCRIPT_DIR}/.orchestrator-raft-local.conf.json"
    
    cp "$RAFT_CONF" "$temp_conf"
    
    # 替换占位符为本地服务名
    sed -i 's/ORCHESTRATOR_NODE1/orchestrator-1/g' "$temp_conf"
    sed -i 's/ORCHESTRATOR_NODE2/orchestrator-2/g' "$temp_conf"
    sed -i 's/ORCHESTRATOR_NODE3/orchestrator-3/g' "$temp_conf"
    sed -i 's/ORCHESTRATOR_RAFT_BIND/0.0.0.0:10008/g' "$temp_conf"
    
    log_success "配置准备完成: $temp_conf"
}

# 启动环境
start() {
    log_info "=========================================="
    log_info "启动一主两从 MySQL + Orchestrator Raft 集群..."
    log_info "=========================================="
    
    check_files
    check_dependencies
    prepare_config
    
    cd "$SCRIPT_DIR"
    
    log_info "启动容器..."
    docker compose -f docker-compose.raft.yml up -d --build
    
    log_info "等待服务启动..."
    sleep 15
    
    log_info "验证服务状态..."
    docker compose -f docker-compose.raft.yml ps
    
    log_success "=========================================="
    log_success "Raft 集群启动完成！"
    log_success "=========================================="
    
    echo ""
    echo -e "${GREEN}📊 Orchestrator Raft 节点 Web 界面${NC}"
    echo "  Node 1 (Leader): http://localhost:3000 (Raft端口: 10008)"
    echo "  Node 2:          http://localhost:3001 (Raft端口: 10009)"
    echo "  Node 3:          http://localhost:3002 (Raft端口: 10010)"
    echo ""
    echo -e "${GREEN}🗄️  MySQL 拓扑${NC}"
    echo "  Master: localhost:3306"
    echo "  Slave 1: localhost:3307"
    echo "  Slave 2: localhost:3308"
    echo ""
    echo -e "${GREEN}🔍 Raft 集群状态检查${NC}"
    echo "  curl http://localhost:3000/api/leader-check"
    echo "  curl http://localhost:3000/api/raft-health"
    echo ""
}

# 初始化复制
init() {
    log_info "=========================================="
    log_info "初始化主从复制..."
    log_info "=========================================="
    
    check_files
    
    # 等待 MySQL master 启动
    log_info "等待 MySQL Master 启动..."
    for i in {1..30}; do
        if docker exec orchestrator-mysql-master mysqladmin ping -h 127.0.0.1 &> /dev/null; then
            log_success "MySQL Master 已启动"
            break
        fi
        log_info "等待中... ($i/30)"
        sleep 2
    done
    
    # 创建复制用户
    log_info "在 Master 创建复制用户..."
    docker exec -e MYSQL_PWD=root orchestrator-mysql-master mysql -h 127.0.0.1 -u root -e \
        "CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'repl_pass';
         GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
         FLUSH PRIVILEGES;"
    log_success "复制用户创建完成"
    
    # 创建 Orchestrator 用户
    log_info "在 Master 创建 Orchestrator 用户..."
    docker exec -e MYSQL_PWD=root orchestrator-mysql-master mysql -h 127.0.0.1 -u root -e \
        "CREATE USER IF NOT EXISTS 'orc_client_user'@'%' IDENTIFIED BY 'orc_client_pass';
         GRANT SUPER, PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO 'orc_client_user'@'%';
         GRANT SELECT ON mysql.* TO 'orc_client_user'@'%';
         FLUSH PRIVILEGES;"
    log_success "Orchestrator 用户创建完成"
    
    # 创建心跳表
    log_info "创建心跳表..."
    docker exec -e MYSQL_PWD=root orchestrator-mysql-master mysql -h 127.0.0.1 -u root -e \
        "CREATE DATABASE IF NOT EXISTS test;
         CREATE TABLE IF NOT EXISTS test.heartbeat (
           ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
           server_id INT,
           PRIMARY KEY (server_id)
         );
         INSERT INTO test.heartbeat (server_id) VALUES (1) ON DUPLICATE KEY UPDATE ts=CURRENT_TIMESTAMP;"
    log_success "心跳表创建完成"
    
    # 获取 Master 状态
    log_info "获取 Master 状态..."
    master_status=$(docker exec -e MYSQL_PWD=root orchestrator-mysql-master mysql -h 127.0.0.1 -u root -se \
        "SHOW MASTER STATUS\G" | grep -E "File|Position")
    echo "$master_status"
    
    # 等待 Slave 1 启动
    log_info "等待 Slave 1 启动..."
    for i in {1..30}; do
        if docker exec orchestrator-mysql-slave-1 mysqladmin ping -h 127.0.0.1 &> /dev/null; then
            log_success "Slave 1 已启动"
            break
        fi
        log_info "等待中... ($i/30)"
        sleep 2
    done
    
    # 配置 Slave 1
    log_info "配置 Slave 1..."
    docker exec -e MYSQL_PWD=root orchestrator-mysql-slave-1 mysql -h 127.0.0.1 -u root -e \
        "CHANGE MASTER TO MASTER_HOST='mysql-master', MASTER_USER='repl_user', MASTER_PASSWORD='repl_pass', MASTER_AUTO_POSITION=1;
         START SLAVE;"
    log_success "Slave 1 配置完成"
    
    # 等待 Slave 2 启动
    log_info "等待 Slave 2 启动..."
    for i in {1..30}; do
        if docker exec orchestrator-mysql-slave-2 mysqladmin ping -h 127.0.0.1 &> /dev/null; then
            log_success "Slave 2 已启动"
            break
        fi
        log_info "等待中... ($i/30)"
        sleep 2
    done
    
    # 配置 Slave 2
    log_info "配置 Slave 2..."
    docker exec -e MYSQL_PWD=root orchestrator-mysql-slave-2 mysql -h 127.0.0.1 -u root -e \
        "CHANGE MASTER TO MASTER_HOST='mysql-master', MASTER_USER='repl_user', MASTER_PASSWORD='repl_pass', MASTER_AUTO_POSITION=1;
         START SLAVE;"
    log_success "Slave 2 配置完成"
    
    # 验证复制状态
    log_info "=========================================="
    log_info "验证主从复制状态..."
    log_info "=========================================="
    
    sleep 5
    
    log_info "Slave 1 复制状态:"
    docker exec -e MYSQL_PWD=root orchestrator-mysql-slave-1 mysql -h 127.0.0.1 -u root -se \
        "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_State|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"
    
    log_info "Slave 2 复制状态:"
    docker exec -e MYSQL_PWD=root orchestrator-mysql-slave-2 mysql -h 127.0.0.1 -u root -se \
        "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_State|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"
    
    log_success "主从复制初始化完成！"
}

# 停止环境
stop() {
    log_info "停止所有容器..."
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.raft.yml down
    log_success "环境已停止"
}

# 查看状态
status() {
    log_info "=========================================="
    log_info "容器状态："
    log_info "=========================================="
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.raft.yml ps
    
    echo ""
    log_info "=========================================="
    log_info "Orchestrator Raft 集群状态"
    log_info "=========================================="
    
    for port in 3000 3001 3002; do
        node_num=$((port - 3000 + 1))
        log_info "检查 Orchestrator Node $node_num (端口 $port)..."
        
        if curl -s http://localhost:$port/api/status > /dev/null 2>&1; then
            log_success "Node $node_num 运行正常"
            
            # 检查 leader
            if curl -s http://localhost:$port/api/leader-check > /dev/null 2>&1; then
                log_success "Node $node_num 是 Leader"
            else
                log_info "Node $node_num 是 Follower"
            fi
            
            # 检查 raft health
            if curl -s http://localhost:$port/api/raft-health 2>&1 | grep -q "healthy"; then
                log_success "Node $node_num Raft 健康"
            fi
        else
            log_warning "Node $node_num 不可用"
        fi
    done
}

# 查看日志
logs() {
    SERVICE=${1:-all}
    cd "$SCRIPT_DIR"
    if [ "$SERVICE" == "all" ]; then
        docker compose -f docker-compose.raft.yml logs -f
    else
        docker compose -f docker-compose.raft.yml logs -f "$SERVICE"
    fi
}

# 重置环境
reset() {
    log_warning "准备重置环境（删除所有数据）..."
    read -p "确认要继续吗? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        log_info "停止容器..."
        cd "$SCRIPT_DIR"
        docker compose -f docker-compose.raft.yml down -v
        log_success "环境已重置"
    else
        log_info "操作已取消"
    fi
}

# 显示帮助
show_help() {
    cat << 'EOF'
Orchestrator Raft 集群部署脚本

使用方法:
  ./deploy-raft.sh [command]

命令:
  start       启动 MySQL + Orchestrator Raft 集群
  stop        停止所有容器
  status      查看集群状态
  logs        查看容器日志 (logs [service_name])
  init        初始化主从复制
  reset       重置环境（删除所有数据）
  help        显示本帮助信息

示例:
  ./deploy-raft.sh start      # 启动集群
  ./deploy-raft.sh init       # 初始化复制
  ./deploy-raft.sh status     # 查看状态
  ./deploy-raft.sh logs orchestrator-1  # 查看节点1日志
  ./deploy-raft.sh stop       # 停止集群
  ./deploy-raft.sh reset      # 重置环境

EOF
}

# 主程序
COMMAND=${1:-start}

case "$COMMAND" in
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
        logs "${2:-all}"
        ;;
    init)
        init
        ;;
    reset)
        reset
        ;;
    help)
        show_help
        ;;
    *)
        log_error "未知命令: $COMMAND"
        show_help
        exit 1
        ;;
esac
