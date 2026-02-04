# 一主两从部署包 - 文件清单

## 📋 概述

已为您创建了一套完整的**一主两从 MySQL + Orchestrator** 部署解决方案，包括配置文件、部署脚本和详细文档。

## 📁 创建的文件清单

### 1. **Docker Compose 配置**
- **文件**: [`docker-compose.master-slave.yml`](./docker-compose.master-slave.yml)
- **说明**: 完整的一主两从拓扑定义
- **内容**:
  - MySQL Master（server-id=1，端口 3306）
  - MySQL Slave 1（server-id=2，端口 3307）
  - MySQL Slave 2（server-id=3，端口 3308）
  - Orchestrator 管理服务（端口 3000）
- **特性**:
  - 启用 GTID 复制模式
  - 启用 ROW 格式二进制日志
  - 健康检查配置
  - 持久化存储卷

### 2. **Orchestrator 配置**
- **文件**: [`conf/orchestrator-master-slave.conf.json`](./conf/orchestrator-master-slave.conf.json)
- **说明**: Orchestrator 服务的配置文件
- **关键配置**:
  - 后端数据库：mysql-master:3306
  - 拓扑监控用户：orc_client_user
  - GTID 模式启用
  - 自动拓扑发现

### 3. **部署脚本**
- **文件**: [`deploy-master-slave.sh`](./deploy-master-slave.sh)
- **说明**: 自动化部署和管理脚本
- **功能**:
  ```bash
  start    # 启动环境
  stop     # 停止环境
  status   # 查看状态
  logs     # 查看日志
  init     # 初始化复制
  reset    # 重置环境
  ```
- **特性**: 彩色输出、错误检查、交互式确认

### 4. **详细部署文档**
- **文件**: [`docs/deployment-master-slave.md`](./docs/deployment-master-slave.md)
- **说明**: 完整的部署指南（约 500 行）
- **包含内容**:
  - 系统架构和拓扑图
  - 前置条件和环境检查
  - 分步部署指南
  - 复制配置步骤
  - 验证方法
  - Orchestrator 管理
  - 故障转移测试
  - 性能监控
  - 常见问题解决
  - 日志检查方法

### 5. **快速参考指南**
- **文件**: [`QUICK-REFERENCE-MASTER-SLAVE.md`](./QUICK-REFERENCE-MASTER-SLAVE.md)
- **说明**: 快速查阅文档（约 300 行）
- **内容**:
  - 3 步快速开始
  - 常用命令速查表
  - 访问方式汇总
  - 验证命令示例
  - Orchestrator API 示例
  - 故障排查快速指南
  - 配置修改方法

## 🚀 快速开始（3 步）

### Step 1: 启动环境
```bash
cd /workspaces/orchestrator
bash deploy-master-slave.sh start
```

### Step 2: 初始化复制
```bash
bash deploy-master-slave.sh init
```

### Step 3: 验证拓扑
```bash
bash deploy-master-slave.sh status

# 或访问 Web 界面
open http://localhost:3000
```

## 📊 部署架构

```
┌─────────────────────────────────────────────────────┐
│                  Docker Network                      │
│              (mysql-replication)                    │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │                   Master                      │  │
│  │  mysql-master:3306 (server-id=1)              │  │
│  │  - Binary Log: Enabled                        │  │
│  │  - GTID Mode: ON                              │  │
│  │  - Port: 3306                                 │  │
│  └──────────────┬───────────────────────────────┘  │
│                 │                                    │
│         ┌───────┴────────┐                          │
│         │                │                          │
│  ┌──────▼────────┐  ┌────▼────────┐               │
│  │    Slave 1    │  │   Slave 2   │               │
│  │ mysql-slave-1 │  │mysql-slave-2│               │
│  │:3307 (id=2)   │  │:3308 (id=3) │               │
│  │ Relay Log: ON │  │Relay Log: ON│               │
│  └───────────────┘  └─────────────┘               │
│                                                     │
│  ┌─────────────────────────────────────────────┐  │
│  │           Orchestrator (Port 3000)          │  │
│  │  - Web UI: http://localhost:3000            │  │
│  │  - API: http://localhost:3000/api           │  │
│  │  - Backend: mysql-master:3306               │  │
│  └─────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## 🔌 端口映射

| 服务 | 容器端口 | 宿主机端口 | 用途 |
|-----|---------|----------|------|
| Master | 3306 | 3306 | MySQL 主节点 |
| Slave 1 | 3306 | 3307 | MySQL 从节点 1 |
| Slave 2 | 3306 | 3308 | MySQL 从节点 2 |
| Orchestrator | 3000 | 3000 | 管理界面 |

## 🔐 默认凭据

| 用途 | 用户名 | 密码 | 作用域 |
|-----|-------|------|--------|
| MySQL Root | root | root | 本地和网络 |
| 复制用户 | repl_user | repl_password | 复制专用 |
| Orchestrator 客户端 | orc_client_user | orc_client_password | 拓扑监控 |
| Orchestrator 服务器 | orc_server_user | orc_server_password | 后端存储 |

## 📖 文档导航

1. **快速开始** → [QUICK-REFERENCE-MASTER-SLAVE.md](./QUICK-REFERENCE-MASTER-SLAVE.md)
   - 3 步快速启动
   - 常用命令
   - 快速验证

2. **详细指南** → [docs/deployment-master-slave.md](./docs/deployment-master-slave.md)
   - 完整部署流程
   - 配置详解
   - 故障排查
   - 性能优化

3. **自动化脚本** → [deploy-master-slave.sh](./deploy-master-slave.sh)
   - 自动启停
   - 状态查询
   - 日志查看
   - 复制初始化

## ✅ 验证清单

部署成功后，请检查以下项目：

- [ ] 三个 MySQL 容器正在运行（Master、Slave 1、Slave 2）
- [ ] Orchestrator 容器正在运行
- [ ] Master 复制用户已创建
- [ ] Slave 1 连接到 Master 并正在同步
- [ ] Slave 2 连接到 Master 并正在同步
- [ ] Orchestrator Web 界面可访问 (http://localhost:3000)
- [ ] Orchestrator 已发现所有三个实例
- [ ] 测试数据从 Master 成功复制到两个 Slave

## 🔧 常见操作

### 查看复制状态
```bash
# 查看 Slave 1 状态
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "SHOW SLAVE STATUS\G"

# 查看 Slave 2 状态
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "SHOW SLAVE STATUS\G"
```

### 在 Master 创建测试表
```bash
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "
CREATE DATABASE IF NOT EXISTS test;
CREATE TABLE IF NOT EXISTS test.t1 (id INT PRIMARY KEY AUTO_INCREMENT, data VARCHAR(100));
INSERT INTO test.t1 (data) VALUES ('test data');
SELECT * FROM test.t1;
"
```

### 在 Slave 验证数据
```bash
# Slave 1
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "SELECT * FROM test.t1;"

# Slave 2
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "SELECT * FROM test.t1;"
```

### 查看 Orchestrator 拓扑
```bash
# Web 界面
open http://localhost:3000

# API 查询
curl -sS http://localhost:3000/api/topology/mysql-master/3306 | jq .
```

## 📚 学习资源

- [Orchestrator 官方文档](https://openark.github.io/orchestrator/)
- [MySQL 复制指南](https://dev.mysql.com/doc/refman/8.0/en/replication.html)
- [GTID 复制详解](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids.html)
- [Docker 官方文档](https://docs.docker.com/)

## 🐛 问题排查

### 容器启动失败
```bash
# 查看详细日志
docker compose -f docker-compose.master-slave.yml logs mysql-master

# 重新启动
docker compose -f docker-compose.master-slave.yml restart
```

### 复制不同步
```bash
# 检查从节点状态
bash deploy-master-slave.sh logs mysql-slave-1

# 验证网络连接
docker network inspect orchestrator_mysql-replication
```

### Orchestrator 无法发现实例
```bash
# 重启 Orchestrator
docker compose -f docker-compose.master-slave.yml restart orchestrator

# 查看日志
bash deploy-master-slave.sh logs orchestrator
```

## 📝 修改配置

### 更改 MySQL 密码
1. 编辑 `docker-compose.master-slave.yml`
2. 修改 `MYSQL_ROOT_PASSWORD` 环境变量
3. 重新启动环境

### 更改监听端口
1. 编辑 `docker-compose.master-slave.yml`
2. 修改 `ports` 部分
3. 重新启动环境

### 更改 MySQL 版本
1. 编辑 `docker-compose.master-slave.yml`
2. 修改 `image: mysql:X.Y.Z`
3. 重新构建

## 🎯 下一步操作

1. **立即启动**: 
   ```bash
   bash deploy-master-slave.sh start
   bash deploy-master-slave.sh init
   ```

2. **验证拓扑**:
   ```bash
   bash deploy-master-slave.sh status
   ```

3. **浏览 Orchestrator**:
   ```bash
   open http://localhost:3000
   ```

4. **阅读详细文档**:
   - [QUICK-REFERENCE-MASTER-SLAVE.md](./QUICK-REFERENCE-MASTER-SLAVE.md)
   - [docs/deployment-master-slave.md](./docs/deployment-master-slave.md)

---

**祝您使用愉快！** 如有任何问题，请参考文档或查看 Orchestrator 日志。
