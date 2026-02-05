# 🚀 Orchestrator Raft 部署 - 快速参考指南

一主两从 MySQL 集群 + Orchestrator Raft 快速参考手册

---

## 📋 完整部署包内容

```
✅ docker-compose.raft.yml           - 本地3节点Raft设置
✅ conf/orchestrator-raft.conf.json  - Raft配置模板
✅ deploy-raft.sh                    - 本地部署脚本
✅ deploy-raft-distributed.sh        - 分布式部署脚本
✅ dist/docker-compose.raft-*.yml    - 分布式部署模板
✅ docs/deployment-raft-master-slave.md  - 详细部署文档
✅ RAFT-QUICK-REFERENCE.md           - 本快速参考（本文件）
```

---

## 🎯 3 分钟快速启动

### 本地部署（推荐先试）

```bash
cd /workspaces/orchestrator

# Step 1: 启动集群（30秒）
bash deploy-raft.sh start

# Step 2: 初始化复制（1分钟）
bash deploy-raft.sh init

# Step 3: 检查状态（10秒）
bash deploy-raft.sh status
```

**访问地址**：
- Orchestrator Node 1: `http://localhost:3000`
- Orchestrator Node 2: `http://localhost:3001`
- Orchestrator Node 3: `http://localhost:3002`

---

## 🖥️ 分布式部署（三台主机）

### 前置条件检查

```bash
# 确保三台主机都已安装 Docker
ssh user@192.168.1.10 "docker --version && docker compose --version"
ssh user@192.168.1.11 "docker --version && docker compose --version"
ssh user@192.168.1.12 "docker --version && docker compose --version"
```

### 一键部署

```bash
cd /workspaces/orchestrator

# 方案 A：SQLite 后端（推荐）
bash deploy-raft-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu

# 方案 B：MySQL 后端
bash deploy-raft-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu --backend-db mysql

# 使用主机名
bash deploy-raft-distributed.sh master.local slave1.local slave2.local ubuntu
```

---

## 📊 核心命令速查

### 本地控制

```bash
./deploy-raft.sh start        # 🚀 启动集群
./deploy-raft.sh status       # 📊 查看状态
./deploy-raft.sh init         # ⚙️  初始化复制
./deploy-raft.sh logs         # 📝 查看日志
./deploy-raft.sh stop         # ⏹️  停止集群
./deploy-raft.sh reset        # 🔄 完全重置（删除数据）
```

### 集群状态检查

```bash
# 查看 Leader
curl http://localhost:3000/api/leader-check

# 查看 Raft 健康状态
curl http://localhost:3000/api/raft-health | jq .

# 查看 MySQL 拓扑
curl http://localhost:3000/api/cluster/master-slave | jq .

# 查看 Raft 节点列表
curl http://localhost:3000/api/raft/nodes | jq .
```

---

## 🏗️ 架构一览

```
┌────────────────────────────────────────────────┐
│        Orchestrator Raft 集群（3节点HA）       │
├──────────────┬──────────────┬─────────────────┤
│ Node 1       │ Node 2       │ Node 3          │
│ (Leader)     │ (Follower)   │ (Follower)      │
│ :3000        │ :3001        │ :3002           │
│Raft:10008    │Raft:10009    │Raft:10010       │
├──────────────┼──────────────┼─────────────────┤
│ Master       │ Slave1       │ Slave2          │
│ :3306        │ :3307        │ :3308           │
│ ID=1         │ ID=2         │ ID=3            │
└──────────────┴──────────────┴─────────────────┘
       ↑              ↑              ↑
       └──────────────────────────────┘
              MySQL 复制流
```

### Raft 共识特性

| 特性 | 说明 |
|------|------|
| **Quorum** | 3 节点中需要 2 个持有最新数据 |
| **Leader 选举** | 若 5s 无心跳，自动选举新 Leader |
| **网络分区** | 少数派节点自动降级，防止脑裂 |
| **自愈能力** | 故障节点重启后自动同步并加入 |

---

## 🔧 常用场景

### 场景 1：监控集群实时状态

```bash
# 实时查看所有日志
./deploy-raft.sh logs

# 查看特定节点日志
docker logs -f orchestrator-orchestrator-1-1

# 检查 Raft Leader
while true; do
  echo "$(date '+%H:%M:%S') - Leader: $(curl -s http://localhost:3000/api/leader-check >/dev/null 2>&1 && echo 'Node1' || echo 'Other')"
  sleep 5
done
```

### 场景 2：测试故障转移

```bash
# 模拟 Node 1（Leader）故障
docker-compose -f docker-compose.raft.yml stop orchestrator-1

# 观察：
# 1. Leader 检测会失败
# 2. Node 2 或 Node 3 会自动成为 Leader
# 3. Web 界面自动重定向到新 Leader

# 验证新 Leader 选举
sleep 5
curl http://localhost:3001/api/leader-check  # 应该返回 200
curl http://localhost:3002/api/leader-check  # 应该返回 200

# 恢复 Node 1
docker-compose -f docker-compose.raft.yml up -d orchestrator-1
```

### 场景 3：执行拓扑操作

```bash
# 使用 Orchestrator 强制故障转移
curl -X POST http://localhost:3000/api/recover/master-slave/master:3306

# 禁止自动故障转移
curl -X POST http://localhost:3000/api/begin-downtime/master:3306/true/Testing

# 恢复故障转移
curl -X POST http://localhost:3000/api/end-downtime/master:3306
```

### 场景 4：升级 Orchestrator 版本

```bash
# 不停止服务，逐个升级节点
docker-compose -f docker-compose.raft.yml up -d --pull always orchestrator-1
sleep 30
docker-compose -f docker-compose.raft.yml up -d --pull always orchestrator-2
sleep 30
docker-compose -f docker-compose.raft.yml up -d --pull always orchestrator-3

# 验证
curl http://localhost:3000/api/status | jq '.Version'
```

---

## ⚠️ 故障快速诊断

| 问题 | 症状 | 检查命令 | 修复方案 |
|------|------|--------|--------|
| **Raft 不健康** | LED 红色，无仲裁 | `curl localhost:3000/api/raft-health` | 重启故障节点，检查网络 |
| **无法访问 Leader** | 全红，无响应 | `curl localhost:3000/api/leader-check` | 检查 Leader 选举，查看日志 |
| **MySQL 离线** | 拓扑灰色 | `curl localhost:3000/api/status` | 检查 MySQL 连接，验证网络 |
| **复制停止** | Slave 复制延迟 ∞ | `SHOW SLAVE STATUS` | 查看 Slave 错误日志 |
| **内存溢出** | 容器异常退出 | `docker logs` | 增加内存限制或调整配置 |

---

## 📈 性能优化建议

### 调整发现间隔（降低 CPU）

编辑 `conf/orchestrator-raft.conf.json`：
```json
{
  "InstancePollSeconds": 10        // 从 5 改为 10（降低 50% 负载）
}
```

### 调整故障检测灵敏度

```json
{
  "FailureDetectionPeriodBlockMinutes": 10,  // 延长阻止期
  "FailMasterPromotionOnLagMinutes": 2       // 延迟故障转移
}
```

### 调整 Raft 参数（网络延迟大时）

```json
{
  "RaftElectionTimeout": "2000ms",   // 增加选举超时
  "RaftHeartbeatTimeout": "200ms"    // 增加心跳超时
}
```

---

## 🔒 安全建议

### 1. 启用 SSL/TLS

```json
{
  "UseSSL": true,
  "SSLCertFile": "/path/to/cert.pem",
  "SSLPrivateKeyFile": "/path/to/key.pem"
}
```

### 2. 修改默认凭证

```bash
# 编辑 orchestrator-raft.conf.json
{
  "MySQLTopologyUser": "orc_user",
  "MySQLTopologyPassword": "secure_password",
  "MySQLBackendUser": "orchestrator",
  "MySQLBackendPassword": "backend_secure_pass"
}
```

### 3. 限制访问 IP

使用防火墙或网络策略限制：
- 3000 (Web API) - 仅允许管理员 IP
- 10008 (Raft) - 仅允许 Raft 节点间通讯

---

## 📚 文件说明

| 文件 | 用途 | 修改频率 |
|-----|------|--------|
| `docker-compose.raft.yml` | 本地容器编排 | 低 |
| `conf/orchestrator-raft.conf.json` | 核心配置 | 中 |
| `deploy-raft.sh` | 本地部署脚本 | 低 |
| `deploy-raft-distributed.sh` | 分布式部署脚本 | 低 |
| `docs/deployment-raft-master-slave.md` | 详细文档 | 低 |

---

## 🆘 获取帮助

### 查看脚本帮助

```bash
./deploy-raft.sh help
./deploy-raft-distributed.sh --help
```

### 查看完整文档

```bash
# 详细部署指南
less docs/deployment-raft-master-slave.md

# Orchestrator 官方文档
https://github.com/openark/orchestrator/wiki

# Raft 共识算法
https://raft.github.io/
```

### 收集诊断信息

```bash
# 打包完整诊断信息
mkdir -p ./diagnostics
docker-compose -f docker-compose.raft.yml ps > ./diagnostics/containers.txt
curl -s http://localhost:3000/api/status | jq . > ./diagnostics/status.json
docker-compose -f docker-compose.raft.yml logs > ./diagnostics/logs.txt
```

---

## 📅 定期维护计划

| 任务 | 频率 | 命令 |
|------|------|------|
| 备份数据库 | 每周 | `docker cp <container>:/var/lib/orchestrator ./backup/` |
| 检查合规性 | 每月 | `./deploy-raft.sh status` |
| 更新镜像 | 每季度 | `docker pull openark/orchestrator:latest` |
| 清理日志 | 每月 | `docker-compose logs --tail 0 orchestrator-1` |

---

**快速链接**：
- 📖 [完整部署指南](docs/deployment-raft-master-slave.md)
- 🔧 [配置参考](conf/orchestrator-raft.conf.json)
- 🐳 [Docker Compose 模板](docker-compose.raft.yml)
- 🚀 [本地部署脚本](deploy-raft.sh)
- 🌐 [分布式部署脚本](deploy-raft-distributed.sh)

**最后更新**: 2026-02-05  
**版本**: 1.0
