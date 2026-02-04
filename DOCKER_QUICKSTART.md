# Orchestrator Docker 快速启动指南

## 项目概述

[Orchestrator](https://github.com/openark/orchestrator) 是用于 MySQL 拓扑管理与故障转移的高可用工具。本文档说明如何用 Docker Compose 快速启动测试环境。

## 快速开始

### 1. 启动 Docker Compose 环境

```bash
cd /workspaces/orchestrator
docker compose up -d --build
```

此命令将启动：
- **MySQL 8.0.44** 数据库（Orchestrator 后端）
- **Orchestrator 服务**（监听 `http://localhost:3000`）

### 2. 验证服务状态

```bash
# 查看运行中的容器
docker ps

# 验证 Orchestrator 健康状态
curl -sS http://localhost:3000/api/status | jq .
```

## 使用 Orchestrator

### 方式 1：Web 界面

直接访问 Orchestrator Web 界面：

```bash
open http://localhost:3000
# 或使用浏览器访问
```

### 方式 2：Orchestrator API

#### 查看已发现的实例

```bash
# 列出所有集群
curl -sS http://localhost:3000/api/clusters | jq .

# 查看特定拓扑状态
curl -sS http://localhost:3000/api/topology/alias/test | jq .
```

#### 发现 MySQL 实例

使用容器内的 `orchestrator-client` 发现 MySQL：

```bash
# 进入 orchestrator 容器
docker exec -it orchestrator-orchestrator-1 /bin/bash

# 在容器内执行（需要设置 ORCHESTRATOR_API）
cd /usr/local/orchestrator
export ORCHESTRATOR_API='http://127.0.0.1:3000/api'

# 发现实例
./orchestrator-client -c discover -instance mysql:3306

# 查看拓扑
./orchestrator-client -c topology-tabulated -alias test
```

或使用 HTTP API 直接调用：

```bash
# 发现实例（使用容器名作为主机名）
curl -X POST "http://localhost:3000/api/discover/mysql/3306"

# 查看实例详情
curl -sS "http://localhost:3000/api/instance/mysql/3306" | jq .
```

### 方式 3：CLI 工具

在容器内使用 `orchestrator-client` 命令行工具：

```bash
docker exec -it orchestrator-orchestrator-1 /bin/bash

# 设置 API 地址
export ORCHESTRATOR_API='http://127.0.0.1:3000/api'

# 常用命令
orchestrator-client -c clusters-alias           # 列出集群别名
orchestrator-client -c topology-tabulated -alias test  # 查看特定集群拓扑
orchestrator-client -c api -path /status        # 查看服务状态
```

## 配置说明

### Docker Compose 配置

文件：`docker-compose.yml`

**主要参数：**
- MySQL 镜像：`mysql:8.0.44`
- Orchestrator 监听端口：`3000`
- 后端数据库：SQLite（`/usr/local/orchestrator/orchestrator.sqlite3`）
- Orchestrator 拓扑发现用户：`orc_client_user`（密码：`orc_client_password`）

### MySQL 初始化

文件：`docker/mysql-init/01-orchestrator-user.sql`

初始化脚本创建以下用户：
- `orc_server_user`：Orchestrator 后端数据库用户
- `orc_client_user`：MySQL 拓扑发现用户（需要 REPLICATION CLIENT 权限）

## 容器管理

### 查看日志

```bash
# 查看 Orchestrator 日志
docker logs -f orchestrator-orchestrator-1

# 查看 MySQL 日志
docker logs -f orchestrator-mysql-1
```

### 停止服务

```bash
# 保留卷数据
docker compose down

# 完全清理（包括卷）
docker compose down -v
```

### 重启服务

```bash
docker compose restart
```

## 常见问题

### 1. Orchestrator 无法连接 MySQL

**原因：** 容器网络隔离或认证失败。

**解决：**
- 确保 MySQL 容器状态为 `(healthy)`
- 验证用户权限：`docker exec orchestrator-mysql-1 mysql -uorc_client_user -porc_client_password -e "SELECT 1"`
- 检查配置文件：`docker exec orchestrator-orchestrator-1 cat /etc/orchestrator.conf.json`

### 2. Web 界面显示"No clusters"

**原因：** 还未发现任何 MySQL 实例。

**解决：**
- 通过 API 或 CLI 手动发现实例（见上面的"方式 2"和"方式 3"）
- 或配置自动发现（修改 `orchestrator-sample-sqlite.conf.json` 中的 `DiscoveryIgnoreReplicaHostnameFilters` 等配置）

### 3. curl 请求返回 404

**原因：** API 路径不正确。

**解决：**
- 确认 Orchestrator 已启动：`curl http://localhost:3000/api/status`
- API 格式为 `/api/COMMAND/PARAM1/PARAM2`，例如：`/api/instance/mysql/3306`

## 扩展配置

若要使用外部 MySQL 作为 Orchestrator 后端（而非 SQLite），修改 `docker-compose.yml`：

```yaml
orchestrator:
  environment:
    ORC_DB_HOST: your-mysql-host
    ORC_DB_PORT: 3306
    ORC_DB_NAME: orchestrator
    ORC_USER: orc_server_user
    ORC_PASSWORD: orc_server_password
```

## 参考链接

- [官方文档](https://github.com/openark/orchestrator/tree/master/docs)
- [API 文档](https://github.com/openark/orchestrator/blob/master/docs/using-the-web-api.md)
- [CLI 工具](https://github.com/openark/orchestrator/blob/master/docs/orchestrator-client.md)
