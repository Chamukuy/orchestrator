# Orchestrator Raft 集群部署指南

一主两从 MySQL 集群 + Orchestrator Raft 高可用部署方案

## 目录

- [架构概述](#架构概述)
- [前置条件](#前置条件)
- [本地部署](#本地部署)
- [分布式部署](#分布式部署)
- [集群管理](#集群管理)
- [故障恢复](#故障恢复)
- [常见问题](#常见问题)

---

## 架构概述

### 拓扑结构

```
┌─────────────────────────────────────────────┐
│      Orchestrator Raft 集群（HA）           │
├──────────────┬──────────────┬───────────────┤
│ Master节点   │  Slave1节点  │  Slave2节点   │
│ Orch-1       │  Orch-2      │  Orch-3       │
│              │              │               │
│ :3000        │  :3001       │  :3002        │
│ Raft:10008   │ Raft:10009   │ Raft:10010    │
└──────────────┼──────────────┼───────────────┘
       ↓              ↓              ↓
┌──────────────┬──────────────┬───────────────┐
│   MySQL      │   MySQL      │   MySQL       │
│   Master     │   Slave1     │   Slave2      │
│   :3306      │   :3307      │   :3308       │
└──────────────┴──────────────┴───────────────┘
```

### 核心特性

- ✅ **高可用性**: 通过 Raft 共识协议保证三个节点中任意一个故障仍可用
- ✅ **数据一致性**: Raft 共识保证所有节点共享相同的链接拓扑信息
- ✅ **网络分区隔离**: Quorum 保证只有多数派节点才能进行决策
- ✅ **数据库管理灵活**: 支持 SQLite（嵌入式）或 MySQL 后端
- ✅ **独立发现**: 三个节点独立探测 MySQL 拓扑，但共享决策

---

## 前置条件

### 本地部署

- Docker 19.03+
- Docker Compose 1.29+
- 至少 6GB 可用内存（每个容器约 ~1.5GB）
- 足够的磁盘空间（数据卷）

### 分布式部署

**本地机器**
- Bash 4.0+
- `jq` 工具（JSON 处理）
- SSH 客户端
- 可访问目标主机

**目标主机（Master 和两个 Slave）**
- Docker 19.03+
- Docker Compose 1.29+
- 至少 2GB 可用内存
- SSH 服务开启（允许密钥或密码登录）
- 3306、3000、10008 端口未被占用

### 网络要求

| 端口 | 协议 | 说明 |
|------|------|------|
| 3306 | TCP | MySQL 拓扑服务 |
| 3000 | HTTP | Orchestrator Web API |
| 10008 | TCP | Raft 集群通讯 |

---

## 本地部署

### 快速开始（3 步）

#### Step 1: 启动集群

```bash
cd /workspaces/orchestrator
chmod +x deploy-raft.sh
./deploy-raft.sh start
```

**输出示例**：
```
[INFO] 启动一主两从 MySQL + Orchestrator Raft 集群...
[SUCCESS] Raft 集群启动完成！

📊 Orchestrator Raft 节点 Web 界面
  Node 1 (Leader): http://localhost:3000
  Node 2:          http://localhost:3001
  Node 3:          http://localhost:3002

🗄️  MySQL 拓扑
  Master: localhost:3306
  Slave 1: localhost:3307
  Slave 2: localhost:3308
```

#### Step 2: 初始化主从复制

```bash
./deploy-raft.sh init
```

该命令将：
- 在 Master 创建复制用户 (`repl_user`)
- 在 Master 创建 Orchestrator 用户 (`orc_client_user`)
- 在两个 Slave 上配置复制连接
- 创建心跳表（用于延迟检测）
- 验证复制状态

**输出示例**：
```
[INFO] 初始化主从复制...
[SUCCESS] 复制用户创建完成
[SUCCESS] 主从复制初始化完成！

Slave 1 复制状态:
Slave_IO_State                    : Waiting for source to send event
Slave_IO_Running                  : Yes
Slave_SQL_Running                 : Yes
Seconds_Behind_Master             : NULL
```

#### Step 3: 验证集群状态

```bash
./deploy-raft.sh status
```

**输出示例**：
```
容器状态：
NAME                    STATUS
orchestrator-mysql-master-1   Up
orchestrator-mysql-slave-1-1  Up
orchestrator-mysql-slave-2-1  Up
orchestrator-orchestrator-1-1 Up (healthy)
orchestrator-orchestrator-2-1 Up (healthy)
orchestrator-orchestrator-3-1 Up (healthy)

Orchestrator Raft 集群状态
[SUCCESS] Node 1 运行正常
[SUCCESS] Node 1 是 Leader
[SUCCESS] Node 1 Raft 健康
[INFO] Node 2 是 Follower
[SUCCESS] Node 2 Raft 健康
[INFO] Node 3 是 Follower
[SUCCESS] Node 3 Raft 健康
```

### 完整命令集

```bash
./deploy-raft.sh start      # 启动集群
./deploy-raft.sh stop       # 停止集群
./deploy-raft.sh status     # 查看状态
./deploy-raft.sh init       # 初始化复制
./deploy-raft.sh logs       # 查看所有日志
./deploy-raft.sh logs orchestrator-1  # 查看特定服务日志
./deploy-raft.sh reset      # 完全重置（删除所有数据）
./deploy-raft.sh help       # 显示帮助
```

### 本地部署配置调整

编辑 `docker-compose.raft.yml` 调整：
- 端口映射
- 环境变量
- 资源限制

编辑 `conf/orchestrator-raft.conf.json` 调整：
- 发现种子服务器
- 故障检测参数
- 恢复策略

---

## 分布式部署

### 前置准备

#### 1. 配置 SSH 密钥（推荐）

```bash
# 本地生成密钥（如果没有）
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa

# 复制公钥到三个目标主机
ssh-copy-id -i ~/.ssh/id_rsa.pub user@192.168.1.10  # Master
ssh-copy-id -i ~/.ssh/id_rsa.pub user@192.168.1.11  # Slave1
ssh-copy-id -i ~/.ssh/id_rsa.pub user@192.168.1.12  # Slave2

# 验证连接
ssh user@192.168.1.10 echo "SSH 连接成功"
```

#### 2. 检查目标主机

```bash
# 在每个目标主机上执行
ssh user@192.168.1.10 "docker --version && docker compose --version"
```

### 部署步骤

#### 方案 A：使用 SQLite 后端（推荐）

```bash
cd /workspaces/orchestrator
chmod +x deploy-raft-distributed.sh

./deploy-raft-distributed.sh \
  192.168.1.10 \
  192.168.1.11 \
  192.168.1.12 \
  ubuntu
```

#### 方案 B：使用 MySQL 后端

```bash
./deploy-raft-distributed.sh \
  192.168.1.10 \
  192.168.1.11 \
  192.168.1.12 \
  ubuntu \
  --backend-db mysql
```

#### 方案 C：使用主机名代替 IP

```bash
./deploy-raft-distributed.sh \
  master.example.com \
  slave1.example.com \
  slave2.example.com \
  ubuntu \
  --backend-db sqlite
```

### 部署流程详解

部分脚本执行分为 7 个步骤：

| 步骤 | 名称 | 说明 |
|-----|------|------|
| 1 | 环境检查 | 验证 SSH 连接、Docker 可用性 |
| 2 | 目录准备 | 在各主机创建 `~/orchestrator_raft_dist` |
| 3 | 配置生成 | 为每个节点生成个性化 Raft 配置 |
| 4 | 文件上传 | 上传 Docker Compose 和配置文件 |
| 5 | 容器启动 | 在各主机启动 Docker 容器 |
| 6 | 复制初始化 | 配置 Master→Slave1/Slave2 复制 |
| 7 | 部署验证 | 验证 Raft 集群和复制状态 |

### 配置 HAProxy 反向代理（可选但推荐）

为了只让客户端连接到 Leader 节点，可以配置 HAProxy：

```bash
# 在代理主机上安装 HAProxy
sudo apt-get install haproxy

# 编辑 /etc/haproxy/haproxy.cfg
cat >> /etc/haproxy/haproxy.cfg << 'EOF'
listen orchestrator
  bind  0.0.0.0:3000
  mode tcp
  option httpchk GET /api/leader-check
  balance first
  retries 1
  timeout connect 1000
  timeout check 300
  timeout server 30s
  
  # 使用默认HTTP服务器设置
  default-server port 3000 fall 1 inter 1000 rise 1
  
  server orch-node1 192.168.1.10:3000 check
  server orch-node2 192.168.1.11:3000 check
  server orch-node3 192.168.1.12:3000 check
EOF

# 启动 HAProxy
sudo systemctl restart haproxy
```

然后客户端连接到：`http://proxy-host:3000/api`

---

## 集群管理

### 监控集群状态

#### 查看 Leader 节点

```bash
# 方式1：直接 HTTP 请求
curl -s http://localhost:3000/api/leader-check
# 返回 200 OK 表示该节点是 Leader

# 方式2：检查 Raft 健康
curl -s http://localhost:3000/api/raft-health | jq .
# 返回 200 和健康状态
```

#### 查看 Raft 集群成员

```bash
curl -s http://localhost:3000/api/raft/nodes | jq .
```

#### 查看拓扑信息

```bash
curl -s http://localhost:3000/api/cluster/master-slave | jq .
```

### 使用 orchest-client 命令行工具

安装脚本（可选）：
```bash
# 下载 orchestrator-client
wget https://github.com/openark/orchestrator/releases/download/v3.2.6/orchestrator-client

chmod +x orchestrator-client

# 配置环境变量
export ORCHESTRATOR_API="http://localhost:3000/api"

# 或分布式部署
export ORCHESTRATOR_API="\
  http://192.168.1.10:3000/api \
  http://192.168.1.11:3000/api \
  http://192.168.1.12:3000/api"

# 使用示例
./orchestrator-client -c status       # 查看集群状态
./orchestrator-client -c discover-seeds  # 发现新服务器
```

### 日志查看

#### 本地部署

```bash
# 查看所有服务日志
./deploy-raft.sh logs

# 查看特定服务
./deploy-raft.sh logs orchestrator-1
./deploy-raft.sh logs mysql-master
```

#### 分布式部署

```bash
# 远程查看日志
ssh user@192.168.1.10 "cd ~/orchestrator_raft_dist && docker compose logs -f orchestrator"
```

---

## 故障恢复

### 场景 1：单个 Orchestrator 节点故障

**症状**：一个节点无法访问或 Raft 不健康

**恢复步骤**：

```bash
# 1. 查看故障节点日志
./deploy-raft.sh logs orchestrator-2

# 2. 重启故障节点
docker-compose -f docker-compose.raft.yml restart orchestrator-2

# 3. 验证恢复
./deploy-raft.sh status
```

**预期结果**：该节点会重新加入 Raft group，自动同步状态

### 场景 2：多个 Orchestrator 节点故障

**症状**：Raft 无法形成仲裁（超过 3 个节点中 2 个故障）

**恢复步骤**：

```bash
# 1. 修复故障的节点（修复硬件、重启 Docker 等）

# 2. 逐个仅启动节点
docker-compose -f docker-compose.raft.yml up -d orchestrator-1

# 3. 监控日志，查看 Raft leader 选举
tail -f docker-compose.raft.log

# 4. 重启其他节点
docker-compose -f docker-compose.raft.yml up -d orchestrator-2
docker-compose -f docker-compose.raft.yml up -d orchestrator-3

# 5. 验证
./deploy-raft.sh status
```

### 场景 3：Master MySQL 故障

**症状**：无法连接 Master，Slave 复制停止

**Raft 的行为**：
- 三个 Orchestrator 节点继续运行
- Leader 会尝试自动故障转移（如果启用）
- 监视页面会显示拓扑异常

**手动恢复**：

```bash
# 1. 检查 Master 故障原因
ssh user@master-host "docker logs mysql-master"

# 2. 修复 Master 或声明新 Master
# 登录 Orchestrator Web 界面 > Topology > 选择新 Master

# 3. 重新配置 Slaves
curl -X POST http://localhost:3000/api/recover/master-slave/master:3306
```

### 场景 4：Raft 数据损坏

**症状**：Raft 无法启动，反复崩溃

**恢复步骤**（有数据丢失风险）：

```bash
# 1. 停止所有 Orchestrator 容器
./deploy-raft.sh stop

# 2. 删除损坏的 Raft 数据（仅限必要）
docker volume rm orchestrator-1-data orchestrator-2-data orchestrator-3-data

# 3. 重启集群（不推荐，会丢失拓扑历史）
./deploy-raft.sh start
./deploy-raft.sh init
```

---

## 常见问题

### Q1: Raft 收不到消息，节点标记为不健康

**原因**：通常是网络分区或防火墙阻止

**解决方案**：
```bash
# 检查网络连接
ping 192.168.1.11
ping 192.168.1.12

# 检查 Raft 端口是否打开
netstat -tlnp | grep 10008
ss -tlnp | grep 10008

# 测试 Raft 通讯
telnet 192.168.1.11 10008
```

### Q2: 如何更改 Raft 配置而不停止服务？

**方案**：
1. 编辑 `orchestrator.conf.json`
2. 重启单个 Follower 节点（不是 Leader）
3. 重启 Leader 节点
4. 验证所有节点

```bash
# 更新配置（所有节点相同）
docker cp ./orchestrator.conf.json \
  $(docker ps -q -f "label=com.docker.compose.service=orchestrator-2"):/etc/orchestrator/

# 重启 Follower 节点（逐个）
docker-compose restart orchestrator-2
docker-compose restart orchestrator-3
docker-compose restart orchestrator-1  # Leader 最后重启
```

### Q3: SQLite vs MySQL 后端，如何选择？

| 特性 | SQLite | MySQL |
|------|--------|-------|
| 安装 | 无需额外安装，内置 | 需要独立 MySQL |
| 性能 | 5,000+ 服务器 | 10,000+ 服务器 |
| 可靠性 | 本地文件，易备份 | 可配置复制 HA |
| 扩展性 | 受限于单机 I/O | 可水平扩展 |
| 推荐场景 | 中小型（<5000 服务器） | 大规模（>5000 服务器） |

**对于一主两从场景，推荐使用 SQLite**

### Q4: 如何备份 Orchestrator 状态？

```bash
# 备份 SQLite 数据库
docker exec $(docker ps -q -f "label=com.docker.compose.service=orchestrator-1") \
  cp /var/lib/orchestrator/orchestrator.db /backup/orchestrator-$(date +%Y%m%d).db

# 备份配置文件
cp ./conf/orchestrator-raft.conf.json ./backup/

# 完整文件备份（包含 Raft 状态）
docker cp \
  $(docker ps -q -f "label=com.docker.compose.service=orchestrator-1"):/var/lib/orchestrator \
  ./backup/orchestrator-fullbackup-$(date +%Y%m%d)
```

### Q5: 如何升级 Orchestrator 版本？

```bash
# 1. 更新镜像
docker pull openark/orchestrator:v3.2.7

# 2. 重启 Orchestrator（逐个）
docker-compose -f docker-compose.raft.yml up -d --pull always orchestrator-1

# 3. 验证
curl -s http://localhost:3000/api/status | jq '..Version'

# 对其他节点重复步骤 2-3
```

### Q6: 如何完全卸载 Raft 集群？

```bash
# 停止并删除所有容器和卷
./deploy-raft.sh reset

# 或手动清理
docker-compose -f docker-compose.raft.yml down -v

# 删除临时配置文件
rm -f .orchestrator-raft-*.conf.json
```

---

## 性能优化建议

### 1. 调整发现周期

```json
{
  "InstancePollSeconds": 10  // 增加此值以降低负载（默认 5）
}
```

### 2. 为分布式部署调整复制滞后阈值

```json
{
  "ReasonableMaintenanceReplicationLagSeconds": 60,  // 增加容限
  "FailMasterPromotionOnLagMinutes": 2  // 延迟故障检测时间
}
```

### 3. 优化 Raft 参数（高级）

```json
{
  "RaftElectionTimeout": "1000ms",    // 选举超时
  "RaftHeartbeatTimeout": "100ms",    // 心跳超时
  "RaftSnapshotThreshold": 100000      // 快照阈值
}
```

---

## 参考资源

- [Orchestrator 官方文档](https://github.com/openark/orchestrator/wiki)
- [Raft 共识算法](https://raft.github.io/)
- [MySQL 主从复制](https://dev.mysql.com/doc/refman/8.0/en/replication.html)
- [GTID 复制](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids.html)

---

**最后更新**: 2026-02-05  
**维护者**: Orchestrator Community
