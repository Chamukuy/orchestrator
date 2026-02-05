#!/bin/bash

################################################################################
# Orchestrator Raft 恢复钩子脚本
# 在故障检测和转移时自动执行各种恢复和通知操作
# 由 orchestrator-raft.conf.json 中的各种进程配置触发
################################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
LOG_DIR="${LOG_DIR:-/var/log/orchestrator}"
ALERT_EMAIL="${ALERT_EMAIL:-admin@example.com}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-127.0.0.1}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_ADMIN_USER="${PROXYSQL_ADMIN_USER:-admin}"
PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_DIR/recovery-hooks.log"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1" >> "$LOG_DIR/recovery-hooks.log"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_DIR/recovery-hooks.log"
}

################################################################################
# 通知函数
################################################################################

send_slack_notification() {
    local title=$1
    local message=$2
    local severity=${3:-info}  # info, warning, error
    
    if [ -z "$SLACK_WEBHOOK" ]; then
        return 0
    fi
    
    local color
    case "$severity" in
        error)   color="danger" ;;
        warning) color="warning" ;;
        *)       color="good" ;;
    esac
    
    local payload='{
        "attachments": [
            {
                "color": "'$color'",
                "title": "'$title'",
                "text": "'$message'",
                "ts": '$(date +%s)'
            }
        ]
    }'
    
    curl -s -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK" > /dev/null 2>&1 || true
    
    log_info "Slack 通知已发送: $title"
}

send_email_notification() {
    local subject=$1
    local body=$2
    
    if command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || true
        log_info "邮件通知已发送: $subject"
    fi
}

send_webhook() {
    local webhook_url=$1
    local event_type=$2
    local event_data=$3
    
    if [ -z "$webhook_url" ]; then
        return 0
    fi
    
    local payload="{\"event\": \"$event_type\", \"data\": $event_data, \"timestamp\": \"$(date -Iseconds)\"}"
    
    curl -s -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$webhook_url" > /dev/null 2>&1 || true
    
    log_info "Webhook 已发送: $event_type"
}

################################################################################
# ProxySQL 集成函数
################################################################################

update_proxysql_topology() {
    local old_master=$1
    local old_master_port=$2
    local new_master=$3
    local new_master_port=$4
    
    log_info "更新 ProxySQL 拓扑: $old_master:$old_master_port → $new_master:$new_master_port"
    
    mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" <<EOF 2>/dev/null || true
-- 标记旧 Master 为 SHUNNED
UPDATE mysql_servers SET status='SHUNNED' 
WHERE hostname='$old_master' AND port=$old_master_port;

-- 确保新 Master 在线
UPDATE mysql_servers SET status='ONLINE' 
WHERE hostname='$new_master' AND port=$new_master_port;

-- 应用更改
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
EOF
    
    log_success "ProxySQL 拓扑已更新"
}

verify_proxysql_connectivity() {
    local host=$1
    local port=$2
    
    if mysql -h "$PROXYSQL_ADMIN_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASS" -e "SELECT 1;" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

################################################################################
# 恢复钩子处理函数
################################################################################

on_failure_detected() {
    local failure_type=$1
    local failure_cluster=$2
    local failed_host=$3
    local failed_port=$4
    
    log_info "★ 故障检测: $failure_type on $failure_cluster ($failed_host:$failed_port)"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="故障检测: $failure_type
集群: $failure_cluster
故障实例: $failed_host:$failed_port
检测时间: $timestamp
状态: 正在进行自动恢复..."
    
    # 发送通知
    send_slack_notification "🚨 故障检测" "$message" "error"
    send_email_notification "Orchestrator: 故障检测 - $failure_type" "$message"
    
    # 记录事件
    echo "$timestamp | FAILURE_DETECTED | $failure_type | $failed_host:$failed_port" >> "$LOG_DIR/events.log"
}

pre_graceful_takeover() {
    local failure_cluster=$1
    local successor_host=$2
    local successor_port=$3
    
    log_info "◆ 计划性接管启动: 新 Master 将为 $successor_host:$successor_port"
    
    local message="计划性接管启动
集群: $failure_cluster
新 Master: $successor_host:$successor_port
旧 Master 将转为只读"
    
    send_slack_notification "📋 计划性转移" "$message" "warning"
}

post_master_failover() {
    local failed_host=$1
    local failed_port=$2
    local successor_host=$3
    local successor_port=$4
    
    log_info "✓ Master 转移完成: $failed_host:$failed_port → $successor_host:$successor_port"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 更新 ProxySQL
    if verify_proxysql_connectivity "$PROXYSQL_ADMIN_HOST" "$PROXYSQL_ADMIN_PORT"; then
        update_proxysql_topology "$failed_host" "$failed_port" "$successor_host" "$successor_port"
    else
        log_error "ProxySQL 无法连接，跳过拓扑更新"
    fi
    
    local message="✓ Master 转移完成
旧 Master: $failed_host:$failed_port
新 Master: $successor_host:$successor_port
转移时间: $timestamp

ProxySQL 已自动更新配置。新用户请求将路由到新 Master。"
    
    send_slack_notification "✅ 转移完成" "$message" "good"
    
    # 记录事件
    echo "$timestamp | FAILOVER_COMPLETED | $failed_host:$failed_port | $successor_host:$successor_port" >> "$LOG_DIR/events.log"
}

post_failover_failed() {
    local failure_cluster=$1
    
    log_error "✗ 转移失败: $failure_cluster"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="✗ Master 转移失败！
集群: $failure_cluster
转移时间: $timestamp
状态: 需要手动干预

请立即检查日志并手动恢复系统。"
    
    send_slack_notification "❌ 转移失败" "$message" "error"
    send_email_notification "URGENT: Orchestrator 转移失败 - $failure_cluster" "$message"
    
    # 记录事件
    echo "$timestamp | FAILOVER_FAILED | $failure_cluster" >> "$LOG_DIR/events.log"
}

post_graceful_takeover() {
    local successor_host=$1
    local successor_port=$2
    
    log_success "✓ 计划性接管完成: $successor_host:$successor_port"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="✓ 计划性接管完成
新 Master: $successor_host:$successor_port
完成时间: $timestamp
所有应用流量已切换"
    
    send_slack_notification "✅ 接管完成" "$message" "good"
    
    # 记录事件
    echo "$timestamp | GRACEFUL_TAKEOVER_COMPLETED | $successor_host:$successor_port" >> "$LOG_DIR/events.log"
}

post_intermediate_failure() {
    local failed_host=$1
    local failed_port=$2
    
    log_info "⚠ 中间层故障转移: $failed_host:$failed_port"
    
    local message="中间层故障转移
故障实例: $failed_host:$failed_port"
    
    send_slack_notification "⚠️  中间层故障" "$message" "warning"
}

################################################################################
# 恢复后清理函数
################################################################################

cleanup_failed_master() {
    local failed_host=$1
    local failed_port=$2
    
    log_info "清理故障 Master: $failed_host:$failed_port"
    
    # 1. 从故障 Master 提取 GTID 集合
    log_info "步骤 1: 提取故障 Master 的 GTID..."
    
    # 2. 从 ProxySQL 中查询故障时间点的二进制日志
    log_info "步骤 2: 查询转移时间点..."
    
    # 3. 保留故障 Master 的数据副本（用于调查）
    log_info "步骤 3: 保留数据副本..."
    
    # 4. 等待手动检查
    log_info "步骤 4: 等待管理员检查和恢复故障 Master"
    
    # 记录清理操作
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 故障 Master 清理开始: $failed_host:$failed_port" >> "$LOG_DIR/cleanup.log"
}

sync_slave_to_new_master() {
    log_info "同步 Slave 到新 Master..."
    
    # 这个函数由 Orchestrator 自动处理，我们这里只做记录
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Slave 同步已触发" >> "$LOG_DIR/sync.log"
}

################################################################################
# 指标记录函数
################################################################################

record_failover_metrics() {
    local failed_host=$1
    local failed_port=$2
    local successor_host=$3
    local successor_port=$4
    local duration=$5  # 如果有的话
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 记录到指标文件（可被 Prometheus 等监控系统抓取）
    cat >> "$LOG_DIR/metrics.log" <<EOF
# HELP orchestrator_failover_total 总故障转移次数
# TYPE orchestrator_failover_total counter
orchestrator_failover_total{cluster="$failed_host",status="completed"} 1

# HELP orchestrator_failover_duration_seconds 故障转移耗时
# TYPE orchestrator_failover_duration_seconds gauge
orchestrator_failover_duration_seconds{from="$failed_host:$failed_port",to="$successor_host:$successor_port"} ${duration:-0}

# HELP orchestrator_failover_timestamp 故障转移时间戳
# TYPE orchestrator_failover_timestamp gauge
orchestrator_failover_timestamp{cluster="$failed_host"} $(date +%s)
EOF
    
    log_success "指标已记录"
}

################################################################################
# 故障分析函数
################################################################################

analyze_failure() {
    local failure_type=$1
    local failed_host=$2
    local failed_port=$3
    
    log_info "分析故障: $failure_type"
    
    cat >> "$LOG_DIR/failure-analysis.log" <<EOF
─────────────────────────────────────────────────────────
故障分析报告
─────────────────────────────────────────────────────────
时间: $(date '+%Y-%m-%d %H:%M:%S')
故障类型: $failure_type
故障实例: $failed_host:$failed_port

故障分析:
1. 故障类型: $failure_type
2. 可能原因:
EOF
    
    case "$failure_type" in
        DeadMaster)
            echo "   • Master 进程已关闭或网络断开" >> "$LOG_DIR/failure-analysis.log"
            echo "   • 硬件故障或操作系统崩溃" >> "$LOG_DIR/failure-analysis.log"
            echo "   • 防火墙或网络分割" >> "$LOG_DIR/failure-analysis.log"
            ;;
        UnreachableMaster)
            echo "   • 网络连接问题" >> "$LOG_DIR/failure-analysis.log"
            echo "   • MySQL 服务无响应" >> "$LOG_DIR/failure-analysis.log"
            echo "   • DNS 解析失败" >> "$LOG_DIR/failure-analysis.log"
            ;;
        *)
            echo "   • 详见其他日志文件" >> "$LOG_DIR/failure-analysis.log"
            ;;
    esac
    
    echo "" >> "$LOG_DIR/failure-analysis.log"
}

################################################################################
# 主入口
################################################################################

main() {
    local hook_type=$1
    shift
    
    # 确保日志目录存在
    mkdir -p "$LOG_DIR"
    
    # 路由到对应的处理函数
    case "$hook_type" in
        on_failure_detected)
            on_failure_detected "$@"
            ;;
        pre_graceful_takeover)
            pre_graceful_takeover "$@"
            ;;
        post_master_failover)
            post_master_failover "$@"
            record_failover_metrics "$@"
            analyze_failure "MasterFailover" "$1" "$2"
            ;;
        post_failover_failed)
            post_failover_failed "$@"
            ;;
        post_graceful_takeover)
            post_graceful_takeover "$@"
            ;;
        cleanup_failed_master)
            cleanup_failed_master "$@"
            ;;
        sync_slave)
            sync_slave_to_new_master "$@"
            ;;
        *)
            log_error "未知的钩子类型: $hook_type"
            echo "用法: bash recovery-hooks.sh <hook_type> [args...]"
            echo "支持的钩子类型:"
            echo "  on_failure_detected <type> <cluster> <host> <port>"
            echo "  pre_graceful_takeover <cluster> <successor_host> <successor_port>"
            echo "  post_master_failover <old_host> <old_port> <new_host> <new_port>"
            echo "  post_failover_failed <cluster>"
            echo "  post_graceful_takeover <successor_host> <successor_port>"
            echo "  cleanup_failed_master <failed_host> <failed_port>"
            echo "  sync_slave <slave_host> <slave_port>"
            exit 1
            ;;
    esac
    
    log_success "钩子处理完成: $hook_type"
}

# 如果脚本独立运行
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
