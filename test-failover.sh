#!/bin/bash

################################################################################
# Orchestrator Raft 故障演练测试脚本
# 模拟各种故障场景，验证自动转移和恢复机制
################################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# 配置变量
ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-127.0.0.1}"
MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3307}"
MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-127.0.0.1}"
MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3308}"

# 测试数据库用户
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-root}"

DISCOVERY_INTERVAL=5  # 发现间隔（秒）

################################################################################
# 辅助函数
################################################################################

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
CREATE DATABASE IF NOT EXISTS failover_test;
DROP TABLE IF EXISTS failover_test.test_table;
CREATE TABLE failover_test.test_table (
    id INT AUTO_INCREMENT PRIMARY KEY,
    test_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    test_value VARCHAR(255)
);
INSERT INTO failover_test.test_table (test_value) VALUES ('Initial setup');
EOF
    
    log_success "测试数据生成完成"
}

verify_replication() {
    log_info "验证复制延迟..."
    
    local master_seconds_behind=0
    local slave1_seconds_behind=0
    local slave2_seconds_behind=0
    
    # 检查 Slave1
    slave1_seconds_behind=$(mysql -h "$MYSQL_SLAVE1_HOST" -P "$MYSQL_SLAVE1_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master" | awk '{print $2}' || echo "NULL")
    
    # 检查 Slave2
    slave2_seconds_behind=$(mysql -h "$MYSQL_SLAVE2_HOST" -P "$MYSQL_SLAVE2_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master" | awk '{print $2}' || echo "NULL")
    
    if [ "$slave1_seconds_behind" = "NULL" ] || [ "$slave2_seconds_behind" = "NULL" ]; then
        log_warning "复制可能未启动或配置有误"
        return 1
    fi
    
    log_success "Slave1 延迟: ${slave1_seconds_behind}s, Slave2 延迟: ${slave2_seconds_behind}s"
    
    if [ "$slave1_seconds_behind" -le 5 ] && [ "$slave2_seconds_behind" -le 5 ]; then
        log_success "复制同步良好"
        return 0
    else
        log_warning "复制存在较大延迟"
        return 1
    fi
}

wait_for_failover() {
    local timeout=$1
    local elapsed=0
    local check_interval=2
    
    log_info "等待故障转移完成（最长 ${timeout}s）..."
    
    while [ $elapsed -lt "$timeout" ]; do
        local topo
        topo=$(get_topology)
        
        # 检查是否有新的 Master
        if echo "$topo" | grep -q '"IsOfGroupId":1'; then
            log_success "故障转移已完成"
            return 0
        fi
        
        echo -ne "\r进度: ${elapsed}s / ${timeout}s"
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    echo ""
    log_warning "等待超时，故障转移可能未成功"
    return 1
}

################################################################################
# 测试场景
################################################################################

test_scenario_1_master_crash() {
    echo ""
    log_info "=========================================="
    log_info "测试场景 1: Master 宕机自动转移"
    log_info "=========================================="
    
    # 前置检查
    log_info "前置条件检查..."
    check_mysql_connectivity "$MYSQL_MASTER_HOST" "$MYSQL_MASTER_PORT" "Master"
    check_mysql_connectivity "$MYSQL_SLAVE1_HOST" "$MYSQL_SLAVE1_PORT" "Slave1"
    check_mysql_connectivity "$MYSQL_SLAVE2_HOST" "$MYSQL_SLAVE2_PORT" "Slave2"
    
    get_orchestrator_status || {
        log_error "Orchestrator 不可用，跳过此测试"
        return 1
    }
    
    # 生成测试数据
    generate_test_data
    sleep 2
    verify_replication
    
    # 记录转移前的数据
    log_info "记录转移前的数据..."
    local before_binlog
    before_binlog=$(mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SHOW MASTER STATUS\G" 2>/dev/null | grep "File" | awk '{print $2}')
    log_success "当前 Binlog: $before_binlog"
    
    # 停止 Master
    log_warning "停止 Master..."
    if docker ps | grep -q mysql-master; then
        docker stop mysql-master || true
        log_success "Master 容器已停止"
    else
        # 本地 MySQL，使用 mysqladmin
        mysqladmin -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" shutdown 2>/dev/null || {
            log_warning "无法停止本地 MySQL，跳过此测试"
            return 1
        }
    fi
    
    sleep 2
    
    # 检查连通性
    if ! check_mysql_connectivity "$MYSQL_MASTER_HOST" "$MYSQL_MASTER_PORT" "Master"; then
        log_success "Master 已停止"
    fi
    
    # 等待故障转移
    wait_for_failover 120
    
    # 验证转移结果
    log_info "验证故障转移结果..."
    local topo
    topo=$(get_topology)
    
    if echo "$topo" | grep -q '"OfGroupId":0'; then
        log_success "新 Master 已选举"
        echo "$topo" | jq . 2>/dev/null || echo "$topo"
    else
        log_error "故障转移失败"
        echo "拓扑信息：$topo"
    fi
    
    # 验证新 Master 可写入
    log_info "验证新 Master 可写入..."
    if mysql -h "$MYSQL_SLAVE1_HOST" -P "$MYSQL_SLAVE1_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "INSERT INTO failover_test.test_table (test_value) VALUES ('After failover');" 2>/dev/null; then
        log_success "新 Master 写入成功"
    else
        log_error "新 Master 写入失败"
    fi
    
    # 恢复原 Master
    log_info "恢复原 Master..."
    if docker ps -a | grep -q mysql-master; then
        docker start mysql-master || true
        sleep 5
    fi
    
    if check_mysql_connectivity "$MYSQL_MASTER_HOST" "$MYSQL_MASTER_PORT" "Master"; then
        log_success "原 Master 已恢复"
    fi
}

test_scenario_2_slave_lag() {
    echo ""
    log_info "=========================================="
    log_info "测试场景 2: Slave 延迟处理"
    log_info "=========================================="
    
    log_info "检查 Slave 延迟..."
    verify_replication
    
    # 获取当前延迟
    local slave1_lag
    slave1_lag=$(mysql -h "$MYSQL_SLAVE1_HOST" -P "$MYSQL_SLAVE1_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master" | awk '{print $2}')
    
    if [ -z "$slave1_lag" ] || [ "$slave1_lag" = "NULL" ]; then
        log_warning "无法获取 Slave 延迟信息"
        return 1
    fi
    
    log_success "Slave1 当前延迟: ${slave1_lag}s"
    
    if [ "$slave1_lag" -gt 5 ]; then
        log_warning "检测到较大延迟，Orchestrator 可能限制此 Slave 的转移"
    fi
}

test_scenario_3_network_partition() {
    echo ""
    log_info "=========================================="
    log_info "测试场景 3: 网络分割检测"
    log_info "=========================================="
    
    log_info "检查 Orchestrator Raft 节点连通性..."
    
    for i in 1 2 3; do
        local port=$((3000 + i - 1))
        if curl -s -m 2 "http://127.0.0.1:$port/api/leader-check" &>/dev/null; then
            log_success "Orchestrator 节点 $i (端口 $port) 可连接"
        else
            log_warning "Orchestrator 节点 $i (端口 $port) 无法连接"
        fi
    done
    
    log_info "在真实网络分割场景中，Raft 将自动选择多数派节点"
}

test_scenario_4_readonly_promotion() {
    echo ""
    log_info "=========================================="
    log_info "测试场景 4: 只读 Slave 晋升"
    log_info "=========================================="
    
    log_info "检查 Slave 读写状态..."
    
    local slave1_ro
    slave1_ro=$(mysql -h "$MYSQL_SLAVE1_HOST" -P "$MYSQL_SLAVE1_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SELECT @@read_only;" 2>/dev/null)
    
    if [ "$slave1_ro" = "1" ]; then
        log_success "Slave1 处于只读模式（正确）"
    else
        log_warning "Slave1 未处于只读模式"
    fi
    
    # 模拟晋升
    log_info "如果 Master 故障，Slave 将被晋升为 Master"
    log_info "晋升过程包括："
    log_info "  1. 等待复制完成"
    log_info "  2. 停止复制"
    log_info "  3. 设置 read_only=0"
    log_info "  4. 更新拓扑"
    log_info "  5. 其他 Slave 重新指向新 Master"
}

test_scenario_5_orchestrator_restart() {
    echo ""
    log_info "=========================================="
    log_info "测试场景 5: Orchestrator 重启恢复"
    log_info "=========================================="
    
    log_info "此场景演示 Orchestrator 节点故障后的恢复..."
    
    if docker ps | grep -q orchestrator-raft-1; then
        log_info "停止 Orchestrator 节点 1..."
        docker stop orchestrator-raft-1 || true
        sleep 3
        
        log_warning "Orchestrator 节点 1 已停止"
        log_info "其他节点将继续工作并重新选举 Leader"
        
        sleep 5
        
        log_info "重启 Orchestrator 节点 1..."
        docker start orchestrator-raft-1 || true
        sleep 3
        
        if get_orchestrator_status; then
            log_success "Orchestrator 已恢复"
        fi
    else
        log_warning "Orchestrator 无法重启（可能不是 Docker 环境）"
    fi
}

test_scenario_6_data_consistency() {
    echo ""
    log_info "=========================================="
    log_info "测试场景 6: 数据一致性检验"
    log_info "=========================================="
    
    log_info "检查 Master 和 Slave 数据一致性..."
    
    # 在 Master 上写入测试数据
    local test_row_id
    test_row_id=$(mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "INSERT INTO failover_test.test_table (test_value) VALUES ('consistency-check-$(date +%s)'); SELECT LAST_INSERT_ID();" 2>/dev/null)
    
    log_info "在 Master 上插入测试行: ID=$test_row_id"
    
    # 等待复制
    sleep 3
    
    # 在 Slave 上验证
    local slave1_count
    slave1_count=$(mysql -h "$MYSQL_SLAVE1_HOST" -P "$MYSQL_SLAVE1_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SELECT COUNT(*) FROM failover_test.test_table WHERE id=$test_row_id;" 2>/dev/null)
    
    local slave2_count
    slave2_count=$(mysql -h "$MYSQL_SLAVE2_HOST" -P "$MYSQL_SLAVE2_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SELECT COUNT(*) FROM failover_test.test_table WHERE id=$test_row_id;" 2>/dev/null)
    
    if [ "$slave1_count" = "1" ] && [ "$slave2_count" = "1" ]; then
        log_success "数据一致性验证通过"
    else
        log_error "数据一致性检验失败: Slave1=$slave1_count, Slave2=$slave2_count"
    fi
}

################################################################################
# 清理函数
################################################################################

cleanup() {
    log_info "清理测试环境..."
    
    # 删除测试数据库
    mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "DROP DATABASE IF EXISTS failover_test;" 2>/dev/null || true
    
    log_success "清理完成"
}

################################################################################
# 主函数
################################################################################

main() {
    local scenario="${1:-all}"
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Orchestrator Raft 故障演练测试框架                             ║"
    echo "║  API: $ORCHESTRATOR_API"
    echo "║  Master: $MYSQL_MASTER_HOST:$MYSQL_MASTER_PORT"
    echo "║  Slave1: $MYSQL_SLAVE1_HOST:$MYSQL_SLAVE1_PORT"
    echo "║  Slave2: $MYSQL_SLAVE2_HOST:$MYSQL_SLAVE2_PORT"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    
    case "$scenario" in
        1|master-crash)
            test_scenario_1_master_crash
            ;;
        2|slave-lag)
            test_scenario_2_slave_lag
            ;;
        3|network-partition)
            test_scenario_3_network_partition
            ;;
        4|readonly-promotion)
            test_scenario_4_readonly_promotion
            ;;
        5|orchestrator-restart)
            test_scenario_5_orchestrator_restart
            ;;
        6|data-consistency)
            test_scenario_6_data_consistency
            ;;
        all)
            test_scenario_1_master_crash || true
            test_scenario_2_slave_lag
            test_scenario_3_network_partition
            test_scenario_4_readonly_promotion
            test_scenario_5_orchestrator_restart
            test_scenario_6_data_consistency
            ;;
        help)
            show_help
            ;;
        *)
            log_error "未知的测试场景: $scenario"
            show_help
            exit 1
            ;;
    esac
    
    cleanup
    
    echo ""
    log_success "测试完成"
}

show_help() {
    cat <<EOF
用法: bash test-failover.sh [SCENARIO]

测试场景:
  1, master-crash          - Master 宕机自动转移
  2, slave-lag             - Slave 延迟处理
  3, network-partition     - 网络分割检测
  4, readonly-promotion    - 只读 Slave 晋升
  5, orchestrator-restart  - Orchestrator 重启恢复
  6, data-consistency      - 数据一致性检验
  all                      - 运行所有测试（默认）
  help                     - 显示此帮助信息

环境变量:
  ORCHESTRATOR_API         Orchestrator API 地址 (默认: http://127.0.0.1:3000)
  MYSQL_MASTER_HOST        Master 主机名 (默认: 127.0.0.1)
  MYSQL_MASTER_PORT        Master 端口 (默认: 3306)
  MYSQL_SLAVE1_HOST        Slave1 主机名 (默认: 127.0.0.1)
  MYSQL_SLAVE1_PORT        Slave1 端口 (默认: 3307)
  MYSQL_SLAVE2_HOST        Slave2 主机名 (默认: 127.0.0.1)
  MYSQL_SLAVE2_PORT        Slave2 端口 (默认: 3308)
  MYSQL_USER               MySQL 用户名 (默认: root)
  MYSQL_PASS               MySQL 密码 (默认: root)

示例:
  # 运行所有测试
  bash test-failover.sh all

  # 只运行 Master 宕机测试
  bash test-failover.sh master-crash

  # 指定远端服务器运行测试
  ORCHESTRATOR_API=http://192.168.1.100:3000 \\
  MYSQL_MASTER_HOST=192.168.1.10 \\
  bash test-failover.sh all
EOF
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
else
    main "$@"
fi
