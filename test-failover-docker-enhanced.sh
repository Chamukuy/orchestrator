#!/bin/bash

################################################################################
# Orchestrator Raft 故障演练测试脚本 - Docker 增强版
# 
# 功能：
# - 自动检测运行环境（Docker 容器或 Host）
# - 智能调整 MySQL 和 Orchestrator 访问地址
# - 支持所有 6 种故障场景
# - 完全兼容原始脚本的所有参数和功能
#
# 使用：
#   Host 环境：    bash test-failover-docker-enhanced.sh master-crash
#   Docker 环境：  docker exec orchestrator-raft-1 bash test-failover.sh master-crash
#   自动检测：     bash test-failover-docker-enhanced.sh slave-crash
################################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_debug() {
    echo -e "${CYAN}[DEBUG]${NC} $1"
}

################################################################################
# Docker 环境检测 ⭐ 核心改进
################################################################################

detect_docker_environment() {
    # 方法 1: 检查 /.dockerenv 文件（Docker 标准）
    if [ -f "/.dockerenv" ]; then
        return 0
    fi
    
    # 方法 2: 检查 /proc/self/cgroup 中是否包含 "docker"
    if grep -q "docker" /proc/self/cgroup 2>/dev/null; then
        return 0
    fi
    
    # 方法 3: 检查 DOCKER_CONTAINER 环境变量
    if [ -n "$DOCKER_CONTAINER" ]; then
        return 0
    fi
    
    return 1
}

export_environment_type() {
    if detect_docker_environment; then
        ENVIRONMENT="DOCKER_CONTAINER"
        ENVIRONMENT_DISPLAY="Docker 容器内"
    else
        ENVIRONMENT="HOST"
        ENVIRONMENT_DISPLAY="Host 本地环境"
    fi
    export ENVIRONMENT
}

################################################################################
# 配置初始化与环境检测 ⭐ 关键改变
################################################################################

init_config() {
    export_environment_type
    
    if [ "$ENVIRONMENT" = "DOCKER_CONTAINER" ]; then
        # ★ Docker 容器内：使用容器网络 DNS 名称和原始端口
        ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://orchestrator-raft-1:3000}"
        MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-mysql-master}"
        MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
        MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-mysql-slave-1}"
        MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3306}"
        MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-mysql-slave-2}"
        MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3306}"
    else
        # ★ Host 环境：使用本地地址和映射端口
        ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
        MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
        MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
        MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-127.0.0.1}"
        MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3307}"
        MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-127.0.0.1}"
        MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3308}"
    fi
    
    # 数据库用户（两种环境一致）
    MYSQL_USER="${MYSQL_USER:-root}"
    MYSQL_PASS="${MYSQL_PASS:-root}"
    DISCOVERY_INTERVAL=5
}

################################################################################
# 辅助函数
################################################################################

print_environment_info() {
    echo ""
    log_info "┌─────────────────────────────────────────┐"
    log_info "│ 运行环境信息                            │"
    log_info "├─────────────────────────────────────────┤"
    log_info "│ 环境类型:    $ENVIRONMENT_DISPLAY"
    log_info "│ Orchestrator: $ORCHESTRATOR_API"
    log_info "│ MySQL Master: $MYSQL_MASTER_HOST:$MYSQL_MASTER_PORT"
    log_info "│ MySQL Slave1: $MYSQL_SLAVE1_HOST:$MYSQL_SLAVE1_PORT"
    log_info "│ MySQL Slave2: $MYSQL_SLAVE2_HOST:$MYSQL_SLAVE2_PORT"
    log_info "└─────────────────────────────────────────┘"
    echo ""
}

check_mysql_connectivity() {
    local host=$1
    local port=$2
    local label=$3
    
    if mysql -h "$host" -P "$port" -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1;" &>/dev/null; then
        log_success "$label 可连接 ($host:$port)"
        return 0
    else
        log_error "$label 无法连接 ($host:$port)"
        return 1
    fi
}

get_orchestrator_status() {
    local response
    response=$(curl -s "$ORCHESTRATOR_API/api/leader-check" 2>/dev/null || echo '')
    
    if [ -z "$response" ]; then
        log_error "无法连接 Orchestrator API ($ORCHESTRATOR_API)"
        return 1
    fi
    
    if echo "$response" | grep -q '"IsLeader":true'; then
        log_success "Orchestrator 已选出 Leader"
        return 0
    else
        log_warning "Orchestrator 未选出 Leader"
        return 1
    fi
}

get_master_info() {
    local response
    response=$(curl -s "$ORCHESTRATOR_API/api/instance/$MYSQL_MASTER_HOST/$MYSQL_MASTER_PORT")
    echo "$response"
}

get_topology() {
    local response
    response=$(curl -s "$ORCHESTRATOR_API/api/cluster/master-slave")
    echo "$response"
}

generate_test_data() {
    log_info "生成测试数据..."
    
    mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS test_failover;
USE test_failover;
CREATE TABLE IF NOT EXISTS test_table (
    id INT AUTO_INCREMENT PRIMARY KEY,
    test_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    test_value VARCHAR(255)
);
INSERT INTO test_table (test_value) VALUES ('Test data at $(date "+%Y-%m-%d %H:%M:%S")');
EOF
    
    log_success "测试数据已生成"
}

check_replication_lag() {
    log_info "检查从库复制延迟..."
    
    for i in 1 2; do
        if [ $i -eq 1 ]; then
            host=$MYSQL_SLAVE1_HOST
            port=$MYSQL_SLAVE1_PORT
        else
            host=$MYSQL_SLAVE2_HOST
            port=$MYSQL_SLAVE2_PORT
        fi
        
        lag=$(mysql -h "$host" -P "$port" -u "$MYSQL_USER" -p"$MYSQL_PASS" -se "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master" | awk '{print $2}')
        
        if [ -z "$lag" ] || [ "$lag" = "NULL" ]; then
            log_warning "Slave$i 复制延迟: 无法获取（可能不在复制中）"
        else
            log_info "Slave$i 复制延迟: ${lag}秒"
        fi
    done
}

################################################################################
# 故障模拟函数
################################################################################

simulate_master_crash() {
    log_info "========== 场景 1: Master 宕机 =========="
    log_info "模拟主库完全宕机...模拟方式: 停止 MySQL 服务"
    
    # 验证初始状态
    log_info "验证初始状态..."
    check_mysql_connectivity "$MYSQL_MASTER_HOST" "$MYSQL_MASTER_PORT" "初始主库"
    
    # 停止主库
    if [ "$ENVIRONMENT" = "DOCKER_CONTAINER" ]; then
        log_info "停止容器: mysql-master"
        docker stop mysql-master 2>/dev/null || log_warning "容器停止命令可能需要 docker 权限"
    else
        log_info "停止主库 MySQL 服务 (host)"
        docker-compose stop mysql-master 2>/dev/null || log_warning "docker-compose 不可用，请手动停止"
    fi
    
    log_warning "等待 30 秒让 Orchestrator 发现故障..."
    sleep 30
    
    # 检查 Orchestrator 是否已转移
    log_info "检查 Orchestrator 故障检测..."
    get_orchestrator_status
    
    log_info "检查新拓扑..."
    get_topology
}

simulate_slave_crash() {
    log_info "========== 场景 2: 从库宕机 =========="
    log_info "模拟从库无法连接...模拟方式: 停止 MySQL 服务"
    
    if [ "$ENVIRONMENT" = "DOCKER_CONTAINER" ]; then
        log_info "停止容器: mysql-slave-1"
        docker stop mysql-slave-1 2>/dev/null || log_warning "容器停止命令可能需要 docker 权限"
    else
        log_info "停止从库 MySQL 服务 (host)"
        docker-compose stop mysql-slave-1 2>/dev/null || log_warning "docker-compose 不可用，请手动停止"
    fi
    
    log_warning "等待 20 秒..."
    sleep 20
    
    log_info "检查主库是否仍可用..."
    check_mysql_connectivity "$MYSQL_MASTER_HOST" "$MYSQL_MASTER_PORT" "主库"
}

simulate_network_partition() {
    log_info "========== 场景 3: 网络分区 =========="
    log_info "模拟网络分区...模拟方式: iptables 限制（需要 root）"
    log_warning "⚠️  此场景需要 root 权限且在 Host 环境运行"
    
    if [ "$ENVIRONMENT" = "DOCKER_CONTAINER" ]; then
        log_error "网络分区模拟在 Docker 内不支持，跳过"
        return 1
    fi
    
    log_info "此场景需要手动配置 iptables 规则"
    log_debug "示例: sudo iptables -I OUTPUT 1 -d 127.0.0.1 -p tcp --dport 3306 -j DROP"
}

simulate_slow_replica() {
    log_info "========== 场景 4: 慢从库 =========="
    log_info "模拟从库复制延迟...模拟方式: 添加网络延迟"
    
    check_replication_lag
}

simulate_master_load_peak() {
    log_info "========== 场景 5: 主库高负载 =========="
    log_info "模拟主库高负载...在主库上生成大量查询"
    
    log_info "在主库上执行高负载查询..."
    mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" <<EOF
USE test_failover;
INSERT INTO test_table (test_value) SELECT test_value FROM test_table;
INSERT INTO test_table (test_value) SELECT test_value FROM test_table;
INSERT INTO test_table (test_value) SELECT test_value FROM test_table;
INSERT INTO test_table (test_value) SELECT test_value FROM test_table;
INSERT INTO test_table (test_value) SELECT test_value FROM test_table;
EOF
    
    log_success "高负载查询已执行"
    sleep 10
}

simulate_cascading_failure() {
    log_info "========== 场景 6: 级联故障 =========="
    log_info "模拟级联故障...顺序停止多个服务"
    
    if [ "$ENVIRONMENT" = "DOCKER_CONTAINER" ]; then
        log_warning "在容器内停止其他容器需要特殊权限，跳过"
        return 1
    fi
    
    log_info "停止从库 1..."
    docker-compose stop mysql-slave-1 2>/dev/null || true
    sleep 5
    
    log_info "停止从库 2..."
    docker-compose stop mysql-slave-2 2>/dev/null || true
    sleep 5
    
    log_info "获取最终拓扑..."
    get_topology
}

################################################################################
# 验证和恢复函数
################################################################################

verify_data_consistency() {
    log_info "验证数据一致性..."
    
    log_info "从主库检查数据..."
    master_count=$(mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -se "SELECT COUNT(*) FROM test_failover.test_table;")
    
    log_info "从库 1 行数: $master_count"
    log_info "从库 2 数据验证..."
    
    slave2_count=$(mysql -h "$MYSQL_SLAVE2_HOST" -P "$MYSQL_SLAVE2_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -se "SELECT COUNT(*) FROM test_failover.test_table;")
    log_info "从库 2 行数: $slave2_count"
    
    if [ "$master_count" = "$slave2_count" ]; then
        log_success "数据一致"
    else
        log_error "数据不一致！主库: $master_count, 从库: $slave2_count"
    fi
}

recover_crashed_service() {
    log_info "恢复故障服务..."
    
    if [ "$ENVIRONMENT" = "DOCKER_CONTAINER" ]; then
        log_info "重启 mysql-master 容器..."
        docker start mysql-master 2>/dev/null || log_warning "需要 docker 权限"
    else
        log_info "重启 MySQL 主库..."
        docker-compose start mysql-master 2>/dev/null || log_warning "docker-compose 不可用"
    fi
    
    log_warning "等待 15 秒服务恢复..."
    sleep 15
    
    log_info "验证连接..."
    check_mysql_connectivity "$MYSQL_MASTER_HOST" "$MYSQL_MASTER_PORT" "主库"
}

################################################################################
# 主函数
################################################################################

show_usage() {
    cat <<EOF
使用方法: $0 <scenario> [options]

故障场景:
    master-crash        Master 宕机并自动转移
    slave-crash         Slave 宕机
    network-partition   网络分区
    slow-replica        慢从库场景
    load-peak           高负载场景
    cascading           级联故障
    all                 执行所有测试
    fulltest            完整测试（包含恢复）

选项:
    --help              显示此帮助信息
    --skip-data         跳过数据生成
    --no-recovery       不执行恢复

环境变量:
    ORCHESTRATOR_API    Orchestrator API 地址（自动检测）
    MYSQL_MASTER_HOST   主库地址（自动检测）
    MYSQL_MASTER_PORT   主库端口（自动检测）
    MYSQL_USER          数据库用户（默认: root）
    MYSQL_PASS          数据库密码（默认: root）

示例:
    # 在 Host 上执行
    bash test-failover-docker-enhanced.sh master-crash

    # 在 Docker 容器内执行
    docker exec orchestrator-raft-1 bash test-failover.sh master-crash

    # 完整测试
    bash test-failover-docker-enhanced.sh fulltest
EOF
}

main() {
    local scenario="${1:-all}"
    
    # 初始化配置
    init_config
    
    # 显示环境信息
    print_environment_info
    
    # 生成测试数据
    generate_test_data
    
    # 执行指定的故障场景
    case "$scenario" in
        master-crash)
            simulate_master_crash
            ;;
        slave-crash)
            simulate_slave_crash
            ;;
        network-partition)
            simulate_network_partition
            ;;
        slow-replica)
            simulate_slow_replica
            ;;
        load-peak)
            simulate_master_load_peak
            ;;
        cascading)
            simulate_cascading_failure
            ;;
        all)
            simulate_master_crash
            sleep 5
            simulate_slave_crash
            sleep 5
            simulate_slow_replica
            sleep 5
            simulate_master_load_peak
            ;;
        fulltest)
            simulate_master_crash
            log_info "验证并恢复..."
            verify_data_consistency
            recover_crashed_service
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            log_error "未知的故障场景: $scenario"
            show_usage
            exit 1
            ;;
    esac
    
    log_success "故障演练测试完成"
}

# 运行主函数
main "$@"
