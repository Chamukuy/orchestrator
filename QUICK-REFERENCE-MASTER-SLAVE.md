# 一主两从部署快速参考

## 目录结构

```
/workspaces/orchestrator/
├── docker-compose.master-slave.yml      # 一主两从 Docker Compose 配置
├── conf/
│   └── orchestrator-master-slave.conf.json  # Orchestrator 配置文件
├── docs/
│   └── deployment-master-slave.md       # 详细部署文档
├── deploy-master-slave.sh               # 自动化部署脚本
└── QUICK-REFERENCE.md                   # 本文件
```

## 快速开始（3 步）

### 1. 启动环境

```bash
cd /workspaces/orchestrator

# 方式 A：使用脚本（推荐）
bash deploy-master-slave.sh start

# 方式 B：直接用 Docker Compose
docker compose -f docker-compose.master-slave.yml up -d --build
```

### 2. 初始化复制

```bash
# 使用脚本（推荐）
bash deploy-master-slave.sh init

# 或手动配置（见详细文档）
```

### 3. 验证拓扑

```bash
# 方式 A：检查复制状态
bash deploy-master-slave.sh status

# 方式 B：查看 Orchestrator Web 界面
open http://localhost:3000

# 方式 C：API 查询
curl -sS http://localhost:3000/api/instances | jq .
```

## 分布式部署（多主机）

如果需要将 Master / Slave 分别部署在三台不同主机上，可以使用仓库内的 `deploy-distributed.sh`：

```bash
# 在本地运行，将模板与配置推送到远端并启动容器
./deploy-distributed.sh <MASTER_IP> <SLAVE1_IP> <SLAVE2_IP> <SSH_USER> [--orch-on-master]
```

脚本会在远端创建 `~/orchestrator_dist`，上传相应的 `docker-compose` 模板并启动容器，然后在 Master 上创建复制与 Orchestrator 用户、配置并启动从库。

远端运维脚本（`ops/`）：
- `ops/check-replication.sh <SLAVE_IP> <SSH_USER>`：检查从库复制状态
- `ops/gather-logs.sh <HOST> <SSH_USER> [outdir]`：收集远端日志到本地
- `ops/check-orchestrator.sh <ORCH_HOST>`：检查 Orchestrator 健康接口

注意：需保证目标主机已安装 Docker / Docker Compose，并且本地能够通过 `ssh`/`scp` 访问目标主机。

## 常用命令速查表

| 操作 | 命令 |
|-----|------|
| **启动环境** | `bash deploy-master-slave.sh start` |
| **停止环境** | `bash deploy-master-slave.sh stop` |
| **查看状态** | `bash deploy-master-slave.sh status` |
| **查看日志** | `bash deploy-master-slave.sh logs` |
| **初始化复制** | `bash deploy-master-slave.sh init` |
| **重置环境** | `bash deploy-master-slave.sh reset` |
| **进入 Master** | `docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot` |
| **进入 Slave 1** | `docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot` |
| **进入 Slave 2** | `docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot` |

## 访问方式

| 服务 | 地址 | 用户名 | 密码 |
|-----|------|--------|------|
| **Orchestrator Web** | http://localhost:3000 | - | - |
| **Master MySQL** | localhost:3306 | root | root |
| **Slave 1 MySQL** | localhost:3307 | root | root |
| **Slave 2 MySQL** | localhost:3308 | root | root |
| **复制用户** | 任意主机 | repl_user | repl_password |

## 验证命令

### 检查 Slave 复制状态

```bash
# Slave 1
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "SHOW SLAVE STATUS\G"

# Slave 2
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "SHOW SLAVE STATUS\G"
```

关键指标：
- `Slave_IO_Running: Yes` ✓
- `Slave_SQL_Running: Yes` ✓
- `Seconds_Behind_Master: 0` ✓

### 测试数据复制

```bash
# 在 Master 上插入数据
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
CREATE DATABASE IF NOT EXISTS test_db;
USE test_db;
CREATE TABLE IF NOT EXISTS test_table (id INT PRIMARY KEY AUTO_INCREMENT, data VARCHAR(100));
INSERT INTO test_table (data) VALUES ('Hello from Master');
SELECT * FROM test_table;
"

# 验证 Slave 1 接收到数据
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
USE test_db;
SELECT * FROM test_table;
"

# 验证 Slave 2 接收到数据
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "
USE test_db;
SELECT * FROM test_table;
"
```

## Orchestrator API 示例

```bash
# 查看所有实例
curl -sS http://localhost:3000/api/instances | jq '.[].Key'

# 查看主从拓扑
curl -sS http://localhost:3000/api/topology/mysql-master/3306 | jq .

# 查看故障信息
curl -sS http://localhost:3000/api/problems | jq .

# 发现新实例
curl -X POST "http://localhost:3000/api/discover/mysql-master/3306"

# 查看恢复候选项
curl -sS http://localhost:3000/api/recovery/master/mysql-master/3306 | jq .
```

## 故障排查

### 问题：从节点无法连接到主节点

```bash
# 1. 检查网络连接
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 \
  mysqladmin -h mysql-master -u repl_user -p'repl_password' ping

# 2. 检查防火墙
docker network inspect orchestrator_mysql-replication

# 3. 查看错误日志
docker compose -f docker-compose.master-slave.yml logs mysql-slave-1
```

### 问题：复制延迟很大

```bash
# 1. 检查从节点状态
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "SHOW SLAVE STATUS\G"

# 2. 检查 Master 是否有大事务
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "SHOW PROCESSLIST\G"

# 3. 检查从节点执行线程数
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "SHOW VARIABLES LIKE 'slave_parallel_workers'"
```

### 问题：Orchestrator 无法发现实例

```bash
# 1. 检查 Orchestrator 日志
docker compose -f docker-compose.master-slave.yml logs orchestrator | tail -20

# 2. 验证用户权限
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "SHOW GRANTS FOR 'orc_client_user'@'%'"

# 3. 手动发现实例
curl -X POST "http://localhost:3000/api/discover/mysql-master/3306"
```

## 配置文件位置

| 文件 | 说明 |
|-----|------|
| [docker-compose.master-slave.yml](../docker-compose.master-slave.yml) | Docker Compose 配置 |
| [conf/orchestrator-master-slave.conf.json](../conf/orchestrator-master-slave.conf.json) | Orchestrator 配置 |
| [docs/deployment-master-slave.md](./deployment-master-slave.md) | 详细部署文档 |
| [deploy-master-slave.sh](../deploy-master-slave.sh) | 自动化脚本 |

## 修改配置

### 修改监听端口

编辑 `docker-compose.master-slave.yml`，修改 `ports` 部分：

```yaml
services:
  mysql-master:
    ports:
      - "3306:3306"  # 改为其他端口，如 "3310:3306"
```

### 修改密码

编辑配置文件和脚本中的密码常量：
- Master 密码：`MYSQL_ROOT_PASSWORD`
- 复制用户密码：`repl_password`
- Orchestrator 密码：`orc_client_password`

### 修改容器镜像版本

编辑 `docker-compose.master-slave.yml`：

```yaml
mysql-master:
  image: mysql:8.0.44  # 改为其他版本，如 mysql:5.7
```

## 完全清理

```bash
# 仅停止容器
bash deploy-master-slave.sh stop

# 停止并删除数据
docker compose -f docker-compose.master-slave.yml down -v

# 完全清理（包括镜像）
docker compose -f docker-compose.master-slave.yml down -v --remove-orphans --rmi all
```

## 性能优化建议

1. **提高并行复制** - 修改 `slave_parallel_workers`
2. **启用 Semi-Sync 复制** - 配置 `rpl_semi_sync_master_enabled`
3. **监控复制延迟** - 使用 Orchestrator Web 界面
4. **调整缓冲池大小** - 修改 `innodb_buffer_pool_size`

详见详细文档：[deployment-master-slave.md](./deployment-master-slave.md)

## 获取帮助

```bash
# 查看脚本帮助
bash deploy-master-slave.sh help

# 查看完整文档
cat docs/deployment-master-slave.md

# 查看 Orchestrator 日志
bash deploy-master-slave.sh logs orchestrator
```

## 下一步

- 阅读 [详细部署文档](./deployment-master-slave.md)
- 访问 [Orchestrator 官方文档](https://openark.github.io/orchestrator/)
- 了解 [MySQL 复制最佳实践](https://dev.mysql.com/doc/refman/8.0/en/replication.html)
