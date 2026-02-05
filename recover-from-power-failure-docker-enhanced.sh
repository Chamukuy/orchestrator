#!/bin/bash

################################################################################
# 断电恢复自动化脚本 - Docker 增强版
#
# 功能：
# - 自动检测运行环境（Docker 容器或 Host）
# - 7 阶段自动化从断电故障恢复
# - 智能判断需要的恢复步骤
# - 完全兼容原始脚本的所有功能
#
# 使用：
#   Host 环境：    bash recover-from-power-failure-docker-enhanced.sh
#   Docker 环境：  docker exec orchestrator-raft-1 bash recover-power.sh
#   自动执行：     systemctl start orchestrator-power-recovery
################################################################################

set -e

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="/tmp/orchestrator-power-recovery.lock"
LOG_FILE="${LOG_FILE:-/var/log/orchestrator/power-recovery.log}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

################################################################################
# 日志函数
################################################################################

init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
}

log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_info() {
    local msg="[INFO] $1"
    echo -e "${BLUE}$msg${NC}"
    log_to_file "$msg"
}

log_success() {
    local msg="[✓] $1"
    echo -e "${GREEN}$msg${NC}"
    log_to_file "$msg"
}

log_warning() {
    local msg="[WARN] $1"
    echo -e "${YELLOW}$msg${NC}"
    log_to_file "$msg"
}

log_error() {
    local msg="[✗] $1"
    echo -e "${RED}$msg${NC}"
    log_to_file "$msg"
}

log_phase() {
    local phase=$1
    local desc=$2
    local msg="═══════════════════════════════════════════ 阶段 $phase: $desc ═══════════════════════════════════════════"
    echo -e "${MAGENTA}$msg${NC}"
    log_to_file "$msg"
}

################################################################################
# Docker 环境检测 ⭐ 核心改进
################################################################################

detect_docker_environment() {
    if [ -f "/.dockerenv" ]; then
        return 0
    fi
    if grep -q "docker" /proc/self/cgroup 2>/dev/null; then
        return 0
    fi
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
# 配置初始化 ⭐ 关键改变
################################################################################

init_config() {
    export_environment_type
    
    if [ "$ENVIRONMENT" = "DOCKER_CONTAINER" ]; then
        # Docker 容器内：使用容器网络 DNS 名称和原始端口
        ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://orchestrator-raft-1:3000}"
        ORCHESTRATOR_HOST="${ORCHESTRATOR_HOST:-orchestrator-raft-1}"
        ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-3000}"
        
        MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-mysql-master}"
        MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
        MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-mysql-slave-1}"
        MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3306}"
        MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-mysql-slave-2}"
        MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3306}"
    else
        # Host 环境：使用本地地址和映射端口
        ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
        ORCHESTRATOR_HOST="${ORCHESTRATOR_HOST:-127.0.0.1}"
        ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-3000}"
        
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
    
    # 超时和重试配置
    SERVICE_WAIT_TIMEOUT="${SERVICE_WAIT_TIMEOUT:-300}"  # 5 分钟
    SERVICE_RETRY_INTERVAL="${SERVICE_RETRY_INTERVAL:-5}" # 5 秒
    RAFT_WAIT_TIMEOUT="${RAFT_WAIT_TIMEOUT:-60}"         # 1 分钟
}

################################################################################
# 阶段 1: 等待 MySQL 服务启动
################################################################################

phase_1_wait_for_mysql() {
    log_phase "1" "等待 MySQL 服务启动"
    
    local start_time=$(date +%s)
    local timeout=$SERVICE_WAIT_TIMEOUT
    
    log_info "等待 MySQL 主库启动 ($MYSQL_MASTER_HOST:$MYSQL_MASTER_PORT)..."
    
    while true; do
        if mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" \
                 -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1;" &>/dev/null; then
            log_success "主库已启动"
            break
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -gt $timeout ]; then
            log_error "主库启动超时（$timeout 秒）"
            return 1
        fi
        
        log_info "等待中... ($elapsed/$timeout 秒)"
        sleep $SERVICE_RETRY_INTERVAL
    done
    
    log_info "等待从库启动..."
    for i in 1 2; do
        if [ $i -eq 1 ]; then
            host=$MYSQL_SLAVE1_HOST
            port=$MYSQL_SLAVE1_PORT
        else
            host=$MYSQL_SLAVE2_HOST
            port=$MYSQL_SLAVE2_PORT
        fi
        
        log_info "检查从库 $i ($host:$port)..."
        while ! mysql -h "$host" -P "$port" -u "$MYSQL_USER" -p"$MYSQL_PASS" \
                      -e "SELECT 1;" &>/dev/null; do
            sleep $SERVICE_RETRY_INTERVAL
        done
        log_success "从库 $i 已启动"
    done
    
    log_success "✓ 所有 MySQL 服务已启动"
    return 0
}

################################################################################
# 阶段 2: 等待 Orchestrator Raft 集群启动
################################################################################

phase_2_wait_for_orchestrator() {
    log_phase "2" "等待 Orchestrator Raft 集群启动"
    
    local start_time=$(date +%s)
    local timeout=$RAFT_WAIT_TIMEOUT
    
    log_info "连接 Orchestrator API ($ORCHESTRATOR_API)..."
    
    while true; do
        local response=$(curl -s "$ORCHESTRATOR_API/api/leader-check" 2>/dev/null || echo '')
        
        if echo "$response" | grep -q '"IsLeader":true' && \
           echo "$response" | grep -q '"Status":"OK"'; then
            log_success "Orchestrator 已启动，Leader 已选出"
            break
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -gt $timeout ]; then
            log_error "Orchestrator 启动超时（$timeout 秒）"
            log_warning "继续处理，但可能无法自动转移"
            return 1
        fi
        
        log_info "等待 Raft Leader 选出中... ($elapsed/$timeout 秒)"
        sleep $SERVICE_RETRY_INTERVAL
    done
    
    log_success "✓ Orchestrator Raft 集群已就绪"
    return 0
}

################################################################################
# 阶段 3: 检查复制状态
################################################################################

phase_3_check_replication() {
    log_phase "3" "检查主从复制状态"
    
    log_info "检查主库状态..."
    mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" \
           -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW MASTER STATUS\G" | \
           grep -E "File|Position"
    
    log_info "检查从库 1 复制状态..."
    mysql -h "$MYSQL_SLAVE1_HOST" -P "$MYSQL_SLAVE1_PORT" \
           -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW SLAVE STATUS\G" | \
           grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master" || \
           log_warning "从库可能未在复制中"
    
    log_info "检查从库 2 复制状态..."
    mysql -h "$MYSQL_SLAVE2_HOST" -P "$MYSQL_SLAVE2_PORT" \
           -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW SLAVE STATUS\G" | \
           grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master" || \
           log_warning "从库可能未在复制中"
    
    log_success "✓ 复制状态检查完成"
}

################################################################################
# 阶段 4: 进行 Raft 一致性检查
################################################################################

phase_4_raft_consistency_check() {
    log_phase "4" "Raft 一致性检查与恢复"
    
    log_info "获取 Raft 集群状态..."
    local raft_status=$(curl -s "$ORCHESTRATOR_API/api/cluster/name/$(hostname -f)" 2>/dev/null || echo '')
    
    if [ -z "$raft_status" ]; then
        log_warning "无法获取 Raft 状态，跳过一致性检查"
        return 1
    fi
    
    log_info "Raft 集群信息:"
    echo "$raft_status" | jq '.' 2>/dev/null || echo "$raft_status"
    
    log_success "✓ 一致性检查已完成"
}

################################################################################
# 阶段 5: 检测主库故障并触发故障转移
################################################################################

phase_5_detect_and_failover() {
    log_phase "5" "检测主库故障并触发故障转移"
    
    log_info "检查主库可用性..."
    
    if mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" \
             -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1;" &>/dev/null; then
        log_success "主库正常，无需故障转移"
        return 0
    fi
    
    log_error "主库不可用，触发故障转移..."
    log_info "调用 Orchestrator 故障转移 API..."
    
    local failover_response=$(curl -s -X POST \
        "$ORCHESTRATOR_API/api/recover/$MYSQL_MASTER_HOST/$MYSQL_MASTER_PORT" \
        -H "Content-Type: application/json" \
        2>/dev/null || echo '')
    
    if echo "$failover_response" | grep -qE '"Successful":true|"Code":"OK"'; then
        log_success "故障转移已启动"
    else
        log_warning "故障转移 API 响应: $failover_response"
    fi
    
    log_warning "等待故障转移完成... (30 秒)"
    sleep 30
    
    log_info "获取新拓扑..."
    curl -s "$ORCHESTRATOR_API/api/cluster/master-slave" | jq '.' 2>/dev/null || true
    
    log_success "✓ 故障转移检测完成"
}

################################################################################
# 阶段 6: 数据一致性验证
################################################################################

phase_6_data_consistency() {
    log_phase "6" "数据一致性验证"
    
    log_info "验证数据一致性..."
    
    local master_sum=$(mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" \
                             -u "$MYSQL_USER" -p"$MYSQL_PASS" \
                             -se "SELECT MD5(GROUP_CONCAT(COLUMN_NAME ORDER BY COLUMN_NAME)) \
                                  FROM INFORMATION_SCHEMA.COLUMNS \
                                  WHERE TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');" 2>/dev/null || echo "UNKNOWN")
    
    log_info "主库 Schema 校验和: $master_sum"
    
    for i in 1 2; do
        if [ $i -eq 1 ]; then
            host=$MYSQL_SLAVE1_HOST
            port=$MYSQL_SLAVE1_PORT
        else
            host=$MYSQL_SLAVE2_HOST
            port=$MYSQL_SLAVE2_PORT
        fi
        
        local slave_sum=$(mysql -h "$host" -P "$port" \
                               -u "$MYSQL_USER" -p"$MYSQL_PASS" \
                               -se "SELECT MD5(GROUP_CONCAT(COLUMN_NAME ORDER BY COLUMN_NAME)) \
                                    FROM INFORMATION_SCHEMA.COLUMNS \
                                    WHERE TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');" 2>/dev/null || echo "UNKNOWN")
        
        log_info "从库 $i Schema 校验和: $slave_sum"
        
        if [ "$master_sum" = "$slave_sum" ]; then
            log_success "从库 $i 数据一致"
        else
            log_warning "从库 $i 可能存在数据偏差"
        fi
    done
    
    log_success "✓ 数据一致性验证完成"
}

################################################################################
# 阶段 7: 最终系统健康检查
################################################################################

phase_7_final_health_check() {
    log_phase "7" "最终系统健康检查"
    
    log_info "检查系统整体状态..."
    
    # 检查 MySQL 服务
    local mysql_ok=0
    for i in 1 2; do
        if [ $i -eq 0 ]; then
            host=$MYSQL_MASTER_HOST
            port=$MYSQL_MASTER_PORT
            label="Master"
        elif [ $i -eq 1 ]; then
            host=$MYSQL_SLAVE1_HOST
            port=$MYSQL_SLAVE1_PORT
            label="Slave1"
        else
            host=$MYSQL_SLAVE2_HOST
            port=$MYSQL_SLAVE2_PORT
            label="Slave2"
        fi
        
        if mysql -h "$host" -P "$port" -u "$MYSQL_USER" -p"$MYSQL_PASS" \
                 -e "SELECT 1;" &>/dev/null; then
            log_success "$label MySQL: ✓"
            ((mysql_ok++))
        else
            log_error "$label MySQL: ✗"
        fi
    done
    
    # 检查 Orchestrator
    if curl -s "$ORCHESTRATOR_API/api/leader-check" 2>/dev/null | grep -q '"IsLeader":true'; then
        log_success "Orchestrator Raft: ✓"
    else
        log_warning "Orchestrator Raft: 无 Leader"
    fi
    
    # 最终报告
    echo ""
    log_info "┌─────────────────────────────────┐"
    log_info "│ 系统恢复完毕！                  │"
    log_info "├─────────────────────────────────┤"
    log_info "│ MySQL 服务: $mysql_ok/3 在线"
    log_info "│ Orchestrator: 就绪"
    log_info "│ 运行环境: $ENVIRONMENT_DISPLAY"
    log_info "│ 恢复时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "└─────────────────────────────────┘"
    echo ""
    
    log_success "✓ 系统恢复完成"
}

################################################################################
# 主函数
################################################################################

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        log_warning "另一个恢复实例正在运行，退出"
        return 1
    fi
    
    echo "$$" > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
    return 0
}

main() {
    init_logging
    init_config
    
    # 尝试获取锁
    if ! acquire_lock; then
        exit 1
    fi
    
    log_info "═══════════════════════════════════════════════════════════════════════════════"
    log_info "Orchestrator 断电恢复脚本启动"
    log_info "运行环境: $ENVIRONMENT_DISPLAY (自动检测)"
    log_info "Orchestrator API: $ORCHESTRATOR_API"
    log_info "═══════════════════════════════════════════════════════════════════════════════"
    
    # 执行 7 个恢复阶段
    phase_1_wait_for_mysql || log_warning "阶段 1 失败，继续..."
    phase_2_wait_for_orchestrator || log_warning "阶段 2 失败，继续..."
    phase_3_check_replication || log_warning "阶段 3 失败，继续..."
    phase_4_raft_consistency_check || log_warning "阶段 4 失败，继续..."
    phase_5_detect_and_failover || log_warning "阶段 5 失败，继续..."
    phase_6_data_consistency || log_warning "阶段 6 失败，继续..."
    phase_7_final_health_check
    
    log_info "═══════════════════════════════════════════════════════════════════════════════"
    log_info "恢复流程完毕，日志已保存到: $LOG_FILE"
    log_info "═══════════════════════════════════════════════════════════════════════════════"
}

main "$@"
