# 分布式部署详细指南

## 概述

本指南说明如何使用 `deploy-distributed.sh` 脚本在三台不同主机上部署一主两从的 MySQL 复制拓扑。

脚本包含以下特性：
- ✅ 严格的参数验证与 IP 地址检查
- ✅ SSH 连接性测试
- ✅ Docker/Docker Compose 环境检查
- ✅ 详细的日志记录（带时间戳）
- ✅ 分阶段部署与错误恢复
- ✅ 复制状态验证

## 前置条件

### 本地机器
- 已安装 Bash 4.0+
- 已安装 `jq` 工具（用于处理 JSON 配置）
- 可以通过 `ssh`/`scp` 访问目标主机（推荐使用公钥认证）

### 目标主机（Master 和两个 Slave）
- 已安装 Docker (19.03+)
- 已安装 Docker Compose (1.29+)
- 至少 2GB 可用内存
- SSH 服务开启，允许密钥或密码登录
- 3306 端口未被占用

## 快速开始

### 1. 检查前置条件

```bash
# 本地机器
jq --version  # 应该显示版本号
ssh -V        # 应该显示 SSH 版本
```

### 2. 准备 SSH 密钥（可选但推荐）

使用公钥认证可以避免输入密码：

```bash
# 生成密钥对（如果还没有）
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa

# 复制公钥到目标主机（示例）
ssh-copy-id -i ~/.ssh/id_rsa.pub user@192.168.1.10
ssh-copy-id -i ~/.ssh/id_rsa.pub user@192.168.1.11
ssh-copy-id -i ~/.ssh/id_rsa.pub user@192.168.1.12
```

### 3. 运行部署脚本

#### 基本用法

```bash
cd /workspaces/orchestrator

# 部署 Master、Slave1、Slave2，但不在 Master 上部署 Orchestrator
./deploy-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu

# 或，部署时在 Master 上同时启动 Orchestrator 容器
./deploy-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu --orch-on-master
```

#### 使用主机名而非 IP

```bash
./deploy-distributed.sh master.example.com slave1.example.com slave2.example.com ubuntu --orch-on-master
```

#### 自定义日志输出位置

```bash
LOG_FILE=/var/log/deploy_orchestrator.log ./deploy-distributed.sh 192.168.1.10 192.168.1.11 192.168.1.12 ubuntu
```

## 脚本执行流程

脚本执行分为 9 个步骤：

| 步骤 | 名称 | 说明 |
|-----|------|------|
| 1 | 环境检查与连接测试 | 验证 IP 格式、测试 SSH 连接、检查 Docker 可用性 |
| 2 | 创建远端工作目录 | 在各主机创建 `~/orchestrator_dist` |
| 3 | 上传 Docker Compose 配置 | 上传 `docker-compose.master.yml` 和 `docker-compose.slave.yml` |
| 4 | 上传 Orchestrator 配置 | 上传并修改 Orchestrator 配置文件 |
| 5 | 启动 Docker 容器 | 在各主机执行 `docker compose up -d --build` |
| 6 | 创建复制用户 | 在 Master 上创建 `repl_user` 和 Orchestrator 用户 |
| 7 | 配置 Slave 1 | 配置 Slave 1 指向 Master 并启动复制 |
| 8 | 配置 Slave 2 | 配置 Slave 2 指向 Master 并启动复制 |
| 9 | 验证复制状态 | 检查两个 Slave 的复制状态 |

## 输出说明

脚本执行时会在控制台和日志文件中输出详细信息：

```bash
[2026-02-04 10:30:45] [INFO] ==========================================
[2026-02-04 10:30:45] [INFO] 分布式部署脚本启动
[2026-02-04 10:30:45] [INFO] Master IP: 192.168.1.10
[2026-02-04 10:30:45] [INFO] 步骤 1: 环境检查与连接测试
[2026-02-04 10:30:46] [SUCCESS] SSH 连接成功: 192.168.1.10
[2026-02-04 10:30:47] [SUCCESS] Docker 检查通过: 192.168.1.10
[2026-02-04 10:30:47] [INFO] 步骤 2: 创建远端工作目录
[2026-02-04 10:30:48] [SUCCESS] 目录准备完毕: 192.168.1.10
...
[2026-02-04 10:31:05] [SUCCESS] ==========================================
[2026-02-04 10:31:05] [SUCCESS] 分布式部署完成
```

日志文件位置：`_deploy_YYYYMMDD_HHMMSS.log`

## 故障排查

### 问题 1: SSH 连接失败

**症状**：
```
[ERROR] SSH 连接失败: 192.168.1.10
```

**排查步骤**：
```bash
# 1. 检查主机是否可达
ping 192.168.1.10

# 2. 测试 SSH 连接
ssh -v ubuntu@192.168.1.10 "echo test"

# 3. 检查密钥权限
ls -la ~/.ssh/id_rsa
# 权限应为 600

# 4. 检查目标主机 SSH 配置
ssh ubuntu@192.168.1.10 "sudo systemctl status ssh"
```

### 问题 2: Docker 不可用

**症状**：
```
[ERROR] Docker/Docker Compose 不可用或未安装: 192.168.1.10
```

**排查步骤**：
```bash
# 在目标主机上安装 Docker
ssh ubuntu@192.168.1.10 << 'EOF'
sudo apt update
sudo apt install -y docker.io docker-compose
sudo usermod -aG docker $USER
EOF
```

### 问题 3: 文件上传失败

**症状**：
```
[ERROR] 文件上传失败: ~/orchestrator_dist/docker-compose.yml
```

**排查步骤**：
```bash
# 1. 检查目标目录权限
ssh ubuntu@192.168.1.10 "ls -la ~/"

# 2. 手动测试 scp
scp /workspaces/orchestrator/dist/docker-compose.master.yml ubuntu@192.168.1.10:~/test.yml

# 3. 检查磁盘空间
ssh ubuntu@192.168.1.10 "df -h"
```

### 问题 4: MySQL 初始化超时

**症状**：
```
[ERROR] 无法在 192.168.1.10 上创建用户
```

**排查步骤**：
```bash
# 1. 检查 MySQL 容器是否运行
ssh ubuntu@192.168.1.10 "cd ~/orchestrator_dist && docker compose ps"

# 2. 查看 MySQL 日志
ssh ubuntu@192.168.1.10 "cd ~/orchestrator_dist && docker compose logs mysql-master"

# 3. 增加等待时间并重新运行（编辑脚本中的 sleep 时长）
```

### 问题 5: 复制配置失败

**症状**：
```
[ERROR] 无法配置 Slave 1
```

**排查步骤**：
```bash
# 1. 检查从节点是否能连接到主节点
ssh ubuntu@192.168.1.11 "cd ~/orchestrator_dist && docker compose exec -T mysql-slave \
  mysqladmin -h 192.168.1.10 -u repl_user -p'repl_password' ping"

# 2. 查看从节点错误日志
ssh ubuntu@192.168.1.11 "cd ~/orchestrator_dist && docker compose logs mysql-slave"

# 3. 检查防火墙规则
ssh ubuntu@192.168.1.10 "sudo ufw status"
```

## 部署后验证

### 验证 Master

```bash
ssh ubuntu@192.168.1.10 << 'EOF'
cd ~/orchestrator_dist
docker compose ps
docker compose exec -T mysql-master mysql -uroot -proot -e "SHOW MASTER STATUS\G"
EOF
```

### 验证 Slave

```bash
# Slave 1
./ops/check-replication.sh 192.168.1.11 ubuntu

# Slave 2
./ops/check-replication.sh 192.168.1.12 ubuntu
```

### 测试数据复制

```bash
# 在 Master 上创建测试表
ssh ubuntu@192.168.1.10 << 'EOF'
cd ~/orchestrator_dist
docker compose exec -T mysql-master mysql -uroot -proot << 'SQL'
CREATE DATABASE test_repl;
CREATE TABLE test_repl.t1 (id INT PRIMARY KEY AUTO_INCREMENT, data VARCHAR(100));
INSERT INTO test_repl.t1 (data) VALUES ('test data');
SELECT * FROM test_repl.t1;
SQL
EOF

# 在 Slave 1 上验证
ssh ubuntu@192.168.1.11 << 'EOF'
cd ~/orchestrator_dist
docker compose exec -T mysql-slave mysql -uroot -proot -e "SELECT * FROM test_repl.t1;"
EOF
```

## 收集日志进行故障排查

使用 `ops/gather-logs.sh` 收集远端日志：

```bash
# 从各主机收集日志
./ops/gather-logs.sh 192.168.1.10 ubuntu ./logs
./ops/gather-logs.sh 192.168.1.11 ubuntu ./logs
./ops/gather-logs.sh 192.168.1.12 ubuntu ./logs

# 查看日志
cat ./logs/192.168.1.10-logs.txt
cat ./logs/192.168.1.11-logs.txt
cat ./logs/192.168.1.12-logs.txt
```

## 网络和安全考虑

### 跨公网部署

若需跨公网部署，强烈建议：

1. **使用 VPN 或跳板机**
   ```bash
   # 通过跳板机访问
   ssh -J bastion@jump.example.com ubuntu@internal-master.local
   ```

2. **使用公钥认证，禁用密码登录**
   ```bash
   # 在目标主机上
   ssh ubuntu@target
   sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
   sudo systemctl restart ssh
   ```

3. **限制 MySQL 端口访问**
   ```bash
   # 仅允许 Slave 连接到 Master 的 3306 端口
   sudo ufw allow from 192.168.1.11 to any port 3306
   sudo ufw allow from 192.168.1.12 to any port 3306
   ```

### IP 白名单

确保各主机间网络畅通：

```bash
# Master 需要允许 Slave 的 3306 端口连接
ssh ubuntu@192.168.1.10 "sudo ufw allow from 192.168.1.11,192.168.1.12 to any port 3306"

# Slave 需要允许来自 Master 的连接（可选，用于备份或监控）
ssh ubuntu@192.168.1.11 "sudo ufw allow from 192.168.1.10 to any port 3306"
```

## 清理和卸载

### 停止所有容器

```bash
for host in 192.168.1.10 192.168.1.11 192.168.1.12; do
  ssh ubuntu@$host "cd ~/orchestrator_dist && docker compose down"
done
```

### 删除所有数据

```bash
for host in 192.168.1.10 192.168.1.11 192.168.1.12; do
  ssh ubuntu@$host "cd ~/orchestrator_dist && docker compose down -v"
done
```

### 删除工作目录

```bash
for host in 192.168.1.10 192.168.1.11 192.168.1.12; do
  ssh ubuntu@$host "rm -rf ~/orchestrator_dist"
done
```

## 常见问题解答

### Q: 能否使用密码认证而非公钥？

A: 可以，但需要交互式输入密码。建议设置 `ssh-agent` 来保存密钥密码。

### Q: 若部署中途失败怎么办？

A: 查看日志文件（`_deploy_*.log`）找出失败点，修复问题后可以重新运行脚本。脚本会跳过已完成的步骤（使用幂等操作）。

### Q: 能否修改 MySQL 版本或密码？

A: 可以。编辑 `dist/docker-compose.master.yml` 和 `dist/docker-compose.slave.yml` 中的 `image` 和 `environment` 字段，然后重新运行脚本。

### Q: Orchestrator 应该部署在哪里？

A: 建议部署在 Master 主机上（使用 `--orch-on-master` 选项），也可以在独立的监控主机上，需修改配置后手动部署。

### Q: 如何在部署后添加更多 Slave？

A: 在新的 Slave 主机上手动部署 `docker-compose.slave.yml`，然后配置 `CHANGE MASTER TO` 指向 Master 即可。参考 `deploy-distributed.sh` 中的配置步骤。

## 支持和反馈

若遇到问题，请：
1. 查看日志文件 `_deploy_*.log`
2. 运行 `ops/gather-logs.sh` 收集各主机日志
3. 检查本文档的"故障排查"部分
4. 查看 Docker Compose 官方文档和 Orchestrator 官方文档
