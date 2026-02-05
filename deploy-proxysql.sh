#!/usr/bin/env bash

# deploy-proxysql.sh
# ProxySQL + Orchestrator Raft 集成部署脚本
# 用途：部署 ProxySQL 中间件层，实现读写分离和自动故障转移

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXYSQL_COMPOSE="${SCRIPT_DIR}/docker-compose.proxysql.yml"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
    if [ ! -f "$PROXYSQL_COMPOSE" ]; then
        log_error "找不到 Docker Compose 文件: $PROXYSQL_COMPOSE"
        exit 1
    fi
}

# 启动 ProxySQL
start() {
    log_info "=========================================="
    log_info "启动 ProxySQL 中间件..."
    log_info "=========================================="
    
    check_files
    
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.proxysql.yml up -d --build
    
    log_info "等待 ProxySQL 启动..."
    sleep 5
    
    log_info "验证服务状态..."
    docker compose -f docker-compose.proxysql.yml ps
    
    log_success "=========================================="
    log_success "ProxySQL 启动完成！"
    log_success "=========================================="
    
    echo ""
    echo -e "${GREEN}📊 ProxySQL 管理接口${NC}"
    echo "  MySQL 客户端端口: localhost:6033"
    echo "  Admin 接口: localhost:6032"
    echo ""
    echo -e "${GREEN}🔐 默认凭证${NC}"
    echo "  MySQL 用户: proxysql_user / proxysql_pass"
    echo "  Admin 用户: admin / admin"
    echo ""
    echo -e "${GREEN}📝 验证连接${NC}"
    echo "  mysql -h 127.0.0.1 -P 6033 -u proxysql_user -p proxysql_pass"
    echo "  mysql -h 127.0.0.1 -P 6032 -u admin -p admin"
    echo ""
}

# 配置 ProxySQL
configure() {
    log_info "=========================================="
    log_info "配置 ProxySQL..."
    log_info "=========================================="
    
    # 等待 ProxySQL 启动
    log_info "等待 ProxySQL 启动..."
    for i in {1..30}; do
        if docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e "SELECT 1" &>/dev/null; then
            log_success "ProxySQL Admin 已启动"
            break
        fi
        log_info "等待中... ($i/30)"
        sleep 2
    done
    
    # 添加 MySQL 后端服务器
    log_info "添加 MySQL 后端服务器..."
    
    # 获取 MySQL 服务器信息（从 Docker 网络）
    docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin << EOF
-- 清空现有配置
DELETE FROM mysql_servers;

-- 添加 Master (hostgroup 0)
INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight,comment) 
VALUES(0,'mysql-master',3306,1000,'Master');

-- 添加 Slaves (hostgroup 1)
INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight,comment) 
VALUES(1,'mysql-slave-1',3306,1000,'Slave 1');
INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight,comment) 
VALUES(1,'mysql-slave-2',3306,1000,'Slave 2');

-- 应用到运行时
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

-- 验证
SELECT * FROM mysql_servers \G
EOF
    
    log_success "MySQL 后端服务器配置完成"
    
    # 配置查询规则
    log_info "配置查询转发规则..."
    
    docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin << EOF
-- 清空现有规则
DELETE FROM mysql_query_rules;

-- 规则 1: SELECT 转发到 Slave (hostgroup 1)
INSERT INTO mysql_query_rules(rule_id,active,match_pattern,destination_hostgroup,apply,comment)
VALUES(1,1,'^SELECT',1,1,'Route SELECT to Slave');

-- 规则 2: INSERT/UPDATE/DELETE 转发到 Master (hostgroup 0)
INSERT INTO mysql_query_rules(rule_id,active,match_pattern,destination_hostgroup,apply,comment)
VALUES(2,1,'^(INSERT|UPDATE|DELETE)',0,1,'Route write to Master');

-- 规则 3: 事务始终使用 Master
INSERT INTO mysql_query_rules(rule_id,active,match_pattern,destination_hostgroup,apply,comment)
VALUES(3,1,'^BEGIN',0,1,'Route transaction to Master');

-- 应用到运行时
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;

-- 验证
SELECT * FROM mysql_query_rules \G
EOF
    
    log_success "查询转发规则配置完成"
    
    # 配置 MySQL 用户
    log_info "配置 MySQL 用户..."
    
    docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin << EOF
-- 添加 MySQL 用户 (代理用户)
DELETE FROM mysql_users;
INSERT INTO mysql_users(username,password,hostgroup,active,comment)
VALUES('proxysql_user','proxysql_pass',0,1,'ProxySQL client user');

-- 应用到运行时
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;

-- 验证
SELECT * FROM mysql_users \G
EOF
    
    log_success "MySQL 用户配置完成"
    
    log_success "=========================================="
    log_success "ProxySQL 配置完成！"
    log_success "=========================================="
}

# 查看状态
status() {
    log_info "=========================================="
    log_info "ProxySQL 状态"
    log_info "=========================================="
    
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.proxysql.yml ps
    
    echo ""
    log_info "ProxySQL Admin 状态"
    
    # 查看 MySQL 服务器
    log_info "后端 MySQL 服务器:"
    docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e "SELECT hostgroup_id, hostname, port, weight, status FROM mysql_servers;"
    
    echo ""
    
    # 查看查询规则
    log_info "查询转发规则:"
    docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e "SELECT rule_id, match_pattern, destination_hostgroup, comment FROM mysql_query_rules WHERE active=1;"
    
    echo ""
    
    # 查看连接数
    log_info "当前连接数:"
    docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e "SHOW STATUS LIKE 'Connections';"
}

# 查看日志
logs() {
    SERVICE=${1:-all}
    cd "$SCRIPT_DIR"
    if [ "$SERVICE" == "all" ]; then
        docker compose -f docker-compose.proxysql.yml logs -f
    else
        docker compose -f docker-compose.proxysql.yml logs -f "$SERVICE"
    fi
}

# 停止 ProxySQL
stop() {
    log_info "停止 ProxySQL..."
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.proxysql.yml down
    log_success "ProxySQL 已停止"
}

# 重置（删除数据）
reset() {
    log_warning "准备重置 ProxySQL（删除所有配置）..."
    read -p "确认要继续吗? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        log_info "停止容器..."
        cd "$SCRIPT_DIR"
        docker compose -f docker-compose.proxysql.yml down -v
        log_success "ProxySQL 已重置"
    else
        log_info "操作已取消"
    fi
}

# 测试连接
test_connection() {
    log_info "测试 ProxySQL 连接..."
    
    # 测试 MySQL 客户端连接
    if docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6033 -u proxysql_user -pproxysql_pass -e "SELECT 1;" &>/dev/null; then
        log_success "ProxySQL MySQL 客户端连接正常"
    else
        log_error "ProxySQL MySQL 客户端连接失败"
        return 1
    fi
    
    # 测试 Admin 连接
    if docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e "SELECT 1;" &>/dev/null; then
        log_success "ProxySQL Admin 连接正常"
    else
        log_error "ProxySQL Admin 连接失败"
        return 1
    fi
    
    # 测试 SELECT 到 Slave
    log_info "测试读写分离..."
    result=$(docker exec orchestrator-proxysql mysql -h 127.0.0.1 -P 6033 -u proxysql_user -pproxysql_pass -e "SELECT 'read test';" 2>/dev/null || echo "failed")
    if [ "$result" != "failed" ]; then
        log_success "SELECT 查询测试成功"
    fi
}

# 显示帮助
show_help() {
    cat << 'EOF'
ProxySQL + Orchestrator Raft 部署脚本

使用方法:
  ./deploy-proxysql.sh [command]

命令:
  start       启动 ProxySQL
  stop        停止 ProxySQL
  status      查看状态
  configure   配置 ProxySQL (需要先启动)
  test        测试连接
  logs        查看日志 (logs [service_name])
  reset       重置 ProxySQL（删除配置）
  help        显示本帮助信息

示例:
  ./deploy-proxysql.sh start           # 启动 ProxySQL
  ./deploy-proxysql.sh configure       # 配置后端服务器和规则
  ./deploy-proxysql.sh status          # 查看状态
  ./deploy-proxysql.sh test            # 测试连接
  ./deploy-proxysql.sh logs            # 查看日志
  ./deploy-proxysql.sh stop            # 停止 ProxySQL

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
    configure)
        configure
        ;;
    test)
        test_connection
        ;;
    logs)
        logs "${2:-all}"
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
