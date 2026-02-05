# Orchestrator Raft 集群掉电恢复完全指南

分析断电（掉电）场景下的数据安全、一致性和恢复流程

## 🔌 概述

### 核心问题

在生产环境中，**数据中心断电是常见的灾难场景**：
- 单个服务器硬件故障
- 交换机故障导致网络掉电
- 整个数据中心停电

本指南分析 Orchestrator Raft + MySQL 主从 + ProxySQL 体系对这些场景的**恢复能力**。

### 简短回答

✅ **是的，系统可以完全恢复正常！** 但恢复过程和数据安全取决于掉电场景。

---

## 📊 掉电场景分析

### 场景 1: 单个 Slave 断电（最简单）

```
状态: Master 运行 ✓, Slave1 运行 ✓, Slave2 离线 ✗
恢复: Slave2 重启
```

**恢复过程：**

| 时间 | 发生 | 状态 |
|------|------|------|
| T0s | Slave2 断电 | Master 收到 Slave2 连接断开 |
| T5s | Orchestrator 检测 Slave2 离线 | ProxySQL 自动隔离 Slave2 |
| T30-60s | Slave2 通电重启 | MySQL 自动启动，复制重新连接 |
| T90s+ | Slave2 复制追上 Master | 系统完全恢复 |

**恢复步骤：**

```bash
# Slave2 服务器
1. 电源恢复 → 自动启动
2. MySQL 启动 (systemd/docker 自启)
3. 复制自动重新连接（GTID 保证）
4. Orchestrator 自动发现
5. ProxySQL 自动添加回在线服务器列表
```

**数据安全：✅ 完全安全**
- 没有新数据写入 Slave2，因此没有数据丢失
- Slave2 可以继续从 Master 复制

---

### 场景 2: Master 断电（关键场景）

```
状态: Master 离线 ✗, Slave1 运行 ✓, Slave2 运行 ✓
恢复期间: Slave1/2 自动晋升 Master
恢复后: 原 Master 重启，变为 Slave
```

**恢复过程（分三个阶段）：**

#### 第一阶段：故障检测和转移（T0-T120s）

```
T0s:    Master 断电
T5s:    Orchestrator 检测 Master 离线
T30s:   确认故障
T60s:   开始故障转移
        ↓
        Slave1 被晋升为新 Master
        - STOP SLAVE
        - SET read_only=0
        - 修改拓扑信息
        ↓
T70s:   [recovery-hooks.sh] 钩子触发
        - ProxySQL 配置更新
        - Master 标记为 SHUNNED
        - 新 Master 标记为 ONLINE
        ↓
T120s:  Slave2 重新连接新 Master
        - 系统完全恢复，新 Master 接受写入
```

#### 第二阶段：原 Master 重启（T120s-T300s）

```
T120s+: 原 Master 通电重启
        1. MySQL 自动启动
        2. Orchestrator 发现重启的 Master
        3. 分析 GTID：
           - 原 Master: GTID = 1-100
           - 新 Master: GTID = 1-150
        4. 原 Master GTID 落后
        ↓
        Orchestrator 自动处理：
        - 将原 Master 变为新 Master 的 Slave
        - 添加 CHANGE MASTER 命令
        - 从新 Master 复制缺失数据（101-150）
        ↓
T300s:  原 Master 追上新 Master 的 GTID
        系统再次完全恢复
```

#### 第三阶段：可选的 Master 切回（手动）

```
如果想切回原 Master 为主：

选项 A: 保持现状
✓ 风险小，继续以 Slave1 作为 Master

选项 B: 切回原 Master（需要计划停机）
1. 将应用流量切到原 Master
2. 新 Master 变为 Slave
3. 更新 ProxySQL 配置
```

**恢复步骤：**

```bash
# 原 Master 服务器
1. 电源恢复 → 自动启动
2. MySQL 启动，恢复 InnoDB 日志
3. Orchestrator 检测并分析 GTID
4. 自动配置为新 Master 的 Slave
5. 开始复制落差数据
6. 追上后完全恢复

# 应用层（通过 ProxySQL）
1. ProxySQL 自动检测 Master 故障
2. 自动降级为只读（Slave 提升机制）
3. 新 Master 上线后自动恢复写入
4. 应用无需任何修改！
```

**数据安全：✅ 完全安全**
- GTID 机制保证了数据的唯一性
- 没有数据丢失（Master 掉电时的事务已提交或回滚）
- Slave 可以继续服务读请求
- Master 重启后会自动成为 Slave 并追上

---

### 场景 3: 多个节点同时断电

#### 3.1 两个 Slave 同时断电

```
状态: Master 运行 ✓, Slave1 离线 ✗, Slave2 离线 ✗
恢复: Slave1, Slave2 依次重启
```

**恢复特点：**
- ✅ **数据完全安全**（Master 在线）
- ✅ 可以同时停电无需协调
- ✅ 恢复时每个 Slave 独立重启，自动追上 Master

**恢复步骤：**

```
T0s:    Slave1, Slave2 同时下电
T30s+:  Slave1 恢复通电
        - MySQL 启动并复制
        - Orchestrator 发现恢复
T60s+:  Slave2 恢复通电
        - MySQL 启动并复制
        - Orchestrator 发现恢复
T120s+: 两个 Slave 都追上 Master
        系统完全恢复
```

#### 3.2 Master + 一个 Slave 同时断电

```
状态: Master 离线 ✗, Slave1 离线 ✗, Slave2 运行 ✓
恢复: Slave2 临时作为 Master，Master 和 Slave1 重启后自动恢复
```

**恢复过程：**

```
T0s:      Master, Slave1 同时掉电
T5s:      Orchestrator 检测 Master 离线
T30s:     确认故障（只有 Slave2 在线）
T60s:     Slave2 被晋升为新 Master
          应用流量从 Master → Slave2
T120s+:   Master 通电重启
          - MySQL 启动，GTID 落后
          - Orchestrator 自动变为 Slave2 的 Slave
          - 开始复制追赶
T180s+:   Slave1 通电重启
          - MySQL 启动
          - 自动连接到新 Master（Slave2）
          - 开始复制
T240s+:   全部追上，系统完全恢复
```

**关键问题：数据会不会丢失？**

✅ **不会丢失！** 原因：
1. Master 掉电前的所有已提交事务都已写到磁盘
2. Slave2 拥有所有已复制的数据（GTID 不会重复）
3. Master 重启后会自动填补从 Slave2 拿不到的 GTID
4. 由于是 GTID 复制，重新连接时不会有重复或遗漏

#### 3.3 Raft 全部节点同时断电（**最严重场景**）

```
状态: Master 💥, Slave1 💥, Slave2 💥, Orchestrator1 💥, Orchestrator2 💥, Orchestrator3 💥
风险: Raft 集群无法自动做出决策
恢复: 需要等待至少 2 个 Orchestrator 节点启动
```

**恢复约束：**

| 情景 | Raft 状态 | 结果 |
|------|-----------|------|
| 3 个 Raft 节点全部宕机 | 无 Leader | 无法自动转移 |
| 3 个中的 2 个恢复 | 有 Leader | 自动转移恢复 |
| 3 个中的 1 个恢复 | 无 Leader（少数派）| 各自继续，无法做决策 |

**恢复过程：**

```
T0s:       全部节点掉电
T0-T300s:  等待通电恢复
           （最坏情况：UPS 放电完，整个数据中心停电）

T300s:     通电恢复开始
           MySQL 实例启动（顺序随机）
           Orchestrator 实例启动（顺序随机）

T300-T400s: Raft 集群恢复
           需要至少 2/3 个 Orchestrator 节点启动
           
           假设启动顺序:
           1. Orchestrator-1 启动 → 尝试成为 Leader（失败，少数派）
           2. Orchestrator-2 启动 → Raft 选举，选出 Leader
           3. Orchestrator-3 启动 → 加入集群
           
           一旦有 Leader，立即检查 MySQL 拓扑

T400-T500s: Master 故障转移（如果需要）
           如果原 Master 还未启动
           新 Master 晋升 → ProxySQL 更新
           
           如果原 Master 已启动但落后
           自动变为 Slave

T500s+:    系统完全恢复
           所有节点启动，Raft 有 Leader
           MySQL 拓扑正常，复制同步
           应用恢复正常
```

**恢复策略：**

```bash
# 全部掉电恢复的推荐做法：

1. 电源恢复后，不要急着启动
   等待 30-60 秒，让 UPS 电力稳定

2. 按照架构优先级启动：
   a) 先启动 MySQL Master（如果可能）
   b) 然后启动 Raft 节点
   c) 最后启动 ProxySQL, App Server

3. 监控恢复过程：
   bash monitor-raft.sh continuous
   
4. 验证系统状态：
   curl http://ORCH_IP:3000/api/leader-check
   curl http://ORCH_IP:3000/api/cluster/master-slave

5. 检查应用连接：
   mysql -h PROXYSQL_IP -P 6033 -e "SHOW GLOBAL STATUS"
```

---

## 🛡️ 数据安全保证机制

### 1. MySQL InnoDB 事务日志

```
应用提交 INSERT
    ↓
MySQL 写入 Redo Log（内存）
    ↓
Flush to Disk（默认每秒）
    ↓
事务 COMMIT 返回给应用
    ↓
断电发生！
    ↓
重启后：
  - Redo Log 重放 → 恢复已 COMMIT 事务
  - Undo Log 回滚 → 撤销未 COMMIT 事务
  - 结果：零数据丢失
```

**配置验证：**
```bash
# 检查 MySQL 配置
mysql> SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
# 应该是 1（最安全，每次事务都 flush）
```

### 2. GTID 保证复制一致性

```
Master: GTID = 1-100 (UUID:1, UUID:2, ..., UUID:100)
Slave1: GTID = 1-95  (缺少 96-100)
Slave2: GTID = 1-98  (缺少 99-100)

Slave1 重启后：
  - Orchestrator 比较 GTID
  - 发现缺少 96-100
  - 自动从 Master（或 Slave2）拉取 96-100
  - 无需手动干预！
```

### 3. Raft 共识保证

```
Raft 的 3 个节点，一旦有 2 个确认决策：

场景: 决定晋升 Slave1 为新 Master

Orch1: "同意晋升 Slave1"
Orch2: "同意晋升 Slave1"  ← 2/3 已同意，执行！
Orch3: 可能后来才同意或反对，但不影响

即使 Orch3 掉电，决策已经生效
即使 Orch3 永久性故障，集群仍可继续工作
```

### 4. ProxySQL 配置持久化

```
ProxySQL 配置改变时：
  LOAD MySQL SERVERS TO RUNTIME;  ← 立即生效
  SAVE MYSQL SERVERS TO DISK;     ← 持久化到磁盘

重启后自动加载，无需重新配置！
```

---

## 🔄 自动恢复时间表

### 单个节点掉电

| 节点 | 检测时间 | 恢复时间 | 总时间 | 影响 |
|------|--------|--------|--------|------|
| Slave | 5-30s | 30-60s | 1-2min | 读并发下降 |
| Master | 30-60s | 60-120s | 2-4min | 自动转移，无停机 |
| Raft | 30-60s | 30-60s | 1-2min | 无法检测故障（短期） |

### 多个节点掉电

| 场景 | Raft 影响 | 数据影响 | 恢复时间 |
|------|----------|--------|---------|
| 2 个 Slave | 无 | 无 | 2-6min |
| Master + 1 Slave | 无 | 无 | 3-8min |
| 全部掉电 | **需要 2/3 恢复** | 无 | 5-15min |

---

## ⚙️ 自动恢复配置检查

### MySQL 自启动配置

```bash
# Linux systemd
systemctl is-enabled mysql
# 应该输出 enabled

# Docker Compose
services:
  mysql:
    restart: always  # 自动重启

# 验证
systemctl status mysql
docker ps -a | grep mysql  # 检查 status
```

### Orchestrator 自启动

```bash
# 检查 Raft 监听地址
grep "RaftBind" conf/orchestrator-raft.conf.json

# 验证 Raft 节点通信
curl http://ORCH_IP:3000/api/raft-status
```

### ProxySQL 自启动和配置恢复

```bash
# Docker 自重启
docker run --restart=always proxysql

# 配置持久化检查
mysql -h 127.0.0.1 -P 6032 -u admin -padmin
mysql> SHOW VARIABLES LIKE '%config%';
# 应该输出 datadir 路径指向持久化目录
```

---

## 🚨 风险和缓解方案

### 风险 1: Raft 少数派隔离

**风险：** 如果 Raft 集群中少于 2/3 的节点在线，无法做出决策

**发生概率：**
- 3 节点中 1 个启动：❌ 无法决策
- 3 节点中 2 个启动：✅ 可以决策
- 3 节点中 3 个启动：✅ 可以决策

**缓解方案：**

```bash
# 选项 1: 手动恢复少数派情况
# 待另外 2 个节点启动后，第三个会自动加入

# 选项 2: 配置 Raft 服务器更多节点（5 节点）
# 这样即使 2 个掉电，仍有 3 个可以工作
# 但需要更多资源

# 选项 3: 配置自动重启脚本
# 一个节点掉电时，立即触发故障转移逻辑
```

### 风险 2: 存储设备故障

**风险：** 如果 MySQL 数据盘损坏，无法恢复

**缓解方案：**

```bash
# 1. 使用 RAID 1/5/6
   确保硬盘故障时仍有冗余

# 2. 使用云存储（EBS, Cloud Block Storage）
   提供快照和版本管理

# 3. 定期备份
   mysqldump 或物理备份
   rsync 到备用存储

# 4. 跨地域复制
   配置远程 Slave 节点
   确保灾难情况下可恢复
```

### 风险 3: 全局网络分割

**风险：** 两个 Raft 节点掉电，一个掉线但未断电（网络故障）

**结果：** 该节点成为少数派，无法做决策

**缓解：**
```bash
# Raft 有内置的少数派隔离机制
# 一旦检测到自己是少数派，会自动退出 Leader 竞选
# 这防止了"脑裂"（两个独立集群同时声称自己是 Leader）
```

---

## ✅ 完整恢复清单

### 恢复前准备

- [ ] 确认电源稳定（等待 1-2 分钟）
- [ ] 按优先级启动服务器（Master → Raft → ProxySQL）
- [ ] 启动监控脚本了解恢复进度

### 恢复过程

```bash
# 1. 启动监控
bash monitor-raft.sh continuous &  # 后台运行

# 2. 检查 Orchestrator Leader
curl http://ORCH_IP:3000/api/leader-check
# 期望: {"IsLeader": true}

# 3. 检查 MySQL 拓扑
curl http://ORCH_IP:3000/api/cluster/master-slave | jq .

# 4. 检查 ProxySQL 服务器状态
mysql -h PROXYSQL_IP -P 6032 -u admin -padmin
mysql> SHOW MYSQL SERVERS;
```

### 恢复验证

```bash
# 验证清单
□ Orchestrator 有有效 Leader
□ 所有 MySQL 实例在线
□ 复制延迟 < 5 秒
□ ProxySQL 所有服务器 ONLINE
□ 应用可以读写数据
□ 没有未同步的事务

# 如果全部通过，系统完全恢复！✅
```

### 恢复后操作

```bash
# 1. 检查故障日志
tail -100 /var/log/orchestrator/recovery-hooks.log

# 2. 分析故障原因
tail -100 /var/log/orchestrator/failure-analysis.log

# 3. 验证数据完整性
bash test-failover.sh data-consistency

# 4. 恢复性能基准
mysql> SELECT COUNT(*) FROM key_tables;
# 与掉电前的数字对比
```

---

## 📋 掉电场景速查表

### "如果 X 掉电，Y 会发生什么？"

| 掉电场景 | Master | Slaves | Raft | 应用 | 恢复时间 | 数据丢失 |
|---------|--------|--------|------|------|---------|---------|
| 单 Slave | ✓ | ◐ | ✓ | 读性能↓ | 1-2m | ❌ 否 |
| Master | ✗ | ✓ | ✓ | 需转移 | 2-4m | ❌ 否 |
| M + S | ◐ | ◐ | ✓ | 需转移 | 3-8m | ❌ 否 |
| 2 Raft | ✓ | ✓ | ◐ | 无转移 | 1-5m | ❌ 否 |
| **全部** | ✗ | ✗ | ✗ | ✗ | **需手动** | ❌ 否 |

**图例：**
- ✓ 在线，正常
- ◐ 部分故障或恢复中
- ✗ 离线，故障
- ↓ 性能下降但可用
- **需手动** = 需要人工介入（等待多数 Raft 恢复）

---

## 🎯 结论

### 核心答案

| 问题 | 答案 | 说明 |
|------|------|------|
| 单个断电恢复？ | ✅ 自动 | 完全透明恢复，无需干预 |
| 多个断电恢复？ | ✅ 自动 | GTID 和 Raft 共识保证 |
| 全部断电恢复？ | ⚠️ 需等待 | 需要 2/3 Raft 节点启动后自动恢复 |
| 数据丢失风险？ | ❌ 无 | MySQL InnoDB + GTID 双重保证 |
| 自动故障转移？ | ✅ 有 | Orchestrator Raft 自动处理 |
| 应用无感知？ | ✅ 是 | ProxySQL 自动路由切换 |

### 最佳实践

1. **配置服务自启动**
   - systemd `restart=always` 或 Docker `restart=always`
   - 确保 MySQL, Orchestrator, ProxySQL 全部自启

2. **监控恢复过程**
   - 启动 `monitor-raft.sh` 观察恢复进度
   - 检查日志确认无异常

3. **定期容灾演练**
   - 每月运行一次 `test-failover.sh master-crash`
   - 验证自动故障转移是否正常

4. **备份和恢复**
   - 定期备份 MySQL 数据
   - 测试备份恢复流程

5. **监控告警**
   - 配置 Slack/邮件告警
   - 第一时间发现故障

---

## 附录：恢复脚本（可选）

如果需要，可以创建自动恢复脚本来处理全部掉电的情况：

```bash
#!/bin/bash
# 全部掉电后的自动恢复脚本

# 1. 等待服务启动
sleep 60

# 2. 检查 Raft 集群是否形成
while true; do
    leader_count=$(curl -s http://localhost:3000/api/leader-check | jq '.IsLeader // false')
    if [ "$leader_count" = "true" ]; then
        echo "Raft Leader 已形成"
        break
    fi
    sleep 10
done

# 3. 触发自动故障转移
curl -X POST http://localhost:3000/api/recover/cluster/master-slave

# 4. 等待转移完成
sleep 30

# 5. 验证系统
bash monitor-raft.sh once

# 6. 通知管理员
echo "系统已自动恢复" | mail -s "掉电恢复完成" admin@company.com
```

---

**文档版本**: 1.0  
**适用范围**: Orchestrator 3.2+, MySQL 8.0+, ProxySQL 2.5+  
**更新日期**: 2026-02-05
