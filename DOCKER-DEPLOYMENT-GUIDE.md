# Docker 环境脚本改进部署方案

3 种方式快速启用 Docker 容器内的服务监控

## 🚀 方案选择

| 方案 | 适用场景 | 难度 | 推荐度 |
|------|--------|------|--------|
| **方案 A** | 使用改进的增强版脚本 | ⭐ 极简 | ⭐⭐⭐ 最推荐 |
| **方案 B** | 自己修改脚本添加自动检测 | ⭐⭐ 中等 | ⭐⭐ 可选 |
| **方案 C** | 创建专用 Docker 监控容器 | ⭐⭐⭐ 复杂 | ⭐ 不推荐 |

---

## 🎯 方案 A：使用增强版脚本（推荐）

### 概述

新的 `monitor-raft-docker-enhanced.sh` 脚本：
- ✅ 自动检测运行环境（Docker 或 Host）
- ✅ 智能调整访问方式
- ✅ 完全兼容原脚本的所有参数
- ✅ 零修改现有 docker-compose 配置

### 自动检测逻辑

```bash
if [ -f "/.dockerenv" ] || grep -q "docker" /proc/self/cgroup 2>/dev/null; then
    # 在 Docker 容器内 → 使用容器网络名称
    MYSQL_MASTER_HOST=mysql-master         # ← 关键改变！
    MYSQL_SLAVE1_HOST=mysql-slave-1
    MYSQL_SLAVE2_HOST=mysql-slave-2
    ORCHESTRATOR_API=http://orchestrator-raft-1:3000
else
    # 在 Host 或远端 → 使用本地端口或远端 IP
    MYSQL_MASTER_HOST=127.0.0.1            # ← 默认
    MYSQL_SLAVE1_HOST=127.0.0.1
    MYSQL_SLAVE2_HOST=127.0.0.1
    ORCHESTRATOR_API=http://127.0.0.1:3000
fi
```

### 快速上手

#### Step 1: 替换脚本

```bash
# 备份原脚本（可选）
cp monitor-raft.sh monitor-raft.sh.bak

# 使用增强版
cp monitor-raft-docker-enhanced.sh monitor-raft.sh

# 或者两个都保留（推荐）
chmod +x monitor-raft-docker-enhanced.sh
```

#### Step 2: 测试默认配置

```bash
# 在 Host 上运行（自动检测为 Host 环境）
bash monitor-raft.sh once

# 应该输出：
# 运行环境: HOST
# Orchestrator API: http://127.0.0.1:3000
# MySQL Master: 127.0.0.1:3306
```

#### Step 3: 在 Docker 容器内测试

```bash
# 方式 1: 直接在容器内运行（Docker 自动检测）
docker exec orchestrator-raft-1 bash monitor-raft.sh once

# 应该输出：
# 运行环境: DOCKER_CONTAINER
# Orchestrator API: http://orchestrator-raft-1:3000
# MySQL Master: mysql-master:3306

# 方式 2: 创建临时监控容器
docker run --rm \
  --network mysql-replication \
  -v $(pwd)/monitor-raft.sh:/app/monitor.sh:ro \
  mysql:8.0.44 \
  bash /app/monitor.sh once
```

#### Step 4: 与其他脚本一致性

类似地更新其他脚本：
```bash
# 更新测试脚本（同样添加自动检测）
cp test-failover.sh test-failover.sh.bak

# 更新恢复脚本
cp recover-from-power-failure.sh recover-from-power-failure.sh.bak
```

---

## 🔧 方案 B：自己手动修改脚本

### 修改模板

在脚本的配置部分添加：

```bash
#!/bin/bash

# ... 颜色定义等 ...

# ⭐ 添加自动检测
detect_docker_environment() {
    if [ -f "/.dockerenv" ] || grep -q "docker" /proc/self/cgroup 2>/dev/null; then
        return 0
    fi
    return 1
}

# ⭐ 配置初始化（在原配置之前）
if detect_docker_environment; then
    # Docker 环境
    ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://orchestrator-raft-1:3000}"
    MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-mysql-master}"
    MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"     # ← 关键！容器内是原始端口
    MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-mysql-slave-1}"
    MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3306}"
    MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-mysql-slave-2}"
    MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3306}"
    PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-orchestrator-proxysql}"
else
    # Host / 远端环境
    ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
    MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
    MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
    MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-127.0.0.1}"
    MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3307}"
    MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-127.0.0.1}"
    MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3308}"
    PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-127.0.0.1}"
fi

# ... 其他通用配置 ...
```

### 需要修改的脚本列表

- [ ] `monitor-raft.sh` - 监控脚本
- [ ] `test-failover.sh` - 故障演练脚本
- [ ] `recover-from-power-failure.sh` - 恢复脚本
- [ ] `recovery-hooks.sh` - 恢复钩子（ProxySQL 部分）

---

## 🐳 方案 C：创建专用监控容器

### Docker Compose 配置

在 `docker-compose.raft.yml` 中添加：

```yaml
version: "3.8"

services:
  # ... 现有服务 ...

  # 新增：专用监控容器
  monitor:
    image: ubuntu:22.04
    restart: unless-stopped
    depends_on:
      - mysql-master
      - mysql-slave-1
      - mysql-slave-2
      - orchestrator-raft-1
    networks:
      - mysql-replication
    volumes:
      - ./monitor-raft.sh:/app/monitor.sh:ro
      - ./test-failover.sh:/app/test.sh:ro
      - /var/log/orchestrator:/var/log/orchestrator
    environment:
      # 自动在 Docker 网络中使用正确的地址
      MYSQL_MASTER_HOST: mysql-master
      MYSQL_SLAVE1_HOST: mysql-slave-1
      MYSQL_SLAVE2_HOST: mysql-slave-2
      ORCHESTRATOR_API: http://orchestrator-raft-1:3000
      PROXYSQL_ADMIN_HOST: orchestrator-proxysql
      MYSQL_USER: root
      MYSQL_PASS: root
      MONITOR_INTERVAL: "10"
    entrypoint: /bin/bash -c
    command: |
      apt-get update && apt-get install -y mysql-client curl jq &&
      while true; do
        bash /app/monitor.sh once
        sleep 10
      done
```

### 启动和监控

```bash
# 启动监控容器
docker-compose -f docker-compose.raft.yml up -d monitor

# 查看监控日志
docker-compose -f docker-compose.raft.yml logs -f monitor

# 停止监控
docker-compose -f docker-compose.raft.yml stop monitor
```

---

## 📊 三种方案对比

| 对比项 | 方案 A | 方案 B | 方案 C |
|--------|--------|--------|--------|
| 设置难度 | ⭐ 非常简单 | ⭐⭐ 需要改代码 | ⭐⭐⭐ 较复杂 |
| 脚本兼容性 | ✅ 100% 兼容 | ✅ 100% 兼容 | ✅ 100% 兼容 |
| 支持 Host | ✅ 自动 | ✅ 手动检测 | ❌ 需要单独脚本 |
| 支持 Docker | ✅ 自动 | ✅ 自动 | ✅ 自动 |
| 可靠性 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| 维护成本 | ⭐ 最低 | ⭐⭐ 中等 | ⭐⭐⭐ 较高 |
| **推荐度** | **⭐⭐⭐ 强烈推荐** | ⭐⭐ 可选 | ⭐ 不推荐 |

---

## 🎯 最佳实践

### 推荐做法

1. **在 Host 上运行监控脚本**（方案 A）
   ```bash
   # 监控 Host 本地部署的服务或远端服务
   bash monitor-raft-docker-enhanced.sh continuous
   ```

2. **在容器内执行故障转移测试**
   ```bash
   # 从容器内验证 Docker 网络通信
   docker exec mysql-master bash /app/test-failover.sh master-crash
   ```

3. **使用环境变量覆盖自动检测**（在特殊场景）
   ```bash
   # 如果自动检测失败，明确指定
   MYSQL_MASTER_HOST=my-remote-host bash monitor-raft.sh once
   ```

---

## 🔍 故障排查

### 问题 1: "无法连接 MySQL Master"

**在 Host 上** → 检查端口映射
```bash
docker-compose ps
# 应该显示 mysql-master 的 3306 映射到 127.0.0.1:3306
```

**在 Docker 内** → 检查网络名称
```bash
docker exec mysql-master hostname
# 应该输出容器名称
```

### 问题 2: 自动检测失败

```bash
# 手动检查是否在 Docker 内
[ -f "/.dockerenv" ] && echo "In Docker" || echo "Not in Docker"

# 或查看 cgroup
cat /proc/self/cgroup | grep docker
```

### 问题 3: ProxySQL 地址错误

```bash
# 检查 ProxySQL 容器名称
docker-compose ps | grep proxysql

# 如果名称不是 orchestrator-proxysql，手动指定
PROXYSQL_ADMIN_HOST=<actual-container-name> bash monitor-raft.sh once
```

---

## 📚 相关文件

- **分析文档**：[DOCKER-ACCESS-ANALYSIS.md](DOCKER-ACCESS-ANALYSIS.md)
- **增强版脚本**：[monitor-raft-docker-enhanced.sh](monitor-raft-docker-enhanced.sh)
- **原始脚本**：[monitor-raft.sh](monitor-raft.sh)
- **Docker Compose**：[docker-compose.raft.yml](docker-compose.raft.yml)

---

## ✅ 快速检查清单

部署时确认以下事项：

- [ ] 有一个可用的脚本版本（选择方案 A、B 或 C）
- [ ] Docker Compose 网络正确配置（网络名称：`mysql-replication`）
- [ ] 服务容器名称与脚本配置一致
- [ ] MySQL 用户和密码设置正确
- [ ] Host 上的端口映射正确（3306→3306, 3307→3306, 3308→3306）
- [ ] 运行一次测试：`bash monitor-raft.sh once`
- [ ] 验证输出显示正确的运行环境（HOST 或 DOCKER_CONTAINER）

---

**下一步**：选择方案 A、B 或 C，按步骤实施，然后运行 `bash monitor-raft.sh once` 验证！
