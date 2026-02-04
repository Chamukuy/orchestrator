# 一主两从 MySQL 部署指南

## 概述

本文档说明如何使用 Orchestrator 和 Docker Compose 快速部署一个**一主两从**的 MySQL 复制拓扑。

拓扑结构如下：
```
           Master (mysql-master:3306)
              /        \
             /          \
      Slave 1          Slave 2
   (mysql-slave-1:    (mysql-slave-2:
    3307)              3308)
```

## 部署架构

| 服务名称 | 端口 | Server ID | 角色 | 说明 |
|---------|------|-----------|------|------|
| mysql-master | 3306 | 1 | Master | 主节点，接收写入 |
| mysql-slave-1 | 3307 | 2 | Slave | 从节点 1，只读副本 |
| mysql-slave-2 | 3308 | 3 | Slave | 从节点 2，只读副本 |
| orchestrator | 3000 | - | 管理工具 | MySQL 拓扑管理与故障转移 |

## 前置条件

- Docker 和 Docker Compose（版本 3.8+）
- 至少 2GB 可用内存
- 以下端口未被占用：3306, 3307, 3308, 3000

## 快速开始

### 1. 启动复制拓扑

```bash
cd /workspaces/orchestrator

# 使用一主两从配置启动
docker compose -f docker-compose.master-slave.yml up -d --build
```

此命令将启动：
- **MySQL Master** (mysql-master:3306)
- **MySQL Slave 1** (mysql-slave-1:3307)
- **MySQL Slave 2** (mysql-slave-2:3308)
- **Orchestrator** 管理界面 (http://localhost:3000)

### 2. 验证服务健康状态

```bash
# 查看所有运行的容器
docker ps -a

# 查看 Orchestrator 日志（等待启动完成）
docker compose -f docker-compose.master-slave.yml logs orchestrator

# 验证 Orchestrator API 可用
curl -sS http://localhost:3000/api/status | jq .
```

### 3. 配置主从复制

进入 Master 容器并创建复制用户：

```bash
# 进入 Master 容器
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
-- 创建复制用户
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'repl_password';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
GRANT REPLICATION CLIENT ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;

-- 创建 Orchestrator 监控用户
CREATE USER IF NOT EXISTS 'orc_client_user'@'%' IDENTIFIED BY 'orc_client_password';
GRANT SELECT, PROCESS, REPLICATION CLIENT, REPLICATION SLAVE, SUPER ON *.* TO 'orc_client_user'@'%';
FLUSH PRIVILEGES;

-- 查看二进制日志位置
SHOW MASTER STATUS;
"
```

### 4. 配置从节点（Slave 1）

```bash
# 从 Master 获取二进制日志信息
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "SHOW MASTER STATUS\G"
```

记下 `File` 和 `Position`，然后配置从节点：

```bash
# 配置 Slave 1
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
CHANGE MASTER TO
  MASTER_HOST='mysql-master',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password',
  MASTER_PORT=3306,
  MASTER_AUTO_POSITION=1,
  GET_MASTER_PUBLIC_KEY=1;

START SLAVE;

-- 查看从节点状态
SHOW SLAVE STATUS\G
"
```

### 5. 配置从节点（Slave 2）

```bash
# 配置 Slave 2
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "
CHANGE MASTER TO
  MASTER_HOST='mysql-master',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password',
  MASTER_PORT=3306,
  MASTER_AUTO_POSITION=1,
  GET_MASTER_PUBLIC_KEY=1;

START SLAVE;

-- 查看从节点状态
SHOW SLAVE STATUS\G
"
```

## 验证复制拓扑

### 检查复制状态

```bash
# 检查 Slave 1 复制状态
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
SHOW SLAVE STATUS\G
" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"

# 检查 Slave 2 复制状态
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "
SHOW SLAVE STATUS\G
" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"
```

### 在 Master 上写入数据

```bash
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
-- 创建测试数据库
CREATE DATABASE IF NOT EXISTS test_db;
USE test_db;

-- 创建测试表
CREATE TABLE IF NOT EXISTS users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(100),
  email VARCHAR(100),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 插入测试数据
INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');
INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com');

-- 查看数据
SELECT * FROM users;
"
```

### 在从节点上验证数据

```bash
# 验证 Slave 1
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
USE test_db;
SELECT * FROM users;
"

# 验证 Slave 2
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "
USE test_db;
SELECT * FROM users;
"
```

## 使用 Orchestrator 管理拓扑

### Web 界面

访问 Orchestrator Web 界面：

```bash
# 打开浏览器访问
open http://localhost:3000

# 或通过命令行访问
curl -sS http://localhost:3000/api/status | jq .
```

### API 查询

```bash
# 列出所有发现的实例
curl -sS http://localhost:3000/api/instances | jq '.[] | {key: .Key, role: .Role}'

# 查看特定拓扑
curl -sS http://localhost:3000/api/topology/mysql-master/3306 | jq .

# 查看集群信息
curl -sS http://localhost:3000/api/clusters | jq .
```

### 发现拓扑

进入 Orchestrator 容器发现拓扑：

```bash
# 进入容器
docker compose -f docker-compose.master-slave.yml exec orchestrator /bin/bash

# 发现主节点
cd /usr/local/orchestrator
export ORCHESTRATOR_API='http://127.0.0.1:3000/api'
./orchestrator-client -c discover -instance mysql-master:3306

# 查看拓扑（以表格形式）
./orchestrator-client -c topology-tabulated -alias "master-slave cluster"

# 查看拓扑树结构
./orchestrator-client -c topology -alias "master-slave cluster"
```

## 故障转移测试

### 模拟 Master 故障

```bash
# 停止 Master 容器
docker compose -f docker-compose.master-slave.yml stop mysql-master

# 查看 Orchestrator 是否检测到故障
curl -sS http://localhost:3000/api/problems | jq .

# 获取故障转移建议
curl -sS http://localhost:3000/api/recovery/master-slave/3306 | jq .
```

### 恢复 Master

```bash
# 启动 Master 容器
docker compose -f docker-compose.master-slave.yml start mysql-master

# 验证集群恢复
curl -sS http://localhost:3000/api/topology/mysql-master/3306 | jq .
```

## 性能监控

### 查看复制延迟

```bash
# 在主节点上
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
SHOW PROCESSLIST\G
"

# 在从节点上
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
SHOW SLAVE STATUS\G | grep Seconds_Behind_Master
"
```

### 监控二进制日志

```bash
# 查看 Master 二进制日志
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
SHOW BINARY LOGS;
"

# 查看 Slave 中继日志
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
SHOW SLAVE STATUS\G | grep -i 'relay'
"
```

## 日志检查

### Orchestrator 日志

```bash
# 查看 Orchestrator 日志
docker compose -f docker-compose.master-slave.yml logs orchestrator

# 实时查看日志
docker compose -f docker-compose.master-slave.yml logs -f orchestrator
```

### MySQL 错误日志

```bash
# 查看 Master 错误日志
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
SHOW VARIABLES LIKE 'log_error';
"

# 查看 Slave 复制错误
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
SHOW SLAVE STATUS\G | grep -i error
"
```

## 关闭环境

```bash
# 停止所有容器
docker compose -f docker-compose.master-slave.yml down

# 停止并删除所有数据
docker compose -f docker-compose.master-slave.yml down -v

# 完全清理（包括镜像）
docker compose -f docker-compose.master-slave.yml down -v --remove-orphans --rmi all
```

## 常见问题

### 1. 从节点无法连接到主节点

**症状**：`Slave_IO_Running = No`

**解决方案**：
```bash
# 检查网络连接
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 \
  mysqladmin -h mysql-master -u repl_user -p'repl_password' ping

# 检查防火墙和网络配置
docker network inspect orchestrator_mysql-replication
```

### 2. 二进制日志不同步

**症状**：复制延迟很大

**解决方案**：
```bash
# 检查 Master 二进制日志是否启用
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
SHOW VARIABLES LIKE 'log_bin';
"

# 检查 slave_parallel_workers 配置以加速复制
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
SHOW VARIABLES LIKE 'slave_parallel_workers';
"
```

### 3. Orchestrator 无法发现实例

**症状**：API 返回空列表

**解决方案**：
```bash
# 检查 Orchestrator 数据库连接
docker compose -f docker-compose.master-slave.yml logs orchestrator | grep -i "error"

# 手动触发发现
curl -X POST "http://localhost:3000/api/discover/mysql-master/3306"

# 验证用户权限
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
SELECT user, host FROM mysql.user WHERE user = 'orc_client_user';
"
```

## 扩展阅读

- [Orchestrator 官方文档](https://openark.github.io/orchestrator/)
- [MySQL 复制文档](https://dev.mysql.com/doc/refman/8.0/en/replication.html)
- [GTID 复制](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids.html)
- [Orchestrator API](https://openark.github.io/orchestrator/api-orchestrator-web-api/)

## 分布式部署（多主机）

当您希望将 Master、Slave1、Slave2 部署到三台不同主机时，仓库中提供了一个自动化脚本 `deploy-distributed.sh` 和远端 `docker-compose` 模板（位于 `dist/`），可用于将模板上传到远端并在每台主机上启动容器。

前提条件（各远端主机）：
- 已安装 Docker 与 Docker Compose
- 本地机器可以通过 `ssh`/`scp` 访问目标主机（密钥或密码可用）
- 目标主机具备至少 2GB 内存和足够磁盘空间

示例部署流程（在本地机器上执行）：

```bash
# 在仓库根目录运行（示例，将 Orchestrator 部署在 master）
./deploy-distributed.sh <MASTER_IP> <SLAVE1_IP> <SLAVE2_IP> <SSH_USER> --orch-on-master
```

脚本执行要点：
- 在每台主机创建目录 `~/orchestrator_dist` 并上传相应的 `docker-compose.yml`（master 使用 `dist/docker-compose.master.yml`，slave 使用 `dist/docker-compose.slave.yml`）
- 在 master 上上传并（可选）启动 `orchestrator.conf.json`
- 在三台主机上执行 `docker compose up -d --build` 启动 MySQL 容器
- 脚本会在 master 上创建复制用户 `repl_user`（密码 `repl_password`）以及 Orchestrator 用户并创建 `orchestrator` 数据库
- 自动在两台 slave 上执行 `CHANGE MASTER TO ... MASTER_AUTO_POSITION=1` 并 `START SLAVE`（使用 master 的公网/私有 IP）

运维与故障排查脚本（位于仓库的 `ops/` 目录）：
- `ops/check-replication.sh <SLAVE_IP> <SSH_USER>` — 通过 SSH 在远端执行 `SHOW SLAVE STATUS\G` 并打印重要字段
- `ops/gather-logs.sh <HOST> <SSH_USER> [outdir]` — 拉取远端 `docker compose logs` 到本地 `outdir`
- `ops/check-orchestrator.sh <ORCH_HOST>` — 检查 Orchestrator 的 `/api/status` 接口

安全与网络注意事项：
- 若跨公网上传输，请使用 SSH 密钥并关闭密码登录，或通过跳板机/VPN 传输文件
- 确保 Master 对 Slave 的 3306 端口畅通（私有网络或安全组规则）
- 若使用私钥，无密码交互可通过 `ssh-agent` 或 `~/.ssh/config` 的 `IdentityFile` 配置

若需更深度定制（例如为每台从库设置不同 `server-id`、调整 `my.cnf` 参数或挂载外部存储），请编辑 `dist/docker-compose.slave.yml` / `dist/docker-compose.master.yml`，并在 `deploy-distributed.sh` 中添加相应的替换逻辑。

## 支持

如有问题，请查看 Orchestrator 日志或联系相关管理员。
