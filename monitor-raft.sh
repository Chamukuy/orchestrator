#!/bin/bash

################################################################################
# Orchestrator Raft 及 ProxySQL 实时监控脚本
# 持续监控系统健康状况、故障和性能指标
################################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-127.0.0.1}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_ADMIN_USER="${PROXYSQL_ADMIN_USER:-admin}"
PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-127.0.0.1}"
MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3307}"
MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-127.0.0.1}"
MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3308}"

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-root}"

MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"  # 监控间隔（秒）
LOG_DIR="${LOG_DIR:-/var/log/orchestrator-monitor}"
ALERT_THRESHOLD="${ALERT_THRESHOLD:-30}"  # 告警自动触发阈值（秒）

# 日志函数
log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${BLUE}[INFO]${NC} $1" | tee -a "$LOG_DIR/monitor.log"
}

log_success() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${GREEN}[✓]${NC} $1" | tee -a "$LOG_DIR/monitor.log"
}

log_warning() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_DIR/monitor.log"
}

log_error() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${RED}[✗]${NC} $1" | tee -a "$LOG_DIR/monitor.log"
}

log_alert() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${RED}[ALERT]${NC} $1" | tee -a "$LOG_DIR/alerts.log"
    # 触发告警脚本（如有配置）
    if [ -n "$ALERT_SCRIPT" ] && [ -x "$ALERT_SCRIPT" ]; then
        bash "$ALERT_SCRIPT" "Orchestrator Alert" "$1" 2>/dev/null || true
    fi
}

# 初始化
init_monitor() {
    mkdir -p "$LOG_DIR"
    log_info "监控系统启动"
    log_info "Orchestrator API: $ORCHESTRATOR_API"
    log_info "ProxySQL Admin: $PROXYSQL_ADMIN_HOST:$PROXYSQL_ADMIN_PORT"
    log_info "监控间隔: ${MONITOR_INTERVAL}s"
}

################################################################################
# Raft 集群监控
################################################################################

monitor_raft_cluster() {
    echo ""
    echo -e "${CYAN}═══ Orchestrator Raft 集群状态 ════════════════════════════${NC}"
    
    local response
    response=$(curl -s "$ORCHESTRATOR_API/api/leader-check" 2>/dev/null || echo '{}')
    
    if [ -z "$(echo "$response" | grep -o 'IsLeader')" ]; then
        log_error "无法连接 Orchestrator API"
        return 1
    fi
    
    # 检查 Leader
    if echo "$response" | grep -q '"IsLeader":true'; then
        local leader_host
        leader_host=$(echo "$response" | jq -r '.Hostname // "unknown"' 2>/dev/null)
        log_success "Raft Leader: $leader_host"
    else
        log_warning "当前节点不是 Leader"
    fi
    
    # 获取集群信息
    local cluster_response
    cluster_response=$(curl -s "$ORCHESTRATOR_API/api/leader-identity" 2>/dev/null || echo '{}')
    
    if echo "$cluster_response" | jq . &>/dev/null; then
        local leader
        leader=$(echo "$cluster_response" | jq -r '.Hostname // "unknown"' 2>/dev/null)
        log_info "当前Leader: $leader"
    fi
}

################################################################################
# MySQL 拓扑监控
################################################################################

monitor_mysql_topology() {
    echo ""
    echo -e "${CYAN}═══ MySQL 拓扑状态 ════════════════════════════════════╗${NC}"
    
    # Master 状态
    local master_status
    master_status=$(mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SHOW MASTER STATUS\G" 2>/dev/null || echo "")
    
    if [ -z "$master_status" ]; then
        log_error "Master 无法连接 ($MYSQL_MASTER_HOST:$MYSQL_MASTER_PORT)"
        return 1
    fi
    
    local binlog_file
    binlog_file=$(echo "$master_status" | grep "File:" | awk '{print $2}')
    local binlog_pos
    binlog_pos=$(echo "$master_status" | grep "Position:" | awk '{print $2}')
    
    log_success "Master: $MYSQL_MASTER_HOST:$MYSQL_MASTER_PORT"
    log_info "  Binlog: $binlog_file @ $binlog_pos"
    
    # Slave 状态
    for slave_host in $MYSQL_SLAVE1_HOST $MYSQL_SLAVE2_HOST; do
        local slave_port
        if [ "$slave_host" = "$MYSQL_SLAVE1_HOST" ]; then
            slave_port=$MYSQL_SLAVE1_PORT
        else
            slave_port=$MYSQL_SLAVE2_PORT
        fi
        
        local slave_status
        slave_status=$(mysql -h "$slave_host" -P "$slave_port" -u "$MYSQL_USER" -p"$MYSQL_PASS" -sN -e "SHOW SLAVE STATUS\G" 2>/dev/null || echo "")
        
        if [ -z "$slave_status" ]; then
            log_error "Slave 无法连接 ($slave_host:$slave_port)"
            continue
        fi
        
        local slave_running
        slave_running=$(echo "$slave_status" | grep "Slave_IO_Running:" | awk '{print $2}')
        local slave_sql_running
        slave_sql_running=$(echo "$slave_status" | grep "Slave_SQL_Running:" | awk '{print $2}')
        local slave_lag
        slave_lag=$(echo "$slave_status" | grep "Seconds_Behind_Master:" | awk '{print $2}')
        
        if [ "$slave_running" = "Yes" ] && [ "$slave_sql_running" = "Yes" ]; then
            log_success "Slave: $slave_host:$slave_port (延迟: ${slave_lag}s)"
        else
            log_error "Slave: $slave_host:$slave_port (IO: $slave_running, SQL: $slave_sql_running)"
        fi
        
        # 检查延迟告警
        if [ -n "$slave_lag" ] && [ "$slave_lag" != "NULL" ] && [ "$slave_lag" -gt "$ALERT_THRESHOLD" ]; then
            log_alert "Slave 延迟过高: $slave_host:$slave_port 延迟 ${slave_lag}s (阈值: ${ALERT_THRESHOLD}s)"
        fi
    done
}

################################################################################
# ProxySQL 监控
################################################################################

monitor_proxysql() {
    echo ""
    echo -e "${CYAN}═══ ProxySQL 状态 ═════════════════════════════════════╗${NC}"
    
    # 检查连通性
    local proxysql_status
    proxysql_status=$(mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -sN -e "SELECT 1;" 2>/dev/null || echo "")
    
    if [ -z "$proxysql_status" ]; then
        log_error "ProxySQL Admin 无法连接 ($PROXYSQL_ADMIN_HOST:$PROXYSQL_ADMIN_PORT)"
        return 1
    fi
    
    log_success "ProxySQL 可连接"
    
    # MySQL 服务器状态
    echo "  MySQL 服务器:"
    local servers_status
    servers_status=$(mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -sN -e "SELECT hostname, port, status, weight FROM mysql_servers;" 2>/dev/null)
    
    while IFS=$'\t' read -r hostname port status weight; do
        if [ "$status" = "ONLINE" ]; then
            log_success "    $hostname:$port (权重: $weight)"
        elif [ "$status" = "SHUNNED" ]; then
            log_warning "    $hostname:$port 状态: SHUNNED"
        else
            log_error "    $hostname:$port 状态: $status"
        fi
    done <<< "$servers_status"
    
    # 查询统计
    echo "  查询统计:"
    local query_stats
    query_stats=$(mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -sN -e "SELECT digest, COUNT(*) as cnt FROM STATS_MYSQL_QUERY_DIGEST ORDER BY cnt DESC LIMIT 5;" 2>/dev/null)
    
    if [ -z "$query_stats" ]; then
        log_warning "无查询统计数据"
    else
        while IFS=$'\t' read -r digest count; do
            echo "    查询: ${digest:0:50}... (次数: $count)"
        done <<< "$query_stats"
    fi
    
    # 连接池统计
    echo "  连接池:"
    local pool_stats
    pool_stats=$(mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -sN -e "SELECT hostgroup_id, connected, created FROM STATS_MYSQL_CONNECTION_POOL;" 2>/dev/null)
    
    while IFS=$'\t' read -r hostgroup connected created; do
        if [ "$hostgroup" = "0" ]; then
            echo "    Master 连接: 已连接=$connected, 已创建=$created"
        else
            echo "    Slave 连接: 已连接=$connected, 已创建=$created"
        fi
    done <<< "$pool_stats"
}

################################################################################
# 健康检查
################################################################################

monitor_health_check() {
    echo ""
    echo -e "${CYAN}═══ 系统健康检查 ═════════════════════════════════════╗${NC}"
    
    local health_score=100
    local issues_count=0
    
    # 检查 Orchestrator
    if ! curl -s -m 2 "$ORCHESTRATOR_API/api/leader-check" &>/dev/null; then
        log_error "Orchestrator 无可用实例"
        health_score=$((health_score - 30))
        issues_count=$((issues_count + 1))
    else
        log_success "Orchestrator 集群: 正常"
    fi
    
    # 检查 MySQL Master
    if ! mysql -h "$MYSQL_MASTER_HOST" -P "$MYSQL_MASTER_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1;" &>/dev/null; then
        log_error "MySQL Master 无法连接"
        health_score=$((health_score - 40))
        issues_count=$((issues_count + 1))
    else
        log_success "MySQL Master: 在线"
    fi
    
    # 检查 MySQL Slaves
    local slaves_down=0
    for slave_host in $MYSQL_SLAVE1_HOST $MYSQL_SLAVE2_HOST; do
        local slave_port
        if [ "$slave_host" = "$MYSQL_SLAVE1_HOST" ]; then
            slave_port=$MYSQL_SLAVE1_PORT
        else
            slave_port=$MYSQL_SLAVE2_PORT
        fi
        
        if ! mysql -h "$slave_host" -P "$slave_port" -u "$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1;" &>/dev/null; then
            slaves_down=$((slaves_down + 1))
        fi
    done
    
    if [ "$slaves_down" -gt 0 ]; then
        log_error "有 $slaves_down 个 Slave 离线"
        health_score=$((health_score - 20 * slaves_down))
        issues_count=$((issues_count + 1))
    else
        log_success "MySQL Slaves: 全部在线"
    fi
    
    # 检查 ProxySQL
    if ! mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -e "SELECT 1;" &>/dev/null; then
        log_error "ProxySQL 无法连接"
        health_score=$((health_score - 15))
        issues_count=$((issues_count + 1))
    else
        log_success "ProxySQL: 在线"
    fi
    
    # 总体评分
    echo ""
    if [ $health_score -eq 100 ]; then
        log_success "总体健康: 100/100 - 系统完全正常"
    elif [ $health_score -ge 80 ]; then
        log_warning "总体健康: $health_score/100 - 存在轻微问题"
    elif [ $health_score -ge 50 ]; then
        log_error "总体健康: $health_score/100 - 存在严重问题 ($issues_count 个)"
        log_alert "集群出现严重问题，健康度 $health_score/100"
    else
        log_error "总体健康: $health_score/100 - 系统不可用"
        log_alert "集群严重故障，健康度 $health_score/100"
    fi
}

################################################################################
# 性能指标
################################################################################

monitor_performance() {
    echo ""
    echo -e "${CYAN}═══ 性能指标 ═════════════════════════════════════════╗${NC}"
    
    # ProxySQL 缓存命中率
    local cache_stats
    cache_stats=$(mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -sN -e "SELECT questions, cache_get_ok, cache_get_total FROM STATS_MYSQL_QUERY_CACHE;" 2>/dev/null)
    
    if [ -n "$cache_stats" ]; then
        local questions cache_hit cache_total
        read -r questions cache_hit cache_total <<< "$cache_stats"
        
        if [ "$cache_total" -gt 0 ]; then
            local hit_rate=$((cache_hit * 100 / cache_total))
            echo "  Query Cache 命中率: $hit_rate% ($cache_hit/$cache_total)"
        fi
    fi
    
    # 连接池使用率
    local conn_stats
    conn_stats=$(mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -sN -e "SELECT SUM(connected) FROM STATS_MYSQL_CONNECTION_POOL;" 2>/dev/null)
    
    if [ -n "$conn_stats" ] && [ "$conn_stats" != "NULL" ]; then
        echo "  活跃连接数: $conn_stats"
    fi
}

################################################################################
# 报告生成
################################################################################

generate_report() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║          监控报告 - $timestamp"
    echo "╚════════════════════════════════════════════════════════════════╝"
}

################################################################################
# 主监控循环
################################################################################

main() {
    local mode="${1:-continuous}"
    
    init_monitor
    
    if [ "$mode" = "once" ]; then
        generate_report
        monitor_raft_cluster
        monitor_mysql_topology
        monitor_proxysql
        monitor_health_check
        monitor_performance
    elif [ "$mode" = "continuous" ]; then
        echo ""
        log_info "启动持续监控（按 Ctrl+C 停止）"
        
        while true; do
            clear
            generate_report
            monitor_raft_cluster
            monitor_mysql_topology
            monitor_proxysql
            monitor_health_check
            monitor_performance
            
            echo ""
            log_info "下次监控在 ${MONITOR_INTERVAL} 秒后执行..."
            sleep "$MONITOR_INTERVAL"
        done
    else
        show_help
        exit 1
    fi
}

show_help() {
    cat <<EOF
用法: bash monitor-raft.sh [MODE]

模式:
  once         - 运行一次监控并退出
  continuous   - 持续监控（默认）
  help         - 显示此帮助信息

环境变量:
  ORCHESTRATOR_API         Orchestrator API 地址 (默认: http://127.0.0.1:3000)
  MYSQL_MASTER_HOST        Master 主机 (默认: 127.0.0.1)
  MYSQL_MASTER_PORT        Master 端口 (默认: 3306)
  MYSQL_SLAVE1_HOST        Slave1 主机 (默认: 127.0.0.1)
  MYSQL_SLAVE1_PORT        Slave1 端口 (默认: 3307)
  MYSQL_SLAVE2_HOST        Slave2 主机 (默认: 127.0.0.1)
  MYSQL_SLAVE2_PORT        Slave2 端口 (默认: 3308)
  PROXYSQL_ADMIN_HOST      ProxySQL Admin 主机 (默认: 127.0.0.1)
  PROXYSQL_ADMIN_PORT      ProxySQL Admin 端口 (默认: 6032)
  MYSQL_USER               MySQL 用户 (默认: root)
  MYSQL_PASS               MySQL 密码 (默认: root)
  MONITOR_INTERVAL         监控间隔秒数 (默认: 10)
  ALERT_THRESHOLD          延迟告警阈值秒数 (默认: 30)
  LOG_DIR                  日志目录 (默认: /var/log/orchestrator-monitor)
  ALERT_SCRIPT             告警脚本路径（可选）

示例:
  # 持续监控
  bash monitor-raft.sh continuous

  # 运行一次
  bash monitor-raft.sh once

  # 指定监控间隔
  MONITOR_INTERVAL=5 bash monitor-raft.sh continuous

  # 指定远端服务器
  ORCHESTRATOR_API=http://192.168.1.100:3000 bash monitor-raft.sh once
EOF
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
else
    main "$@"
fi
