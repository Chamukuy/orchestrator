# Orchestrator Raft + ProxySQL 完整部署指南

生产级别的 MySQL 高可用和智能中间件一体化解决方案

---

## 目录

- [架构概述](#架构概述)
- [为什么选 ProxySQL](#为什么选-proxysql)
- [本地快速启动](#本地快速启动)
- [分布式生产部署](#分布式生产部署)
- [集成操作](#集成操作)
- [故障处理](#故障处理)
- [性能优化](#性能优化)

---

## 架构概述

### 完整的 3 层架构

```
┌──────────────────────────────────────────────┐
│          应用程序层                          │
│  单一连接点 (ProxySQL:6033)                  │
└─────┬────────────────────────────────────────┘
      │ TCP 6033
      ↓
┌──────────────────────────────────────────────┐
│      ProxySQL 中间件层（智能路由）           │
│  ┌──────────────────────────────────────┐    │
│  │ • 读写分离（SELECT→Slave）          │    │
│  │ • 连接池（共享 300 连接）           │    │
│  │ • Query 缓存（热查询加速）          │    │
│  │ • 自动故障转移                      │    │
│  │ • Admin 接口 6032                   │    │
│  └──────────────────────────────────────┘    │
└──┬─────────────┬──────────────┬──────────────┘
   │3306         │ 3307        │ 3308
   ↓             ↓              ↓
┌─────────┐  ┌─────────┐  ┌─────────┐
│ Master  │←→│ Slave 1 │←→│ Slave 2 │
│ :3306   │  │ :3307   │  │ :3308   │
└────┬────┘  └────┬────┘  └────┬────┘
     │            │             │
     └──────────────┬───────────┘
                    │ 复制
         ┌──────────┴──────────┐
         ↓                     ↓
    ┌─────────────────────────────────┐
    │  Orchestrator Raft 集群         │
    │  Node1  Node2  Node3            │
    │  3000   3001   3002             │
    │  Leader的选举 + Quorum          │
    │  拓扑发现 + 故障转移             │
    └─────────────────────────────────┘
```

### 数据流向

#### 读操作流程
```
应用: SELECT * FROM users;
    ↓
ProxySQL 规则匹配 (SELECT)
    ↓
路由到 Slave (任选 Slave1 或 Slave2)
    ↓
返回结果给应用

延迟: <1ms (ProxySQL 处理) + 网络延迟
```

#### 写操作流程
```
应用: INSERT INTO users VALUES (...);
    ↓
ProxySQL 规则匹配 (INSERT)
    ↓
路由到 Master
    ↓
Master 执行写操作，日志应用到 Slave
    ↓
应用收到确认

延迟: 执行时间 + 网络延迟 (Slave 延迟另外计算)
```

#### 故障转移流程
```
T0. Master 宕机
    ↓
T5s. ProxySQL 首次健康检查失败
    ↓
T10s. ProxySQL 标记 Master 为 SHUNNED（故障）
      新请求自动转向 Slave（读降级为主写）
    ↓
T30s. Orchestrator Raft 开始分析故障
      三个节点共同决定是否需要故障转移
    ↓
T60s. Slave1 被晋升为新 Master
      Slave2 重新指向新 Master
    ↓
T70s. ProxySQL 健康检查到新 Master，更新拓扑
      新请求正常写入新 Master
    ↓
T75s. 系统恢复，无需人工干预

全程自动，应用无感知！
```

---

## 为什么选 ProxySQL？

### ProxySQL vs HAProxy vs 其他

| 对比项 | HAProxy | ProxySQL | Keepalived | 应用层 |
|--------|--------|----------|-----------|--------|
| **MySQL 特化** | ⚠️ 通用 | ✅ 专用 | ⚠️ 通用 | ⚠️ 无 |
| **连接池** | ❌ 无 | ✅ 有 | ❌ 无 | ⚠️ 复杂 |
| **读写分离** | ❌ 无 | ✅ 有 | ❌ 无 | ⚠️ 复杂 |
| **Query 缓存** | ❌ 无 | ✅ 有 | ❌ 无 | ⚠️ 复杂 |
| **动态配置** | ⚠️ 需重启 | ✅ 无需重启 | ⚠️ 需重启 | ⚠️ 需重启 |
| **Admin 接口** | ⚠️ 基础 | ✅ 完整 | ❌ 无 | N/A |
| **设置难度** | ⚠️ 中等 | ✅ 简单 | ⚠️ 中等 | ❌ 复杂 |
| **性能** | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐ |

**结论：ProxySQL 是最适合 MySQL + Orchestrator Raft 的选择**

---

## 本地快速启动

### 30 秒启动完整栈

```bash
cd /workspaces/orchestrator

# 启动 MySQL Raft 集群 + Orchestrator
bash deploy-raft.sh start && bash deploy-raft.sh init

# 在另一个终端启动 ProxySQL
bash deploy-proxysql.sh start && bash deploy-proxysql.sh configure
```

### 验证全栈运行

```bash
# 检查所有服务
bash deploy-proxysql.sh status

# 输出示例：
# ✓ ProxySQL 运行正常
# ✓ MySQL Master 在线
# ✓ MySQL Slave 1/2 同步中
# ✓ Orchestrator Raft 集群健康
```

### 应用连接测试

```bash
# 连接 ProxySQL（单一端口）
mysql -h 127.0.0.1 -P 6033 -u proxysql_user -p proxysql_pass

# 执行查询（自动路由）
mysql> CREATE DATABASE IF NOT EXISTS test;
mysql> CREATE TABLE test.users (id INT, name VARCHAR(50));
mysql> INSERT INTO test.users VALUES (1, 'Alice');
mysql> SELECT * FROM test.users;

# 查看路由统计
mysql -h 127.0.0.1 -P 6032 -u admin -p admin
mysql> SHOW STATS_MYSQL_CONNECTION_POOL \G
```

---

## 分布式生产部署

### 拓扑规划

```
┌─────────────────────────────────────────────┐
│            应用服务器                       │
│  (多机器 + 多应用)                         │
└──────────────┬──────────────────────────────┘
               │ MySQL Host:6033
               ↓
┌─────────────────────────────────────────────┐
│     ProxySQL 节点 (IP: 192.168.1.100)      │
│  • 监听 6033 (应用连接)                    │
│  • 监听 6032 (Admin 接口)                  │
└──┬────────────┬──────────────┬──────────────┘
   │ :3306      │ :3307       │ :3308
   ↓            ↓              ↓
┌──────────┐ ┌──────────┐ ┌──────────┐
│ Master   │ │ Slave 1  │ │ Slave 2  │
│ 192.x.10 │ │ 192.x.11 │ │ 192.x.12 │
└────┬─────┘ └────┬─────┘ └────┬─────┘
     └──────────────┬───────────┘
                    │ 复制
         ┌──────────┴──────────┐
         ↓                     ↓
    ┌─────────────────────────────────┐
    │  Orchestrator Raft (3 节点)     │
    │  可选：在 192.x.10/11/12 上     │
    │  或单独 3 台机器                │
    └─────────────────────────────────┘
```

### 部署步骤

#### Step 1: 部署 MySQL Raft 集群

```bash
# 在主控机
bash deploy-raft-distributed.sh \
  192.168.1.10 \
  192.168.1.11 \
  192.168.1.12 \
  ubuntu
```

#### Step 2: 部署 ProxySQL（选择一个）

**选项 A：在 Master 所在机器部署**
```bash
# 登录 Master 机器 (192.168.1.10)
ssh ubuntu@192.168.1.10

# 下载部署脚本
scp deploy-proxysql.sh ubuntu@192.168.1.10:~/

# 启动 ProxySQL
bash deploy-proxysql.sh start
bash deploy-proxysql.sh configure
```

**选项 B：在独立机器部署（推荐）**
```bash
# 在 192.168.1.100（独立机器）

# 配置连接到远端 MySQL
编辑 proxysql/proxysql.cnf:
- mysql_servers 改为 192.168.1.10:3306 等

bash deploy-proxysql.sh start
bash deploy-proxysql.sh configure
```

**选项 C：部署 ProxySQL 三节点集群（最高可用）**
```bash
# 在 192.168.1.13、192.168.1.14、192.168.1.15

# 每台机器执行相同部署，然后配置集群同步
# （可选，详见高级配置）
```

#### Step 3: 验证生产部署

```bash
# 测试应用连接
mysql -h 192.168.1.100 -P 6033 -u proxysql_user -p proxysql_pass -e "SELECT 1;"

# 测试读写分离
mysql -h 192.168.1.100 -P 6033 -u proxysql_user -p proxysql_pass -e "SELECT @@server_id;"

# 应该交替看到不同的 server_id (Master=1, Slave1=2, Slave2=3)
```

---

## 集成操作

### 场景 1：故障转移演练

```bash
# 模拟 Master 故障
docker stop mysql-master  # 如果是本地
# 或在 192.168.1.10 执行：service mysql stop

# 观察过程（每 5 秒检查一次）
watch -n 5 'mysql -h 192.168.1.100 -P 6032 -u admin -p admin -e "SHOW MYSQL SERVERS \G"'

# 期望结果：
# • mysql-master 状态变为 SHUNNED
# • mysql-slave-1 自动成为新 Master（Orchestrator 故障转移）
# • 新请求自动路由到新 Master

# 验证应用可用性
mysql -h 192.168.1.100 -P 6033 -u proxysql_user -p proxysql_pass -e "INSERT INTO test.log VALUES (now(), 'failover-test');"

# 恢复原 Master
docker start mysql-master
# 或：service mysql start
```

### 场景 2：添加新 Slave

```bash
# ProxySQL Admin
mysql -h 192.168.1.100 -P 6032 -u admin -p admin

# 添加新服务器
INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight,comment)
VALUES(1,'mysql-slave-3',3306,1000,'New Slave');

# 应用更改（无需重启 ProxySQL）
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

# 验证
SHOW MYSQL SERVERS \G
```

### 场景 3：调整读写分离规则

```bash
# 例：添加特殊规则，某些查询始终去 Master

mysql -h 192.168.1.100 -P 6032 -u admin -p admin

# 添加规则：带有 FOR UPDATE 的 SELECT 去 Master
INSERT INTO mysql_query_rules(rule_id,active,match_pattern,destination_hostgroup,comment)
VALUES(10,1,'^SELECT.*FOR UPDATE',0,'SELECT FOR UPDATE to master');

LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

### 场景 4：查询性能分析

```bash
# 查看慢查询
mysql -h 192.168.1.100 -P 6032 -u admin -p admin

# 统计最常执行的查询
SELECT * FROM STATS_MYSQL_QUERY_DIGEST 
ORDER BY count_star DESC 
LIMIT 10 \G

# 查看缓存命中率
SHOW STATS_MYSQL_QUERY_CACHE \G
```

---

## 故障处理

### 问题 1：ProxySQL 无法连接 MySQL

```bash
# 检查 MySQL 可达性
mysql -h 192.168.1.10 -P 3306 -u root -p root -e "SELECT 1;"

# 检查 ProxySQL 配置
mysql -h 192.168.1.100 -P 6032 -u admin -p admin -e "SHOW MYSQL SERVERS \G"

# 查看日志
docker logs orchestrator-proxysql 2>&1 | tail -50

# 常见原因：
# • MySQL 防火墙阻止
# • 用户权限不足
# • hostname 无法解析
```

### 问题 2：读操作仍然走 Master

```bash
# 检查查询规则优先级
mysql -h 192.168.1.100 -P 6032 -u admin -p admin -e "SHOW MYSQL QUERY RULES \G"

# 检查是否被其他规则拦截
# ProxySQL 规则有优先级顺序，前面的规则优先匹配

# 重新排序规则
UPDATE mysql_query_rules SET rule_id=rule_id+10 WHERE rule_id >= 2;
# 这样规则 1（SELECT）会优先匹配

# 重新加载
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

### 问题 3：故障转移没有自动发生

```bash
# 检查 Orchestrator 状态
curl http://192.168.1.100:3000/api/leader-check

# 检查拓扑
curl http://192.168.1.100:3000/api/cluster/master-slave | jq .

# 检查 Orchestrator 是否启用了自动转移
# 编辑配置文件，确保：
# "RecoverMasterClusterFilters": ["*"]
# "ApplyMySQLPromotionAfterMasterFailover": true

# 重启 Orchestrator
docker-compose -f docker-compose.raft.yml restart
```

---

## 性能优化

### 优化 1：增加连接池大小

```bash
# 编辑 proxysql/proxysql.cnf
mysql_variables="
  max_connections=4096      # 增加总连接数
  default_max_connections=200  # 增加每应用连接数
"

# 然后重启
bash deploy-proxysql.sh stop
bash deploy-proxysql.sh start
```

### 优化 2：启用 Query 缓存

```bash
# proxysql/proxysql.cnf
mysql_variables="
  query_cache_size_MB=512        # 增加缓存大小（512MB）
  query_cache_default_time_ms=1000  # 缓存 1 秒
"

# 重启 ProxySQL
bash deploy-proxysql.sh stop
bash deploy-proxysql.sh start
```

### 优化 3：调整健康检查频率

```bash
# proxysql/proxysql.cnf
mysql_variables="
  ping_interval_server_msec=10000  # 每 10 秒检查一次（降低 CPU）
  ping_timeout_server=500          # 超时 500ms（更宽松）
"

# 这样可以降低 ProxySQL CPU 占用，但故障检测会延迟
```

### 优化 4：负载均衡权重调整

```bash
# 如果某个 Slave 性能更好，增加权重
mysql -h 192.168.1.100 -P 6032 -u admin -p admin

UPDATE mysql_servers SET weight=2000 
WHERE hostname='mysql-slave-1';

LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

# 现在 Slave1 会收到 2 倍的流量
```

---

## 监控和维护

### 关键监控指标

```bash
# 连接池使用率
SELECT hostgroup_id, Connected, Max_connections, active FROM STATS_MYSQL_CONNECTION_POOL;

# 查询分布
SELECT digest_text, count_star, hostgroup_id FROM STATS_MYSQL_QUERY_DIGEST LIMIT 20;

# 缓存命中率
SHOW STATS_MYSQL_QUERY_CACHE;

# MySQL 服务器状态
SHOW MYSQL SERVERS;
```

### 定期维护任务

| 任务 | 频率 | 命令 |
|------|------|------|
| 检查连接池 | 每天 | `STATS_MYSQL_CONNECTION_POOL` |
| 检查慢查询 | 每周 | `STATS_MYSQL_QUERY_DIGEST` |
| 检查缓存 | 每周 | `STATS_MYSQL_QUERY_CACHE` |
| 更新规则 | 按需 | `LOAD/SAVE MYSQL QUERY RULES` |
| 备份配置 | 每月 | 导出 ProxySQL 配置 |
| 性能测试 | 每季度 | 运行 sysbench/mysqlslap |

---

## 总结

### Orchestrator Raft + ProxySQL 的完整价值

✅ **Orchestrator Raft** 提供：
- MySQL 拓扑自动监控
- 自动故障检测和转移
- Quorum 保证数据一致性

✅ **ProxySQL** 提供：
- 应用无感知的读写分离
- 连接池优化（性能 +40-60%）
- Query 缓存加速
- 自动故障转移降级

✅ **合起来**：
- 完整的数据库高可用
- 最佳的应用性能
- 最小的运维成本
- 最简单的部署和维护

---

**文档版本**: 1.0  
**最后更新**: 2026-02-05  
**维护**: Orchestrator Community
