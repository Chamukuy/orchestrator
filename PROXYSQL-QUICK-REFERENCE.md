# ProxySQL + Orchestrator Raft 集成 - 快速参考

一主两从 MySQL 集群的完整解决方案：Orchestrator Raft + ProxySQL 中间件

---

## 为什么使用 ProxySQL？

| 功能 | 作用 | 优势 |
|------|------|------|
| **读写分离** | 自动将 SELECT 路由到 Slave，INSERT/UPDATE 到 Master | 提高吞吐量，降低 Master 压力 |
| **连接池** | 所有应用共享连接，减少总连接数 | 性能提升 40-60%，节省内存 |
| **故障自动转移** | 主动探测 MySQL 健康，自动标记故障节点 | 应用无感知，自动降级 |
| **Query 缓存** | 缓存热查询结果 | 毫秒级响应，降低数据库压力 |
| **动态配置** | 无需重启，实时更新路由规则 | 零停机时间更新 |

---

## 🚀 3 分钟快速启动

### Step 1: 启动全栈（3 分钟）

```bash
cd /workspaces/orchestrator

# 启动 MySQL Raft 集群 + Orchestrator
bash deploy-raft.sh start
bash deploy-raft.sh init

# 启动 ProxySQL 中间件
bash deploy-proxysql.sh start

# 配置 ProxySQL
bash deploy-proxysql.sh configure

# 验证
bash deploy-proxysql.sh status
```

### Step 2: 应用连接（单一端口）

```bash
# 之前：需要连接三个不同的 MySQL 实例
mysql -h localhost:3306 -u user -p...  # Master
mysql -h localhost:3307 -u user -p...  # Slave1
mysql -h localhost:3308 -u user -p...  # Slave2

# 现在：只需连接一个 ProxySQL 端口！
mysql -h localhost:6033 -u proxysql_user -p proxysql_pass

# ProxySQL 自动路由：
# ✓ SELECT → Slave (自动负载均衡)
# ✓ INSERT/UPDATE/DELETE → Master
# ✓ BEGIN/COMMIT → Master
```

### Step 3: 验证读写分离

```bash
# 连接 ProxySQL
mysql -h 127.0.0.1 -P 6033 -u proxysql_user -p proxysql_pass

# 执行查询（自动到 Slave）
SELECT * FROM information_schema.tables;

# 执行写操作（自动到 Master）
INSERT INTO test.data VALUES (1, 'test');

# 在 ProxySQL Admin 查看统计
mysql -h 127.0.0.1 -P 6032 -u admin -p admin
SHOW STATS_MYSQL_CONNECTION_POOL \G
```

---

## 📊 完整工作流

```
应用程序
    ↓
  6033 (ProxySQL)
    ↓
┌─────────────────────┐
│ ProxySQL 规则引擎    │
├─────────────────────┤
│ SELECT → Slave      │
│ INSERT/UPDATE → M   │
│ BEGIN → Master      │
└─────────────────────┘
    ↓       ↓       ↓
  3306    3307    3308
  (M)     (S1)    (S2)

同时：

Master 宕机
    ↓
Orchestrator Raft 检测 (30秒)
    ↓
Slave 1 晋升为新 Mas
ter
    ↓
ProxySQL 自动探测
    ↓
新请求自动路由到新 Master

全程自动，应用无感知！
```

---

## ⚡ 常用命令

### 启动/停止

```bash
bash deploy-proxysql.sh start       # 启动
bash deploy-proxysql.sh stop        # 停止
bash deploy-proxysql.sh status      # 查看状态
bash deploy-proxysql.sh configure   # 配置
bash deploy-proxysql.sh test        # 测试连接
```

### ProxySQL Admin 操作

```bash
# 连接到 Admin 接口
mysql -h 127.0.0.1 -P 6032 -u admin -p admin

# 查看后端服务器状态
SHOW MYSQL SERVERS \G

# 查看查询规则
SHOW MYSQL QUERY RULES \G

# 查看连接池统计
SHOW STATS_MYSQL_CONNECTION_POOL \G

# 动态添加新服务器（无需重启）
INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight) 
VALUES(0,'new-master',3306,1000);
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

# 动态更新查询规则
UPDATE mysql_query_rules SET destination_hostgroup=1 WHERE rule_id=2;
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

---

## 🔍 ProxySQL 与 Orchestrator 协作

### 故障场景演示

#### 场景：MySQL Master 宕机

```bash
# 1. 模拟 Master 故障（Docker 停止容器）
docker stop orchestrator-mysql-master-1

# 2. 观察过程
# 第一阶段：ProxySQL 自动探测到故障 (5秒)
# 第二阶段：Orchestrator Raft 开始分析 (30秒)
# 第三阶段：Slave 1 被晋升为新 Master (1分钟)
# 第四阶段：ProxySQL 检测到变化，更新路由 (5-10秒)
# 第五阶段：新请求自动使用新 Master

# 3. 验证新 Master
# 在 ProxySQL Admin
mysql -h 127.0.0.1 -P 6032 -u admin -p admin
SHOW MYSQL SERVERS \G
# 看 mysql-master 的状态是否为 SHUNNED（故障）
# mysql-slave-1 是否变成了写目标

# 4. 或者直接测试
mysql -h 127.0.0.1 -P 6033 -u proxysql_user -p proxysql_pass
INSERT INTO test.data VALUES (999, 'after-failover');
SELECT * FROM test.data WHERE id=999;  # 应该能读到

# 5. 恢复原 Master
docker start orchestrator-mysql-master-1
```

---

## 🎯 关键配置参数

### 连接池参数

```json
{
  "max_connections": 2048,              // 总连接数
  "default_max_connections": 100,       // 每个应用最多连接数
  "connection_max_age_ms": 3600000      // 连接复用最长时间（1小时）
}
```

### 健康检查参数

```json
{
  "ping_interval_server_msec": 5000,    // 每 5 秒检查一次
  "ping_timeout_server": 200            // 超过 200ms 认为故障
}
```

### 查询缓存参数

```json
{
  "query_cache_size_MB": 256,           // 缓存大小
  "query_cache_default_time_ms": 100    // 默认缓存 100ms
}
```

---

## 📈 性能对比

### 无 ProxySQL（直连 MySQL）
```
应用 A: 10 个连接
应用 B: 10 个连接
应用 C: 10 个连接
...
应用 J: 10 个连接
───────────────────
总计: ~100 个连接 (超过 MySQL max_connections 限制 64)

结果：连接失败率高，性能差
```

### 使用 ProxySQL
```
应用 A → ProxySQL(共享连接池 300)
应用 B →     ├─ 连接到 Master (10)
应用 C →     └─ 连接到 Slave  (10)
...
应用 J →

结果：所有应用共享 300 个连接，性能提升 40-60%
```

---

## 🔐 安全配置

### 修改默认密码

编辑 `docker-compose.proxysql.yml` 和 `proxysql/proxysql.cnf`，修改：

```bash
# Admin 密码
admin_password='your_secure_admin_pass'

# 应用用户密码
{
  username='proxysql_user'
  password='your_secure_app_pass'
  ...
}
```

### 限制访问 IP

```bash
# proxysql.cnf
admin_listen_ip='192.168.1.100'  # 只监听特定 IP
interfaces='192.168.1.100:6033'  # 只监听特定 IP
```

---

## 🆘 故障排查

### ProxySQL 无法连接

```bash
# 检查容器状态
docker logs orchestrator-proxysql

# 检查 Admin 连接
mysql -h 127.0.0.1 -P 6032 -u admin -p admin

# 检查 MySQL 客户端连接
mysql -h 127.0.0.1 -P 6033 -u proxysql_user -p proxysql_pass
```

### 查询不走 Slave

```bash
# ProxySQL Admin
mysql -h 127.0.0.1 -P 6032 -u admin -p admin

# 检查 Slave 是否在线
SHOW MYSQL SERVERS \G

# 检查规则是否匹配
SHOW MYSQL QUERY RULES \G

# 测试查询
SHOW STATS_MYSQL_QUERY_DIGEST LIMIT 10 \G
# 看 hostgroup 是不是 1 (Slave)
```

### 故障转移没有发生

```bash
# 检查 Orchestrator Raft 状态
curl http://localhost:3000/api/leader-check

# 检查 Orchestrator 拓扑
curl http://localhost:3000/api/cluster/master-slave | jq .

# 检查 ProxySQL 是否检测到变化
docker logs orchestrator-proxysql | grep -i "master\|slave"
```

---

## 📚 完整文档

- [PROXYSQL-INTEGRATION-PLAN.md](PROXYSQL-INTEGRATION-PLAN.md) - 架构详解
- [proxysql/proxysql.cnf](proxysql/proxysql.cnf) - 配置参考
- [deploy-proxysql.sh](deploy-proxysql.sh) - 部署脚本

---

## 🎓 推荐阅读顺序

1. **本文件** (5 分钟) - 快速了解
2. **PROXYSQL-INTEGRATION-PLAN.md** (15 分钟) - 深入理解架构
3. **deploy-proxysql.sh** (10 分钟) - 了解部署流程
4. **proxysql/proxysql.cnf** (15 分钟) - 理解配置细节

---

## ✨ 关键优势总结

✅ **单一连接点** - 应用只需连一个端口  
✅ **自动读写分离** - 无需应用改动  
✅ **连接池** - 性能提升 40-60%  
✅ **自动故障转移** - 无人工干预  
✅ **零停机更新** - 动态配置生效  
✅ **Query 缓存** - 热查询毫秒级响应  

---

**版本**: 1.0  
**更新**: 2026-02-05
