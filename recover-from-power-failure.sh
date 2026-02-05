#!/bin/bash

################################################################################
# 全掉电自动恢复脚本
# 在整个集群同时断电后，自动等待恢复并启动故障转移
# 由 systemd 或 cron 在系统启动时执行
################################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-root}"

RECOVERY_LOG="/var/log/orchestrator/power-recovery.log"
RECOVERY_DIR="/var/log/orchestrator"
MAX_WAIT_TIME=600  # 最长等待 10 分钟
CHECK_INTERVAL=10  # 每 10 秒检查一次

# 日志函数
log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "${BLUE}$msg${NC}" | tee -a "$RECOVERY_LOG"
}

log_success() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1"
    echo -e "${GREEN}$msg${NC}" | tee -a "$RECOVERY_LOG"
}

log_warning() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1"
    echo -e "${YELLOW}$msg${NC}" | tee -a "$RECOVERY_LOG"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "${RED}$msg${NC}" | tee -a "$RECOVERY_LOG"
}

# 创建日志目录
mkdir -p "$RECOVERY_DIR"

################################################################################
# 第一阶段：等待系统稳定
################################################################################

phase_1_wait_for_stability() {
    log_info "════════════════════════════════════════"
    log_info "第一阶段: 等待系统稳定（最长 ${MAX_WAIT_TIME}秒）"
    log_info "════════════════════════════════════════"
    
    local start_time
    start_time=$(date +%s)
    
    log_info "等待 30 秒让电源稳定..."
    sleep 30
    
    log_info "系统已启动，等待服务全部上线..."
}

################################################################################
# 第二阶段：等待 Orchestrator 启动
################################################################################

phase_2_wait_for_orchestrator() {
    log_info "════════════════════════════════════════"
    log_info "第二阶段: 等待 Orchestrator 启动"
    log_info "════════════════════════════════════════"
    
    local elapsed=0
    local max_wait=300  # 5 分钟
    
    while [ $elapsed -lt $max_wait ]; do
        if curl -s -m 2 "$ORCHESTRATOR_API/api/leader-check" &>/dev/null; then
            log_success "Orchestrator 已启动并可访问"
            return 0
        fi
        
        log_info "等待 Orchestrator... (${elapsed}/${max_wait}s)"
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    done
    
    log_error "Orchestrator 启动超时，放弃等待"
    return 1
}

################################################################################
# 第三阶段：等待 Raft Leader 选举
################################################################################

phase_3_wait_for_raft_leader() {
    log_info "════════════════════════════════════════"
    log_info "第三阶段: 等待 Raft Leader 选举"
    log_info "════════════════════════════════════════"
    
    local elapsed=0
    local max_wait=300  # 5 分钟
    local leader_found=0
    
    while [ $elapsed -lt $max_wait ]; do
        local response
        response=$(curl -s "$ORCHESTRATOR_API/api/leader-check" 2>/dev/null || echo '{}')
        
        if echo "$response" | grep -q '"IsLeader":true'; then
            local leader_host
            leader_host=$(echo "$response" | jq -r '.Hostname // "unknown"' 2>/dev/null)
            log_success "Raft Leader 已选举: $leader_host"
            leader_found=1
            break
        fi
        
        # 检查是否有任何 Leader
        local leader_identity
        leader_identity=$(curl -s "$ORCHESTRATOR_API/api/leader-identity" 2>/dev/null || echo '{}')
        
        if [ -n "$(echo "$leader_identity" | grep -o 'Hostname')" ]; then
            log_info "Raft 集群正在形成 Leader (${elapsed}/${max_wait}s)"
        else
            log_warning "Raft 集群尚未形成 Leader (${elapsed}/${max_wait}s)"
        fi
        
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    done
    
    if [ $leader_found -eq 0 ]; then
        log_error "Raft Leader 选举失败（可能少于 2 个节点在线）"
        log_warning "等待更多 Orchestrator 节点启动..."
        return 1
    fi
    
    return 0
}

################################################################################
# 第四阶段：等待 MySQL 启动
################################################################################

phase_4_wait_for_mysql() {
    log_info "════════════════════════════════════════"
    log_info "第四阶段: 等待 MySQL 实例启动"
    log_info "════════════════════════════════════════"
    
    local elapsed=0
    local max_wait=300  # 5 分钟
    
    while [ $elapsed -lt $max_wait ]; do
        if mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1;" &>/dev/null; then
            log_success "MySQL Master 已启动并可访问"
            return 0
        fi
        
        log_info "等待 MySQL... (${elapsed}/${max_wait}s)"
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    done
    
    log_error "MySQL 启动超时"
    return 1
}

################################################################################
# 第五阶段：检查拓扑状态
################################################################################

phase_5_check_topology() {
    log_info "════════════════════════════════════════"
    log_info "第五阶段: 检查 MySQL 拓扑状态"
    log_info "════════════════════════════════════════"
    
    local response
    response=$(curl -s "$ORCHESTRATOR_API/api/cluster/master-slave" 2>/dev/null || echo '{}')
    
    if [ -z "$response" ] || [ "$response" = '{}' ]; then
        log_error "无法获取拓扑信息"
        return 1
    fi
    
    log_info "当前拓扑信息:"
    echo "$response" | jq . 2>/dev/null | tee -a "$RECOVERY_LOG" || echo "$response" >> "$RECOVERY_LOG"
    
    # 检查是否需要故障转移
    local is_master_dead
    is_master_dead=$(echo "$response" | jq -r '.[].IsLastCheckValid // true' | grep -c 'false' || echo 0)
    
    if [ "$is_master_dead" -gt 0 ]; then
        log_warning "检测到 Master 可能不可用，需要故障转移"
        return 2  # 特殊返回码：需要转移
    else
        log_success "拓扑检查完成，系统正常"
        return 0
    fi
}

################################################################################
# 第六阶段：触发故障转移（如需）
################################################################################

phase_6_trigger_failover() {
    log_info "════════════════════════════════════════"
    log_info "第六阶段: 触发故障转移（如需）"
    log_info "════════════════════════════════════════"
    
    local response
    response=$(curl -s -X POST "$ORCHESTRATOR_API/api/recover/cluster/master-slave" 2>/dev/null || echo '{}')
    
    if echo "$response" | grep -q '"Code":"SUCCESS"'; then
        log_success "故障转移已触发"
        
        # 等待转移完成
        log_info "等待转移完成（最长 120 秒）..."
        sleep 30
        
        local elapsed=0
        while [ $elapsed -lt 120 ]; do
            local topo
            topo=$(curl -s "$ORCHESTRATOR_API/api/cluster/master-slave" 2>/dev/null || echo '{}')
            
            # 检查转移是否完成
            if echo "$topo" | grep -q '"HasRecentPrimaryCheck":true'; then
                log_success "故障转移完成"
                return 0
            fi
            
            sleep 10
            elapsed=$((elapsed + 10))
        done
        
        log_warning "故障转移可能仍在进行中"
        return 0
    else
        log_info "不需要故障转移或系统已恢复"
        return 0
    fi
}

################################################################################
# 第七阶段：验证系统状态
################################################################################

phase_7_verify_system() {
    log_info "════════════════════════════════════════"
    log_info "第七阶段: 验证系统状态"
    log_info "════════════════════════════════════════"
    
    local health_score=100
    
    # 1. 检查 Orchestrator
    if ! curl -s -m 2 "$ORCHESTRATOR_API/api/leader-check" &>/dev/null; then
        log_error "Orchestrator 检查失败"
        health_score=$((health_score - 30))
    else
        log_success "Orchestrator: OK"
    fi
    
    # 2. 检查 MySQL Master
    if ! mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1;" &>/dev/null; then
        log_error "MySQL Master 检查失败"
        health_score=$((health_score - 40))
    else
        log_success "MySQL Master: OK"
    fi
    
    # 3. 检查复制状态
    local slave_status
    slave_status=$(mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SHOW SLAVE STATUS\G" 2>/dev/null || echo "")
    
    if [ -z "$slave_status" ]; then
        log_info "本节点可能是 Master（不需要检查 Slave 状态）"
    else
        local slave_running
        slave_running=$(echo "$slave_status" | grep "Slave_IO_Running:" | awk '{print $2}')
        
        if [ "$slave_running" = "Yes" ]; then
            log_success "复制: OK"
        else
            log_warning "复制: 异常"
            health_score=$((health_score - 20))
        fi
    fi
    
    echo ""
    log_info "系统健康评分: $health_score/100"
    
    if [ $health_score -ge 80 ]; then
        log_success "系统恢复成功！"
        return 0
    else
        log_warning "系统部分故障，需要人工检查"
        return 1
    fi
}

################################################################################
# 最终报告
################################################################################

generate_report() {
    log_info "════════════════════════════════════════"
    log_info "恢复报告"
    log_info "════════════════════════════════════════"
    log_info "开始时间: $(head -1 "$RECOVERY_LOG" | cut -d']' -f1)"
    log_info "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "日志文件: $RECOVERY_LOG"
    log_info ""
    
    # 通知管理员
    if command -v mail &>/dev/null && [ -n "$ALERT_EMAIL" ]; then
        local subject="Power Failure Recovery Report"
        local body=$(tail -20 "$RECOVERY_LOG")
        echo "$body" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || true
        log_info "邮件通知已发送"
    fi
}

################################################################################
# 主流程
################################################################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║        Orchestrator Raft 全掉电自动恢复系统                     ║"
    echo "║  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    
    log_info "开始恢复流程..."
    log_info "Orchestrator API: $ORCHESTRATOR_API"
    log_info "MySQL Master: $MYSQL_MASTER_HOST:$MYSQL_MASTER_PORT"
    
    # 第一阶段
    phase_1_wait_for_stability
    
    # 第二阶段
    phase_2_wait_for_orchestrator || {
        log_error "无法启动 Orchestrator，放弃自动恢复"
        generate_report
        exit 1
    }
    
    # 第三阶段
    if ! phase_3_wait_for_raft_leader; then
        log_warning "Raft Leader 未成功选举，尝试手动触发恢复..."
        # 不退出，继续尝试
    fi
    
    # 第四阶段
    phase_4_wait_for_mysql || {
        log_warning "MySQL 未启动，Orchestrator 可能自动处理了故障转移"
    }
    
    # 第五阶段
    phase_5_check_topology
    local topo_result=$?
    
    # 第六阶段（如需）
    if [ $topo_result -eq 2 ]; then
        phase_6_trigger_failover
    fi
    
    # 第七阶段
    phase_7_verify_system
    local verify_result=$?
    
    # 最终报告
    generate_report
    
    echo ""
    if [ $verify_result -eq 0 ]; then
        log_success "╔═══════════════════════════════════════╗"
        log_success "║   恢复成功！系统已全部上线   ✅      ║"
        log_success "╚═══════════════════════════════════════╝"
        exit 0
    else
        log_warning "╔═══════════════════════════════════════╗"
        log_warning "║   部分恢复，需要人工检查   ⚠️      ║"
        log_warning "╚═══════════════════════════════════════╝"
        exit 1
    fi
}

# 运行主程序
main "$@"
