# Docker 增强版脚本汇总

所有脚本已升级为 **自动环境检测版本**，支持 Host 和 Docker 容器两种运行环境。

## 📦 已完成的增强版脚本

### 1️⃣ monitor-raft-docker-enhanced.sh ⭐ COMPLETE
**功能**: 实时监控 Orchestrator Raft 集群健康状态

| 特性 | 说明 |
|------|------|
| **自动检测** | ✅ Docker / Host 环境自动判断 |
| **容器网络** | ✅ mysql-master, mysql-slave-1, mysql-slave-2 |
| **Host 端口** | ✅ 127.0.0.1:3306, :3307, :3308 自动切换 |
| **功能完整** | ✅ 所有监控指标保留 |
| **大小** | 21KB, 490 行 |
| **测试状态** | ✅ 逻辑验证通过 |

**快速开始**:
```bash
# Host 运行（自动检测为 Host 环境）
bash monitor-raft-docker-enhanced.sh continuous

# Docker 容器内运行（自动检测为容器环境）
docker exec orchestrator-raft-1 bash monitor-raft-docker-enhanced.sh once

# 替换原脚本（推荐）
cp monitor-raft-docker-enhanced.sh monitor-raft.sh
chmod +x monitor-raft.sh
bash monitor-raft.sh continuous
```

---

### 2️⃣ test-failover-docker-enhanced.sh ⭐ COMPLETE
**功能**: 模拟 6 种故障场景进行演练测试

| 特性 | 说明 |
|------|------|
| **自动检测** | ✅ Docker / Host 环境自动判断 |
| **故障场景** | ✅ Master 宕机、Slave 宕机、网络分区、慢从库、高负载、级联故障 |
| **容器支持** | ✅ 可在容器内执行（有权限时） |
| **恢复验证** | ✅ 数据一致性和状态验证 |
| **大小** | 18.5KB, 480+ 行 |
| **测试状态** | ✅ 逻辑验证通过 |

**快速开始**:
```bash
# Host 执行单个故障场景
bash test-failover-docker-enhanced.sh master-crash

# Docker 容器内执行
docker exec orchestrator-raft-1 bash test-failover-docker-enhanced.sh slave-crash

# 执行所有测试
bash test-failover-docker-enhanced.sh all

# 完整测试（包含恢复）
bash test-failover-docker-enhanced.sh fulltest

# 查看帮助
bash test-failover-docker-enhanced.sh --help
```

**支持的故障场景**:
- `master-crash` - Master 宕机并自动转移
- `slave-crash` - Slave 宕机
- `network-partition` - 网络分区
- `slow-replica` - 慢从库延迟
- `load-peak` - 高负载压力测试
- `cascading` - 级联故障
- `all` - 执行所有非 root 场景
- `fulltest` - 完整测试含恢复

---

### 3️⃣ recover-from-power-failure-docker-enhanced.sh ⭐ COMPLETE
**功能**: 7 阶段自动化断电恢复

| 特性 | 说明 |
|------|------|
| **自动检测** | ✅ Docker / Host 环境自动判断 |
| **7 个恢复阶段** | ✅ 等待服务、Raft 一致性、复制检查、故障转移、数据验证、健康检查 |
| **容器网络** | ✅ 三种访问模式透明支持 |
| **日志完整** | ✅ /var/log/orchestrator/power-recovery.log |
| **大小** | 15.5KB, 450+ 行 |
| **测试状态** | ✅ 逻辑验证通过 |

**快速开始**:
```bash
# Host 执行恢复
bash recover-from-power-failure-docker-enhanced.sh

# Docker 容器内执行
docker exec orchestrator-raft-1 bash recover-from-power-failure-docker-enhanced.sh

# 查看恢复日志
tail -f /var/log/orchestrator/power-recovery.log

# 通过 systemd 自动执行（见下方）
systemctl start orchestrator-power-recovery
```

**7 个恢复阶段**:
1. 等待 MySQL 服务启动
2. 等待 Orchestrator Raft 集群就绪
3. 检查主从复制状态
4. Raft 一致性检查与恢复
5. 检测主库故障并触发转移
6. 数据一致性验证
7. 最终系统健康检查

---

## 📝 其他需要增强的脚本

### recovery-hooks.sh （可选增强）
目前仅在 Host 环境使用 ProxySQL，建议的增强：
```bash
# 在脚本顶部添加自动检测
if detect_docker_environment; then
    PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-orchestrator-proxysql}"
else
    PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-127.0.0.1}"
fi
```

**状态**: ⏳ 如需 Docker 支持，请告知

### deploy-proxysql.sh （可选增强）
部署脚本可选添加容器主机检测，目前 Host-only。

**状态**: ⏳ 如需 Docker 支持，请告知

---

## 🎯 使用策略

### 推荐方案 A：快速替换（最简单）

```bash
cd /workspaces/orchestrator

# 备份原脚本（可选）
cp monitor-raft.sh monitor-raft.sh.bak
cp test-failover.sh test-failover.sh.bak
cp recover-from-power-failure.sh recover-from-power-failure.sh.bak

# 使用增强版本
cp monitor-raft-docker-enhanced.sh monitor-raft.sh
cp test-failover-docker-enhanced.sh test-failover.sh
cp recover-from-power-failure-docker-enhanced.sh recover-from-power-failure.sh

# 设置权限
chmod +x monitor-raft.sh test-failover.sh recover-from-power-failure.sh

# 测试
bash monitor-raft.sh once
bash test-failover.sh master-crash
bash recover-from-power-failure.sh
```

### 方案 B：并行保留（更安全）

```bash
# 保留原脚本，用增强版
chmod +x monitor-raft-docker-enhanced.sh
chmod +x test-failover-docker-enhanced.sh
chmod +x recover-from-power-failure-docker-enhanced.sh

# 直接使用增强版无需修改原脚本
bash monitor-raft-docker-enhanced.sh continuous
bash test-failover-docker-enhanced.sh all
bash recover-from-power-failure-docker-enhanced.sh
```

---

## 🔍 环境检测验证

测试自动检测是否工作正常：

```bash
# 1. Host 环境验证
bash monitor-raft-docker-enhanced.sh once
# 应该输出：
#   环境类型: Host 本地环境
#   MySQL Master: 127.0.0.1:3306

# 2. Docker 容器环境验证
docker exec orchestrator-raft-1 bash monitor-raft-docker-enhanced.sh once
# 应该输出：
#   环境类型: Docker 容器内
#   MySQL Master: mysql-master:3306
```

---

## 📊 脚本对比表

| 脚本 | 原版 | 增强版 | 主要改进 |
|------|------|--------|---------|
| monitor-raft | 17KB | 21KB | +4KB 自动检测逻辑 |
| test-failover | 17KB | 18.5KB | +1.5KB 自动检测逻辑 |
| recover-power | 15KB | 15.5KB | +0.5KB 自动检测逻辑 |
| **总计** | **49KB** | **54.5KB** | **+5.5KB 开销** |

✅ **开销极小**，获益巨大

---

## 🚀 部署建议

### Step 1: 验证当前环境
```bash
# 检查 Docker 是否运行
docker-compose ps

# 检查 Orchestrator 服务
curl -s http://127.0.0.1:3000/api/leader-check | jq .
```

### Step 2: 部署增强版脚本
```bash
# 选择方案 A（推荐快速替换）
cp monitor-raft-docker-enhanced.sh monitor-raft.sh
cp test-failover-docker-enhanced.sh test-failover.sh
cp recover-from-power-failure-docker-enhanced.sh recover-from-power-failure.sh
chmod +x *.sh
```

### Step 3: 运行测试
```bash
# 1. 监控测试
bash monitor-raft.sh once

# 2. 故障演练
bash test-failover.sh master-crash

# 3. 恢复流程
bash recover-from-power-failure.sh
```

### Step 4: 生产部署（可选）
```bash
# 配置 systemd 自动启动恢复脚本
sudo cp orchestrator-power-recovery.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable orchestrator-power-recovery
sudo systemctl start orchestrator-power-recovery

# 检查状态
systemctl status orchestrator-power-recovery
```

---

## 🔧 自定义配置

所有脚本都支持环境变量覆盖：

```bash
# Host 环境下连接远程 Orchestrator
ORCHESTRATOR_API="http://192.168.1.100:3000" \
MYSQL_MASTER_HOST="db-prod" \
bash monitor-raft.sh once

# Docker 容器内连接外部 Orchestrator（如需要）
ORCHESTRATOR_API="http://172.17.0.1:3000" \
docker exec orchestrator-raft-1 bash monitor-raft.sh once

# 自定义日志位置
LOG_FILE="/custom/path/recovery.log" \
bash recover-from-power-failure.sh
```

---

## 📚 相关文档

- [DOCKER-DEPLOYMENT-GUIDE.md](DOCKER-DEPLOYMENT-GUIDE.md) - 三种部署方案详解
- [DOCKER-ACCESS-ANALYSIS.md](DOCKER-ACCESS-ANALYSIS.md) - Docker 访问模式分析
- [FAILURE-MANAGEMENT.md](FAILURE-MANAGEMENT.md) - 故障管理完整指南
- [POWER-FAILURE-RECOVERY.md](POWER-FAILURE-RECOVERY.md) - 断电恢复详细指南

---

## ✅ 部署检查清单

启用增强版脚本前，确认：

- [ ] Docker Compose 配置正确，所有服务可启动
- [ ] MySQL 用户名密码配置正确
- [ ] Orchestrator API 可访问
- [ ] 容器网络命名规范一致（mysql-master, mysql-slave-1, mysql-slave-2）
- [ ] 运行一次 Host 测试：`bash monitor-raft.sh once`
- [ ] 运行一次 Docker 测试：`docker exec orchestrator-raft-1 bash monitor-raft.sh once`
- [ ] 验证输出显示正确的运行环境

---

## 🎉 完成！

所有脚本已升级，支持在 **Host 和 Docker 容器** 两种环境中无缝运行。

**建议行动**：
1. 选择方案 A 或 B 部署增强版脚本
2. 运行 `bash monitor-raft.sh once` 验证环境检测
3. 后续所有脚本调用自动适应运行环境

**下一步** （如需要）：
- 增强 recovery-hooks.sh 和 deploy-proxysql.sh（可选）
- 创建专用监控 Docker 服务（参考 DOCKER-DEPLOYMENT-GUIDE.md）
- 配置 systemd 自动恢复服务
