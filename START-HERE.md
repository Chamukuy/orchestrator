# 🚀 一主两从部署 - 快速启动指南

## 📦 您已获得的完整部署包

已为您创建了 **6 个核心文件**，完整的一主两从 MySQL + Orchestrator 部署解决方案：

```
✅ docker-compose.master-slave.yml          - Docker Compose 配置
✅ conf/orchestrator-master-slave.conf.json - Orchestrator 配置
✅ deploy-master-slave.sh                   - 自动化部署脚本
✅ docs/deployment-master-slave.md          - 详细部署文档（500+ 行）
✅ QUICK-REFERENCE-MASTER-SLAVE.md          - 快速参考指南（300+ 行）
✅ DEPLOYMENT-PACKAGE-SUMMARY.md            - 部署包说明
```

## 🎯 3 分钟快速启动

### Step 1: 启动环境（30秒）
```bash
cd /workspaces/orchestrator
bash deploy-master-slave.sh start
```

**输出示例**：
```
[INFO] 启动一主两从 MySQL + Orchestrator 拓扑...
[INFO] 等待服务启动...
[SUCCESS] 环境启动完成！
[INFO] Orchestrator Web 界面: http://localhost:3000
[INFO] Master: localhost:3306
[INFO] Slave 1: localhost:3307
[INFO] Slave 2: localhost:3308
```

### Step 2: 初始化复制（1分钟）
```bash
bash deploy-master-slave.sh init
```

**该命令将**：
- 在 Master 创建复制用户 (`repl_user`)
- 在 Master 创建 Orchestrator 用户 (`orc_client_user`)
- 配置 Slave 1 连接到 Master
- 配置 Slave 2 连接到 Master
- 验证复制状态

**输出示例**：
```
[INFO] 初始化主从复制...
[INFO] 在 Master 上创建复制用户...
[SUCCESS] Master 用户创建完成
[INFO] 配置 Slave 1...
[SUCCESS] Slave 1 配置完成
[INFO] 配置 Slave 2...
[SUCCESS] Slave 2 配置完成
[INFO] 验证复制状态...
=== Slave 1 复制状态 ===
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0

=== Slave 2 复制状态 ===
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
```

### Step 3: 验证并查看拓扑（30秒）

**方式 A：使用脚本查看状态**
```bash
bash deploy-master-slave.sh status
```

**方式 B：打开 Web 界面**
```bash
# Linux 用户
xdg-open http://localhost:3000

# macOS 用户
open http://localhost:3000

# 或在浏览器中打开
http://localhost:3000
```

**方式 C：查询 API**
```bash
curl -sS http://localhost:3000/api/instances | jq '.[].Key'
```

## 📋 部署检查清单

启动后，验证以下项：

```bash
# ✅ 检查 1: 所有容器运行中
docker ps -a

# ✅ 检查 2: Orchestrator 服务可用
curl -sS http://localhost:3000/api/status | jq .

# ✅ 检查 3: Master 正常运行
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot -e "SELECT VERSION();"

# ✅ 检查 4: Slave 1 复制正常
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running"

# ✅ 检查 5: Slave 2 复制正常
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running"

# ✅ 检查 6: Orchestrator 已发现所有实例
curl -sS http://localhost:3000/api/instances | jq 'length'
```

## 🧪 测试数据复制

### 创建测试数据（在 Master）
```bash
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot <<EOF
CREATE DATABASE IF NOT EXISTS test_replication;
USE test_replication;
CREATE TABLE test_table (
  id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(100),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO test_table (name) VALUES ('Test Data 1');
INSERT INTO test_table (name) VALUES ('Test Data 2');
SELECT * FROM test_table;
EOF
```

### 验证 Slave 1 收到数据
```bash
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "
USE test_replication;
SELECT * FROM test_table;
"
```

### 验证 Slave 2 收到数据
```bash
docker compose -f docker-compose.master-slave.yml exec mysql-slave-2 mysql -uroot -proot -e "
USE test_replication;
SELECT * FROM test_table;
"
```

## 🔗 重要链接

| 链接 | 地址 | 说明 |
|-----|------|------|
| **Orchestrator Web** | http://localhost:3000 | 主要管理界面 |
| **Orchestrator API** | http://localhost:3000/api | RESTful API |
| **MySQL Master** | localhost:3306 | 主节点连接 |
| **MySQL Slave 1** | localhost:3307 | 从节点 1 连接 |
| **MySQL Slave 2** | localhost:3308 | 从节点 2 连接 |

## 💾 数据库连接信息

```
Host:     localhost (或 127.0.0.1)
Port:     3306 (Master), 3307 (Slave 1), 3308 (Slave 2)
Username: root
Password: root

数据库管理工具连接示例：
mysql -h localhost -P 3306 -u root -proot
```

## 📚 文档导航

### 🎯 快速参考（5 分钟阅读）
👉 [QUICK-REFERENCE-MASTER-SLAVE.md](QUICK-REFERENCE-MASTER-SLAVE.md)
- 常用命令速查
- 快速验证步骤
- 故障排查

### 📖 详细部署文档（20 分钟阅读）
👉 [docs/deployment-master-slave.md](docs/deployment-master-slave.md)
- 完整架构说明
- 分步部署指南
- 性能优化建议
- 日志查看方法

### 📦 部署包说明（10 分钟阅读）
👉 [DEPLOYMENT-PACKAGE-SUMMARY.md](DEPLOYMENT-PACKAGE-SUMMARY.md)
- 文件清单
- 配置说明
- 修改方法

## ⚙️ 常用命令速查

```bash
# 启动环境
bash deploy-master-slave.sh start

# 停止环境
bash deploy-master-slave.sh stop

# 查看状态
bash deploy-master-slave.sh status

# 查看日志
bash deploy-master-slave.sh logs              # 所有服务
bash deploy-master-slave.sh logs orchestrator # 仅 Orchestrator
bash deploy-master-slave.sh logs mysql-master # 仅 Master

# 初始化复制
bash deploy-master-slave.sh init

# 完全重置环境
bash deploy-master-slave.sh reset

# 获取帮助
bash deploy-master-slave.sh help
```

## 🔧 常见问题

### Q: 如何查看 Slave 的复制状态？
```bash
docker compose -f docker-compose.master-slave.yml exec mysql-slave-1 mysql -uroot -proot -e "SHOW SLAVE STATUS\G"
```
查看 `Slave_IO_Running` 和 `Slave_SQL_Running` 是否都为 `Yes`

### Q: 如何在 Master 上写入数据？
```bash
docker compose -f docker-compose.master-slave.yml exec mysql-master mysql -uroot -proot
# 然后输入 SQL 命令
```

### Q: 如何查看 Orchestrator 发现的实例？
```bash
curl -sS http://localhost:3000/api/instances | jq '.[].Key'
```

### Q: 如何停止并清理环境？
```bash
docker compose -f docker-compose.master-slave.yml down -v
```

### Q: 密码是什么？
- MySQL Root: `root`
- 复制用户密码: `repl_password`
- Orchestrator 用户密码: `orc_client_password`

## 🎓 学习路线

1. **第 1 步**：启动环境
   ```bash
   bash deploy-master-slave.sh start
   bash deploy-master-slave.sh init
   ```

2. **第 2 步**：访问 Web 界面
   ```bash
   open http://localhost:3000
   ```

3. **第 3 步**：进行数据复制测试
   ```bash
   # 在 Master 插入数据
   # 验证 Slave 收到数据
   ```

4. **第 4 步**：阅读详细文档
   - [QUICK-REFERENCE-MASTER-SLAVE.md](QUICK-REFERENCE-MASTER-SLAVE.md)
   - [docs/deployment-master-slave.md](docs/deployment-master-slave.md)

5. **第 5 步**：尝试故障转移
   ```bash
   # 停止 Master 观察 Orchestrator 反应
   docker compose -f docker-compose.master-slave.yml stop mysql-master
   ```

## 🚀 现在就开始！

```bash
cd /workspaces/orchestrator
bash deploy-master-slave.sh start
bash deploy-master-slave.sh init
bash deploy-master-slave.sh status
```

然后打开浏览器访问：**http://localhost:3000**

---

**一切准备就绪！祝您使用愉快！** 🎉

有任何问题或需要帮助，请查看相关文档或 Orchestrator 日志。

## 🧭 分布式部署（多主机）

如果您希望将 Master / Slave1 / Slave2 部署到三台不同主机上，可使用仓库内的分布式脚本 `deploy-distributed.sh`：

1. 在本地运行（将模板与配置推到远端并启动容器）：

```bash
# 示例：部署 Orchestrator 在 Master 主机上
./deploy-distributed.sh <MASTER_IP> <SLAVE1_IP> <SLAVE2_IP> <SSH_USER> --orch-on-master
```

2. 脚本会执行的工作：
- 将 `dist/docker-compose.master.yml` 上传到 Master，`dist/docker-compose.slave.yml` 上传到 Slave 节点
- 在各节点 `~/orchestrator_dist` 启动容器
- 在 Master 上创建复制用户（`repl_user`）与 Orchestrator 用户，并启用复制
- 配置两台 Slave 指向 Master 并启动复制

3. 常用远程运维脚本（位于 `ops/`）：
- `ops/check-replication.sh <SLAVE_IP> <SSH_USER>`：检查远端从库复制状态
- `ops/gather-logs.sh <HOST> <SSH_USER> [outdir]`：拉取远端 Docker Compose 日志到本地目录
- `ops/check-orchestrator.sh <ORCH_HOST>`：检查 Orchestrator 健康接口

注意：脚本使用 `ssh`/`scp` 登录远端，请确保密钥或密码可用且目标主机已安装 Docker 与 Docker Compose。
