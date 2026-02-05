# Orchestrator Raft 故障管理完全指南

包含故障演练、监控、恢复钩子和参数优化

## 📋 目录

- [概述](#概述)
- [文件清单](#文件清单)
- [优化的转移参数](#优化的转移参数)
- [故障演练测试](#故障演练测试)
- [实时监控](#实时监控)
- [恢复钩子](#恢复钩子)
- [完整工作流](#完整工作流)
- [故障排查](#故障排查)

---

## 概述

本指南介绍了 Orchestrator Raft 完整的故障管理解决方案，包括：

1. **优化的转移参数** - 加快故障检测和转移速度
2. **故障演练脚本** - 模拟各种故障场景进行测试
3. **监控脚本** - 实时监控系统健康状态
4. **恢复钩子** - 自动处理故障转移相关操作

## 文件清单

### 新增脚本

| 文件 | 大小 | 用途 | 可执行 |
|------|------|------|--------|
| `test-failover.sh` | 17KB | 故障演练和测试 | ✅ |
| `monitor-raft.sh` | 17KB | 实时系统监控 | ✅ |
| `recovery-hooks.sh` | 14KB | 故障恢复自动化 | ✅ |
| `docs/proxysql-raft-integration.md` | 15KB | ProxySQL 集成指南 | - |

### 更新文件

| 文件 | 变更 |
|------|------|
| `conf/orchestrator-raft.conf.json` | 优化转移参数 + 添加钩子命令 |

---

## 优化的转移参数

### 参数变更

```json
{
  "FailureDetectionPeriodBlockMinutes": 2,    // 从 5 改为 2（加快检测）
  "FailMasterPromotionOnLagMinutes": 1,       // 保持不变
  "RecoveryPeriodBlockSeconds": 3,            // 从 5 改为 3（加快恢复）
  "FailureDetectionPeriodBlockSeconds": 30,   // 新增详细控制
  "PostponeReplicaRecoveryOnLagMinutes": 0    // 新增不延迟恢复
}
```

### 参数说明

| 参数 | 旧值 | 新值 | 说明 |
|------|------|------|------|
| **FailureDetectionPeriodBlockMinutes** | 5 | 2 | 故障检测完成后，至少等待 2 分钟再允许下一次检测（防止频繁转移） |
| **FailMasterPromotionOnLagMinutes** | 1 | 1 | Slave 延迟超过 1 分钟时，不提升为新 Master（防止数据丢失） |
| **RecoveryPeriodBlockSeconds** | 5 | 3 | 故障恢复完成后，至少等待 3 秒再允许下一次恢复 |

### 故障检测流程时间线

```
T0:     Orchestrator 开始定期检查 Master
T5s:    第一次检查失败 → 标记"疑似故障"
T30s:   经过 5 次检查（5s × 5），确认故障
T30-60s: 进行故障转移
  - 选择最佳 Slave（延迟最小）
  - 传播 GTID 信息
  - 晋升为新 Master
T60+:   其他 Slave 重新连接新 Master，ProxySQL 更新配置
T120s:  故障检测周期恢复（RecoveryPeriodBlockSeconds = 3 秒后）
```

---

## 故障演练测试

### 快速开始

```bash
# 运行所有测试场景
bash test-failover.sh all

# 运行特定测试场景
bash test-failover.sh master-crash
bash test-failover.sh slave-lag
bash test-failover.sh data-consistency
```

### 测试场景详解

#### 场景 1: Master 宕机自动转移 ⭐ 最重要

```bash
bash test-failover.sh master-crash
```

**演练流程：**
1. 检查前置条件（所有 MySQL 实例在线）
2. 生成测试数据（failover_test 数据库）
3. **停止 Master**
4. 等待故障转移（最长 120s）
5. 验证新 Master 可写入
6. 恢复原 Master

**期望结果：**
- ✅ 故障自动检测
- ✅ Slave 自动晋升为新 Master
- ✅ 其他 Slave 重新连接新 Master
- ✅ 数据一致性保证
- ✅ 应用无感知（通过 ProxySQL）

#### 场景 2: Slave 延迟处理

```bash
bash test-failover.sh slave-lag
```

检查 Slave 复制延迟，验证 Orchestrator 的延迟保护机制。

#### 场景 3: 网络分割检测

```bash
bash test-failover.sh network-partition
```

验证 Raft 集群在网络分割时的行为：
- 多数派节点继续工作
- 少数派节点自动隔离

#### 场景 4: 只读 Slave 晋升

```bash
bash test-failover.sh readonly-promotion
```

验证只读 Slave 晋升为 Master 的过程：
1. 停止复制
2. 设置 `read_only=0`
3. 转移新的写请求
4. 旧 Slave 重新连接

#### 场景 5: Orchestrator 重启恢复

```bash
bash test-failover.sh orchestrator-restart
```

演练 Orchestrator 节点故障和恢复：
1. 停止一个 Orchestrator 节点
2. 验证其他节点的 Leader 选举
3. 重启故障节点
4. 验证集群恢复正常

#### 场景 6: 数据一致性检验

```bash
bash test-failover.sh data-consistency
```

在设定 Master 后，自动验证：
- 数据是否复制到所有 Slave
- 是否存在未同步的数据

### 自定义测试环境

```bash
# 指定远端 Orchestrator 和 MySQL 服务器
ORCHESTRATOR_API=http://192.168.1.100:3000 \
MYSQL_MASTER_HOST=192.168.1.10 \
MYSQL_SLAVE1_HOST=192.168.1.11 \
MYSQL_SLAVE2_HOST=192.168.1.12 \
MYSQL_USER=root \
MYSQL_PASS=root \
bash test-failover.sh master-crash
```

### 测试结果分析

所有测试输出到：
- **控制台** - 实时进度和结果
- **日志文件** - 详细日志（如需配置）

---

## 实时监控

### 启动监控

```bash
# 持续监控（默认）
bash monitor-raft.sh continuous

# 或简写
bash monitor-raft.sh

# 运行一次后退出
bash monitor-raft.sh once
```

### 监控视图 (每次刷新)

```
═══ Orchestrator Raft 集群状态 ════════════════════════════════════
✓ Raft Leader: orchestrator-node1
  当前Leader: 192.168.1.10:10008

═══ MySQL 拓扑状态 ════════════════════════════════════════════════
✓ Master: 127.0.0.1:3306
  Binlog: mysql-bin.000005 @ 4096
✓ Slave: 127.0.0.1:3307 (延迟: 0s)
✓ Slave: 127.0.0.1:3308 (延迟: 0s)

═══ ProxySQL 状态 ════════════════════════════════════════════════
✓ ProxySQL 可连接
  MySQL 服务器:
    ✓ 192.168.1.10:3306 (权重: 1000)
    ✓ 192.168.1.11:3306 (权重: 1000)
    ✓ 192.168.1.12:3306 (权重: 1000)
  查询统计:
    查询: SELECT * FROM users... (次数: 15234)
  连接池:
    Master 连接: 已连接=45, 已创建=231
    Slave 连接: 已连接=128, 已创建=456

═══ 系统健康检查 ═════════════════════════════════════════════════
✓ Orchestrator 集群: 正常
✓ MySQL Master: 在线
✓ MySQL Slaves: 全部在线
✓ ProxySQL: 在线
总体健康: 100/100 - 系统完全正常

═══ 性能指标 ═════════════════════════════════════════════════════
  Query Cache 命中率: 68% (3421/5032)
  活跃连接数: 173

下次监控在 10 秒后执行...
```

### 监控配置

```bash
# 修改监控间隔（每 5 秒检查一次）
MONITOR_INTERVAL=5 bash monitor-raft.sh continuous

# 修改告警延迟阈值（超过 20s 延迟时告警）
ALERT_THRESHOLD=20 bash monitor-raft.sh continuous

# 指定远端服务器
ORCHESTRATOR_API=http://192.168.1.100:3000 \
MYSQL_MASTER_HOST=192.168.1.10 \
bash monitor-raft.sh once

# 配置日志目录
LOG_DIR=/var/log/orchestrator bash monitor-raft.sh continuous
```

### 健康评分说明

| 分数 | 状态 | 说明 |
|------|------|------|
| 100 | ✅ 极好 | 系统完全正常 |
| 80-99 | ⚠️  良好 | 存在轻微问题，可继续运行 |
| 50-79 | ❌ 差 | 存在严重问题，需要立即检查 |
| <50 | 🔴 严重 | 系统不可用，需要紧急恢复 |

---

## 恢复钩子

### 工作原理

Orchestrator 在故障检测和转移的各个阶段，自动调用恢复钩子脚本 `recovery-hooks.sh`：

```
Master 宕机
    ↓
[on_failure_detected] → 记录故障，发送 Slack/邮件告警
    ↓
故障转移开始
    ↓
[pre_graceful_takeover] → 准备新 Master（变为只读、准备晋升等）
    ↓
Slave 晋升为新 Master
    ↓
[post_master_failover] → 更新 ProxySQL 配置，通知应用
    ↓
[post_graceful_takeover] → 记录转移完成，发送完成通知
```

### 钩子函数详解

#### 1. `on_failure_detected` - 故障检测

```bash
bash recovery-hooks.sh on_failure_detected DeadMaster master-slave 192.168.1.10 3306
```

**触发时机**：Orchestrator 首次检测到故障

**作用**：
- ✅ 记录故障事件到日志
- ✅ 发送 Slack/邮件告警
- ✅ 通知值班人员

**日志**：`/var/log/orchestrator/recovery-hooks.log`

#### 2. `pre_graceful_takeover` - 转移前准备

```bash
bash recovery-hooks.sh pre_graceful_takeover master-slave 192.168.1.11 3306
```

**触发时机**：开始进行 Master 转移

**作用**：
- ✅ 旧 Master 变为只读（防止新写入）
- ✅ 暂停应用（可选）
- ✅ 备份关键数据

#### 3. `post_master_failover` - 转移后处理

```bash
bash recovery-hooks.sh post_master_failover 192.168.1.10 3306 192.168.1.11 3306
```

**触发时机**：新 Master 晋升完成

**作用**：
- ✅ **更新 ProxySQL 配置** ⭐ 最关键
  - 标记旧 Master 为 SHUNNED（故障）
  - 设置新 Master 为 ONLINE
  - 更新所有应用连接路由
- ✅ 记录转移指标（用于监控）
- ✅ 发送转移完成通知

#### 4. `post_failover_failed` - 转移失败处理

```bash
bash recovery-hooks.sh post_failover_failed master-slave
```

**触发时机**：故障转移失败

**作用**：
- ✅ 发送紧急告警
- ✅ 记录失败原因
- ✅ 通知管理员需要手动干预

### 配置钩子

在 `conf/orchestrator-raft.conf.json` 中配置：

```json
{
  "OnFailureDetectionProcesses": [
    "echo '...' >> /var/log/orchestrator/failures.log",
    "bash /usr/local/bin/recovery-hooks.sh on_failure_detected {failureType} {failureCluster} {failedHost} {failedPort}"
  ],
  
  "PostFailoverProcesses": [
    "bash /usr/local/bin/recovery-hooks.sh post_failover {failedHost} {failedPort} {successorHost} {successorPort}"
  ],
  
  "PostMasterFailoverProcesses": [
    "bash /usr/local/bin/recovery-hooks.sh post_master_failover {failedHost} {failedPort} {successorHost} {successorPort}"
  ]
}
```

### 钩子模板变量

| 模板变量 | 说明 | 示例 |
|---------|------|------|
| `{failureType}` | 故障类型 | DeadMaster, UnreachableMaster |
| `{failureCluster}` | 集群名 | master-slave |
| `{failedHost}` | 故障主机 | 192.168.1.10 |
| `{failedPort}` | 故障端口 | 3306 |
| `{successorHost}` | 接管主机 | 192.168.1.11 |
| `{successorPort}` | 接管端口 | 3306 |
| `{countSlaves}` | 受影响的从数 | 2 |

### 告警集成

Recovery Hooks 支持多种告警方式：

#### Slack 通知

```bash
# 设置 Slack Webhook
export SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
bash monitor-raft.sh continuous
```

#### 邮件通知

```bash
# 设置告警邮箱
export ALERT_EMAIL="ops-team@company.com"
bash monitor-raft.sh continuous
```

---

## 完整工作流

### 场景：Master 宕机完整恢复流程

#### 第一阶段：故障检测与通知 (T0-T60s)

```
T0s:    Master (192.168.1.10:3306) 宕机
T5s:    Orchestrator 健康检查失败 → 标记"疑似故障"
T30s:   确认故障
        ↓
        [on_failure_detected] 钩子触发
        - 记录事件到 /var/log/orchestrator/recovery-hooks.log
        - 发送 Slack 消息：🚨 故障检测
        - 发送邮件给 ops-team@company.com

T45s:   Raft 集群共同决定转移
T60s:   开始选择新 Master（选择延迟最小的 Slave）
```

#### 第二阶段：故障转移 (T60-T120s)

```
T60s:   [pre_graceful_takeover] 钩子触发
        - 旧 Master 锁定（如果可达）
        - 确认 GTID 信息

T70s:   [post_master_failover] 钩子触发
        | 1. 获取新 Master 信息
        | 2. 更新 ProxySQL 配置：
        |    - UPDATE mysql_servers SET status='SHUNNED' 
        |      WHERE hostname='192.168.1.10'
        |    - UPDATE mysql_servers SET status='ONLINE'
        |      WHERE hostname='192.168.1.11'
        |    - LOAD MYSQL SERVERS TO RUNTIME
        |
        | 3. 其他 Slave 重新连接新 Master
        | 4. 发送 Slack 消息：✅ 转移完成
        | 5. 发送邮件通知

T120s:  所有应用重新连接新 Master
        ProxySQL 自动将新请求路由到新 Master
```

#### 第三阶段：故障恢复 (T120s+)

```
T120s+: [post_graceful_takeover] 钩子触发
        - 记录恢复完成
        - 发送最终通知

之后:   管理员检查并恢复故障 Master（192.168.1.10）
        1. 查看故障日志
        2. 重启 MySQL 或硬件
        3. 将其变为新 Master 的 Slave
        4. 从 ProxySQL 中移除故障标记
        5. 恢复为在线状态
```

#### 重要提示

**故障转移中的数据安全保证：**

1. ✅ GTID 确保全局唯一性
2. ✅ Slave 延迟检查（避免晋升延迟过大的 Slave）
3. ✅ 二进制日志检查（确保有足够的日志）
4. ✅ ProxySQL 自动隔离故障 Master
5. ✅ 应用自动重连到新 Master（通过 ProxySQL）

**无需手动干预，完全自动化！**

---

## 故障排查

### 问题 1: 故障转移没有发生

**症状**：Master 宕机后，未自动转移

**排查步骤**：

```bash
# 1. 检查 Orchestrator 是否运行
curl http://127.0.0.1:3000/api/leader-check

# 2. 检查拓扑发现
curl http://127.0.0.1:3000/api/cluster/master-slave | jq .

# 3. 查看 Orchestrator 日志
docker logs orchestrator-raft-1
# 或
tail -100 /var/log/orchestrator/orchestrator.log

# 4. 检查转移配置是否启用
grep "ApplyMySQLPromotionAfterMasterFailover" conf/orchestrator-raft.conf.json
# 应该是 true
```

**常见原因**：

| 原因 | 解决方案 |
|------|--------|
| Raft 集群没有 Leader | 重启 Orchestrator 容器 |
| 没有可用的 Slave | 检查 Slave 连通性和复制状态 |
| 转移被阻止 | 检查 `RecoveryPeriodBlockSeconds` 配置 |
| Slave 延迟过大 | 等待复制完成或降低 `FailMasterPromotionOnLagMinutes` |

### 问题 2: ProxySQL 未更新路由

**症状**：Master 转移后，请求仍然转向旧 Master

**排查步骤**：

```bash
# 1. 检查 ProxySQL MySQL 服务器列表
mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e "SHOW MYSQL SERVERS \G"

# 2. 查看旧 Master 状态（应为 SHUNNED）
mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e "SELECT * FROM mysql_servers WHERE hostname='192.168.1.10'\G"

# 3. 检查恢复钩子是否执行
tail -50 /var/log/orchestrator/recovery-hooks.log

# 4. 手动触发更新
mysql -h 127.0.0.1 -P 6032 -u admin -padmin <<EOF
UPDATE mysql_servers SET status='SHUNNED' WHERE hostname='192.168.1.10';
UPDATE mysql_servers SET status='ONLINE' WHERE hostname='192.168.1.11';
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
EOF
```

**常见原因**：

| 原因 | 解决方案 |
|------|--------|
| 恢复钩子未执行 | 检查 `conf/orchestrator-raft.conf.json` 配置 |
| ProxySQL 无法连接 | 检查网络和防火墙 |
| 配置未重载 | 手动执行 LOAD/SAVE MySQL SERVERS |

### 问题 3: Slave 复制停止

**症状**：转移后，一个或多个 Slave 复制中断

**排查步骤**：

```bash
# 1. 检查 Slave 状态
mysql -h 192.168.1.11 -P 3306 -u root -proot -e "SHOW SLAVE STATUS\G"

# 2. 查看错误消息
mysql -h 192.168.1.11 -P 3306 -u root -proot -e "SHOW SLAVE STATUS\G" | grep "Error"

# 3. 重启复制
mysql -h 192.168.1.11 -P 3306 -u root -proot -e "
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO MASTER_HOST='新Master地址', MASTER_LOG_FILE='binlog文件', MASTER_LOG_POS=位置;
START SLAVE;
"

# 4. 验证复制
mysql -h 192.168.1.11 -P 3306 -u root -proot -e "SHOW SLAVE STATUS\G"
```

**常见原因**：

| 原因 | 解决方案 |
|------|--------|
| 新 Master GTID 不兼容 | 检查 GTID 集合，可能需要 RESET MASTER |
| 网络断开 | 检查网络连通性和防火墙 |
| 复制用户无权限 | 检查复制用户权限 |

### 问题 4: 监控脚本错误

**症状**：监控脚本无法连接服务

**解决方案**：

```bash
# 1. 检查环境变量
echo "ORCHESTRATOR_API=$ORCHESTRATOR_API"
echo "MYSQL_MASTER_HOST=$MYSQL_MASTER_HOST"

# 2. 手动测试连接
curl -v http://127.0.0.1:3000/api/leader-check
mysql -h 127.0.0.1 -P 3306 -u root -proot -e "SELECT 1;"

# 3. 查看日志
tail -50 /var/log/orchestrator-monitor/monitor.log

# 4. 增加调试信息
bash -x monitor-raft.sh once
```

---

## 总结

| 组件 | 文件 | 用途 |
|------|------|------|
| **参数优化** | `conf/orchestrator-raft.conf.json` | 加快故障检测和转移 |
| **故障演练** | `test-failover.sh` | 验证整个故障转移流程 |
| **实时监控** | `monitor-raft.sh` | 持续监控系统健康 |
| **自动化恢复** | `recovery-hooks.sh` | 钩子脚本，自动处理转移碎务 |

**建议部署流程：**

1. ✅ 部署 Raft 集群：`bash deploy-raft.sh start`
2. ✅ 部署 ProxySQL：`bash deploy-proxysql.sh start`
3. ✅ 启动监控：`bash monitor-raft.sh continuous`（后台）
4. ✅ 运行故障演练：`bash test-failover.sh master-crash`
5. ✅ 验证恢复钩子：检查日志和通知

---

**文档版本**: 1.0  
**最后更新**: 2026-02-05  
**适用版本**: Orchestrator 3.2+, ProxySQL 2.5+
