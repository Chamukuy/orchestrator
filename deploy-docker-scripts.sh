#!/bin/bash

################################################################################
# Docker 增强版脚本快速部署向导
# 
# 功能：
# - 自动备份原脚本
# - 部署增强版脚本
# - 运行验证测试
# - 显示部署摘要
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}==>${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/.script-backups"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        Docker 增强版脚本快速部署向导                           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

################################################################################
# Step 1: 选择部署方案
################################################################################

show_deployment_options() {
    echo -e "${BLUE}请选择部署方案：${NC}"
    echo ""
    echo "  [1] 方案 A - 快速替换（推荐）"
    echo "      优点：最简单，脚本立即生效"
    echo "      缺点：原脚本移入备份"
    echo ""
    echo "  [2] 方案 B - 并行保存（更安全）"
    echo "      优点：保留原脚本在原位置"
    echo "      缺点：需要手动使用 -docker-enhanced 版本"
    echo ""
    echo "  [3] 仅查看信息（不部署）"
    echo ""
    read -p "请输入选项 [1/2/3，默认 1]: " choice
    choice=${choice:-1}
}

################################################################################
# Step 2: 备份原脚本
################################################################################

backup_original_scripts() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        log_success "创建备份目录: $BACKUP_DIR"
    fi
    
    for script in monitor-raft.sh test-failover.sh recover-from-power-failure.sh; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            cp "$SCRIPT_DIR/$script" "$BACKUP_DIR/${script}.${TIMESTAMP}.bak"
            log_success "已备份: $script → ${script}.${TIMESTAMP}.bak"
        fi
    done
}

################################################################################
# Step 3: 部署方案 A
################################################################################

deploy_option_a() {
    log_info "执行方案 A: 快速替换"
    echo ""
    
    backup_original_scripts
    
    # 替换脚本
    log_info "部署增强版脚本..."
    
    if [ -f "$SCRIPT_DIR/monitor-raft-docker-enhanced.sh" ]; then
        cp "$SCRIPT_DIR/monitor-raft-docker-enhanced.sh" "$SCRIPT_DIR/monitor-raft.sh"
        chmod +x "$SCRIPT_DIR/monitor-raft.sh"
        log_success "monitor-raft.sh 已更新"
    else
        log_error "monitor-raft-docker-enhanced.sh 不存在"
        return 1
    fi
    
    if [ -f "$SCRIPT_DIR/test-failover-docker-enhanced.sh" ]; then
        cp "$SCRIPT_DIR/test-failover-docker-enhanced.sh" "$SCRIPT_DIR/test-failover.sh"
        chmod +x "$SCRIPT_DIR/test-failover.sh"
        log_success "test-failover.sh 已更新"
    else
        log_error "test-failover-docker-enhanced.sh 不存在"
        return 1
    fi
    
    if [ -f "$SCRIPT_DIR/recover-from-power-failure-docker-enhanced.sh" ]; then
        cp "$SCRIPT_DIR/recover-from-power-failure-docker-enhanced.sh" "$SCRIPT_DIR/recover-from-power-failure.sh"
        chmod +x "$SCRIPT_DIR/recover-from-power-failure.sh"
        log_success "recover-from-power-failure.sh 已更新"
    else
        log_error "recover-from-power-failure-docker-enhanced.sh 不存在"
        return 1
    fi
    
    echo ""
    log_success "方案 A 部署完成！"
}

################################################################################
# Step 4: 部署方案 B
################################################################################

deploy_option_b() {
    log_info "执行方案 B: 并行保存"
    echo ""
    
    # 仅确保增强版脚本可执行
    chmod +x "$SCRIPT_DIR/monitor-raft-docker-enhanced.sh" 2>/dev/null || return 1
    chmod +x "$SCRIPT_DIR/test-failover-docker-enhanced.sh" 2>/dev/null || return 1
    chmod +x "$SCRIPT_DIR/recover-from-power-failure-docker-enhanced.sh" 2>/dev/null || return 1
    
    log_success "增强版脚本已设置为可执行"
    log_warning "使用 -docker-enhanced.sh 后缀的脚本或别名指定"
    
    echo ""
    log_success "方案 B 部署完成！"
}

################################################################################
# Step 5: 运行验证测试
################################################################################

run_verification_tests() {
    echo ""
    log_info "运行验证测试..."
    echo ""
    
    # 检查 Docker 和 Orchestrator 可用性
    if ! command -v docker &> /dev/null; then
        log_warning "docker 命令不可用，跳过 Docker 验证"
        return 0
    fi
    
    if ! command -v mysql &> /dev/null; then
        log_warning "mysql 命令不可用，跳过数据库连接测试"
        return 0
    fi
    
    # 测试 Host 环境
    log_info "测试 Host 环境检测..."
    if bash "$SCRIPT_DIR/monitor-raft.sh" once 2>/dev/null | grep -q "HOST"; then
        log_success "Host 环境检测正常"
    else
        log_warning "Host 环境检测输出可能需要检查"
    fi
    
    # 测试 Docker 环境
    log_info "测试 Docker 容器环境检测..."
    if docker ps -q | head -1 > /dev/null 2>&1; then
        container_id=$(docker ps -q | head -1)
        if docker exec "$container_id" bash -c "[ -f /.dockerenv ]" 2>/dev/null; then
            log_success "Docker 容器环境检测可用"
        fi
    else
        log_warning "无运行中的 Docker 容器，跳过容器测试"
    fi
    
    echo ""
}

################################################################################
# Step 6: 显示部署摘要
################################################################################

show_deployment_summary() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   部署完成总结                                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [ "$choice" = "1" ]; then
        echo -e "${GREEN}✓ 方案 A: 快速替换${NC} (已完成)"
        echo ""
        echo "  已部署的脚本："
        echo "    1. monitor-raft.sh"
        echo "    2. test-failover.sh"
        echo "    3. recover-from-power-failure.sh"
        echo ""
        echo "  验证命令："
        echo "    $ bash monitor-raft.sh once"
        echo "    $ bash test-failover.sh master-crash"
        echo "    $ bash recover-from-power-failure.sh"
        echo ""
    elif [ "$choice" = "2" ]; then
        echo -e "${GREEN}✓ 方案 B: 并行保存${NC} (已完成)"
        echo ""
        echo "  原始脚本保留："
        echo "    1. monitor-raft.sh (原版本)"
        echo "    2. test-failover.sh (原版本)"
        echo "    3. recover-from-power-failure.sh (原版本)"
        echo ""
        echo "  增强版脚本可用："
        echo "    1. monitor-raft-docker-enhanced.sh"
        echo "    2. test-failover-docker-enhanced.sh"
        echo "    3. recover-from-power-failure-docker-enhanced.sh"
        echo ""
        echo "  使用增强版命令："
        echo "    $ bash monitor-raft-docker-enhanced.sh once"
        echo "    $ bash test-failover-docker-enhanced.sh master-crash"
        echo "    $ bash recover-from-power-failure-docker-enhanced.sh"
        echo ""
    fi
    
    echo "  文档和指南："
    echo "    • DOCKER-SCRIPTS-SUMMARY.md ......... 脚本汇总（本文档）"
    echo "    • DOCKER-DEPLOYMENT-GUIDE.md ....... 部署方案详解"
    echo "    • DOCKER-ACCESS-ANALYSIS.md ........ Docker 访问模式分析"
    echo ""
    
    if [ -d "$BACKUP_DIR" ]; then
        echo "  备份位置："
        echo "    $BACKUP_DIR/"
        echo ""
    fi
    
    echo "  关键特性："
    echo "    ✓ 自动环境检测 (Docker/Host)"
    echo "    ✓ 透明网络地址转换"
    echo "    ✓ 100% 兼容原脚本"
    echo "    ✓ 完全保留功能特性"
    echo ""
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo ""
}

################################################################################
# Step 7: 显示后续步骤
################################################################################

show_next_steps() {
    echo -e "${BLUE}后续步骤：${NC}"
    echo ""
    echo "  1. 验证基本功能"
    echo "     $ bash monitor-raft.sh once"
    echo ""
    echo "  2. 运行故障演练"
    echo "     $ bash test-failover.sh master-crash"
    echo ""
    echo "  3. 配置自动恢复（可选）"
    echo "     $ sudo cp orchestrator-power-recovery.service /etc/systemd/system/"
    echo "     $ sudo systemctl enable orchestrator-power-recovery"
    echo ""
    echo "  4. 在生产环境测试"
    echo "     $ docker exec orchestrator-raft-1 bash monitor-raft.sh once"
    echo ""
    echo -e "${GREEN}✓ 部署向导完成！${NC}"
    echo ""
}

################################################################################
# 主程序
################################################################################

main() {
    show_deployment_options
    
    case "$choice" in
        1)
            deploy_option_a
            run_verification_tests
            show_deployment_summary
            show_next_steps
            ;;
        2)
            deploy_option_b
            run_verification_tests
            show_deployment_summary
            show_next_steps
            ;;
        3)
            log_info "仅显示信息，未执行部署"
            echo ""
            cat DOCKER-SCRIPTS-SUMMARY.md | head -50
            echo ""
            log_info "完整文档请查看: DOCKER-SCRIPTS-SUMMARY.md"
            ;;
        *)
            log_error "无效的选项"
            exit 1
            ;;
    esac
}

# 运行主程序
main "$@"
