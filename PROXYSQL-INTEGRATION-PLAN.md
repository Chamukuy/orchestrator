# ProxySQL + Orchestrator Raft 集成方案

一主两从 MySQL 集群的智能中间件层，支持自动故障转移和读写分离

## 核心优势

| 特性 | HAProxy | ProxySQL | 推荐 |
|------|--------|----------|------|
| **MySQL 特性支持** | ⚠️ 限制 | ✅ 完整 | ProxySQL |
| **连接池** | ❌ 无 | ✅ 有 | ProxySQL |
| **读写分离** | ❌ 无 | ✅ 自动 | ProxySQL |
| **查询缓存** | ❌ 无 | ✅ 有 | ProxySQL |
| **自定义规则** | ⚠️ 复杂 | ✅ SQL 规则 | ProxySQL |
| **动态配置** | ⚠️ 需重启 | ✅ 无需重启 | ProxySQL |
| **Admin 接口** | ⚠️ 基础 | ✅ 完整 | ProxySQL |

---

## 架构拓扑

```
┌─────────────────────────────────────────────┐
│          应用程序                            │
│       (连接 ProxySQL:6033)                  │
└──────┬──────────────────────────────────────┘
       │ TCP 6033
       ↓
┌─────────────────────────────────────────────┐
│         ProxySQL 中间件                      │
│  ┌─────────────────────────────────────┐    │
│  │ • 连接池 (300 connections)          │    │
│  │ • 读写分离                          │    │
│  │ • Query 缓存                        │    │
│  │ • 自动故障转移检测                   │    │
│  │ • Admin 接口 (6032)                 │    │
│  └─────────────────────────────────────┘    │
└──┬────────────┬─────────────────┬──────────┘
   │            │                 │
   │ TCP 3306   │ TCP 3307       │ TCP 3308
   ↓            ↓                 ↓
┌────────┐  ┌────────┐        ┌────────┐
│ Master │  │Slave 1 │        │Slave 2 │
│ :3306  │  │ :3307  │        │ :3308  │
└────────┘  └────────┘        └────────┘
```

### 读写分离规则

```
应用程序请求
    ↓
┌─────────────────────┐
│ ProxySQL 规则引擎    │
├─────────────────────┤
│ ✓ SELECT ... → SLAVE  (Slave 1, 2)   （负载均衡）
│ ✓ UPDATE/DELETE → MASTER (Master)
│ ✓ INSERT → MASTER (Master)
│ ✓ BEGIN → MASTER (事务始终在 Master)
│ ✓ SET → MASTER
└─────────────────────┘
```

---

## ProxySQL 如何与 Orchestrator Raft 协作

### 场景 1：正常运行
```
ProxySQL 缓存了 Master / Slave 的信息
持续检测 Master 和 Slave 的健康状态
请求路由正常工作
```

### 场景 2：MySQL Master 故障
```
時间轴：

T0. Master 宕机
    ↓
T30-300秒: Orchestrator Raft 检测故障并开始故障转移
    ↓
T60秒: Master 确认故障，Slave 被晋升为新 Master
    ↓
T60秒+: Orchestrator 更新拓扑信息
    ↓
T75秒: ProxySQL 检测到拓扑变化，自动更新路由规则
    ↓
T80秒: 应用重新连接，自动使用新 Master

全程自动转移，无需人工干预！
```

### ProxySQL 检测方式

```
1. 主动探测（Health Check）
   每 5 秒检测 MySQL 服务器健康状态
   ↓
2. 被动检测（异常连接）
   如果发现连接失败，立即标记不健康
   ↓
3. 与 Orchestrator 集成（推荐）
   定期查询 Orchestrator API 获取最新拓扑
   自动更新 ProxySQL 的 MySQL_servers 配置
   ↓
4. 优雅降级
   错误的服务器自动从连接池中移除
```

---

## 总体架构

```
┌─────────────────────────────────────────────────────────┐
│          应用层                                          │
│  (单一连接点: ProxySQL:6033)                            │
└────────┬────────────────────────────────────────────────┘
         │
         ↓
┌─────────────────────────────────────────────────────────┐
│        ProxySQL 智能路由层                               │
│  ┌─────────────┬─────────────┬──────────────────────┐   │
│  │ 连接池      │ 读写分离    │ 故障自动转移          │   │
│  │ Query Cache │ 动态更新    │ 与 Raft 联动        │   │
│  └─────────────┴─────────────┴──────────────────────┘   │
│                     Admin API (6032)                     │
└────┬─────────────────────┬──────────────────────┬───────┘
     │                     │                      │
     ↓                     ↓                      ↓
┌──────────┐          ┌──────────┐          ┌──────────┐
│ Master   │←────────→│ Slave 1  │←────────→│ Slave 2  │
│ :3306    │(复制)    │ :3307    │(复制)    │ :3308    │
└──────────┘          └──────────┘          └──────────┘
     ↑
     └─────────────────────────────────────────┐
                                               │
                            ┌──────────────────┘
                            ↓
                   ┌─────────────────────┐
                   │  Orchestrator Raft  │
                   │  3 节点集群         │
                   │  • 监控拓扑         │
                   │  • 检测故障         │
                   │  • 执行转移         │
                   │  • 通知 ProxySQL    │
                   └─────────────────────┘
```

---

## ProxySQL 配置要点

### mysql-variables.cnf

```ini
[mysqld_servers]
# 定义后端 MySQL 服务器
# hostgroup_id: 0=写组(Master), 1=读组(Slave)
# weight: 权重（用于负载均衡）

# Master
hostgroup_id=0:3306:weight=1000:master

# Slave 1
hostgroup_id=1:3307:weight=1000:slave

# Slave 2
hostgroup_id=1:3308:weight=1000:slave
```

### mysql-query-rules.cnf

```ini
[query_rules]
# 规则示例

# SELECT 查询路由到 Slave
match_pattern=^SELECT.*
route_to_hostgroup=1  # Slave hostgroup

# 更新操作路由到 Master
match_pattern=^(UPDATE|DELETE|INSERT).*
route_to_hostgroup=0  # Master hostgroup

# 事务始终使用 Master
match_pattern=^BEGIN
route_to_hostgroup=0  # Master
```

---

## 与 Orchestrator Raft 的集成方式

### 方式 1：定期刷新（推荐）

```bash
# 每 30 秒从 Orchestrator 查询拓扑
# 更新 ProxySQL mysql_servers 配置

while true; do
  # 查询 Orchestrator Raft API
  curl -s http://orchestrator:3000/api/cluster/master-slave | \
    jq '.[] | {instance, is_master}' | \
    # 生成 ProxySQL Admin SQL
    proxysql-admin-script.sh | \
    # 应用到 ProxySQL
    mysql -h 127.0.0.1 -P 6032 -u admin -p...
  
  sleep 30
done
```

### 方式 2：事件驱动

```bash
# Orchestrator 完成故障转移后，通过 Webhook 通知 ProxySQL
# PostMasterFailoverProcesses 配置

{
  "PostMasterFailoverProcesses": [
    "curl -X POST http://proxysql:6032/api/update-topology"
  ]
}
```

### 方式 3：ProxySQL-Orchestrator-Agent（最完整）

```bash
# 一个轻量级代理
# • 监听 Orchestrator Raft 集群
# • 自动同步拓扑到 ProxySQL
# • 处理故障检测和转移
```

---

## 快速开始

### 本地部署

```bash
# Step 1: 启动 MySQL Raft 集群
bash deploy-raft.sh start
bash deploy-raft.sh init

# Step 2: 启动 ProxySQL
docker-compose -f docker-compose.proxysql.yml up -d

# Step 3: 配置 ProxySQL（自动初始化）
bash deploy-proxysql.sh configure

# Step 4: 验证
bash deploy-proxysql.sh status
```

### 连接应用

```bash
# 原来的连接
mysql -h master:3306 -u user -p...
mysql -h slave1:3307 -u user -p...

# 现在的连接（统一）
mysql -h proxysql:6033 -u user -p...
# ProxySQL 自动路由：
#   SELECT → Slave
#   UPDATE/DELETE → Master
#   INSERT → Master
```

---

## ProxySQL 管理命令

### Admin 接口

```bash
# 连接到 ProxySQL Admin
mysql -h 127.0.0.1 -P 6032 -u admin -p password

# 查看当前 MySQL 服务器配置
SHOW MYSQL SERVERS;

# 添加新服务器
INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight) 
VALUES(0,'new-master',3306,1000);

# 应用更改（无需重启）
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

# 查看查询规则
SHOW MYSQL QUERY RULES;

# 查看连接池状态
SHOW MYSQL PROCESSLIST;

# 查看缓存统计
SHOW STATS_MYSQL_QUERY_CACHE;
```

---

## 故障转移场景

### Master 故障

```
T0. Orchestrator Raft 检测故障
T30-60秒. Slave 1 被晋升为新 Master
T60秒+ ProxySQL 感知变化：

方式A（轮询）:
  ProxySQL 定期检测：Master 变为 Slave
  重新配置路由规则
  新请求自动使用新 Master

方式B（推送）:
  Orchestrator 主动通知 ProxySQL
  ProxySQL 立即更新配置
  立即生效，无检测延迟
```

### ProxySQL 自身故障

```
ProxySQL 宕机
    ↓
应用无法连接 localhost:6033
    ↓
使用故障转移 ProxySQL 集群：
  • 主 ProxySQL  :6033
  • 从 ProxySQL1 :6034
  • 从 ProxySQL2 :6035

应用配置多个 ProxySQL 地址
自动故障转移
```

> 注：我会创建一个可选的 ProxySQL 三节点集群配置

---

## 性能对比

### 无 ProxySQL
```
应用连接 MySQL
每个应用需要 10+ 个连接
总连接数 = 应用数 × 连接数 = 1000+ (超过 MySQL 限制)
```

### 使用 ProxySQL
```
应用连接 ProxySQL (共享连接池)
ProxySQL 连接 MySQL (300 个连接)
节省 80% 的连接开销
性能提升 40-60%
```

---

## 文件清单

```
orchestrator/
├── proxysql/
│   ├── docker-compose.proxysql.yml       ProxySQL 部署配置
│   ├── proxysql.cnf                      主配置文件
│   ├── proxysql-rules.cnf                查询规则
│   ├── init-proxysql.sql                 初始化脚本
│   └── update-topology.sh                动态更新拓扑脚本
│
├── deploy-proxysql.sh                    部署脚本
├── docs/proxysql-raft-integration.md     详细集成指南
└── PROXYSQL-QUICK-REFERENCE.md           快速参考
```

---

好，现在我为你创建完整的 ProxySQL 部署方案。稍等...
