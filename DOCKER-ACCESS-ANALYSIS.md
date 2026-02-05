# Docker 环境下脚本访问方式分析与改进方案

## 🔍 当前脚本访问方式分析

### 现状检查

**monitor-raft.sh 中的配置：**
```bash
ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-127.0.0.1}"
MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-127.0.0.1}"
MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-127.0.0.1}"
```

**问题：**
- ❌ 所有服务访问都假设在本地 (`127.0.0.1`)，通过端口映射
- ❌ 不支持 Docker 容器内部直接访问（应该使用容器网络名称）
- ❌ 没有自动检测运行环境的机制
- ❌ 不能适应多种部署方式（容器化、云环境、物理机）

---

## 📋 Docker Compose 环境中的服务配置

### docker-compose.raft.yml 中的服务

```yaml
services:
  mysql-master:        # 容器名称（Docker 网络中的 DNS 名）
    ports:
      - "3306:3306"   # 宿主机:容器内
    networks:
      - mysql-replication

  mysql-slave-1:
    ports:
      - "3307:3306"   # 注意：容器内都是 3306，宿主机是 3307
    networks:
      - mysql-replication

  mysql-slave-2:
    ports:
      - "3308:3306"
    networks:
      - mysql-replication

networks:
  mysql-replication:   # Docker 虚拟网络，容器可直接通过名称通信
```

---

## 🔄 三种脚本运行环境对比

| 运行环境 | 脚本位置 | 访问方式 | 前缀 | MySQL 主机 | MySQL 端口 | 示例 |
|---------|---------|--------|------|-----------|-----------|------|
| **Host 本地** | `/workspaces/orchestrator/` | 通过映射端口 | `127.0.0.1` | `127.0.0.1` | `3306, 3307, 3308` | `mysql -h 127.0.0.1 -P 3306` |
| **Docker 容器内** | 在监控容器内 | Docker 网络 DNS | `mysql-master` | `mysql-master` | `3306` ✅ | `mysql -h mysql-master -P 3306` |
| **远端服务器** | `/app/` | 宿主机网络 | `192.168.1.100` | `192.168.1.100` | `3306, 3307, 3308` | `mysql -h 192.168.1.100 -P 3306` |

### 问题详解

**当前脚本只支持第一种（Host 本地），不支持第二、三种！**

---

## ✅ 改进方案

### 方案 1: 自动检测运行环境（推荐）

```bash
# 检测是否在 Docker 容器内运行
detect_docker_environment() {
    # 方法 1: 检查 /.dockerenv 文件
    if [ -f "/.dockerenv" ]; then
        return 0  # 在 Docker 容器内
    fi
    
    # 方法 2: 检查 /proc/self/cgroup
    if grep -q "docker" /proc/self/cgroup 2>/dev/null; then
        return 0  # 在 Docker 容器内
    fi
    
    return 1  # 不在 Docker 容器内
}

# 自动设置访问方式
if detect_docker_environment; then
    # 在 Docker 容器内：使用容器网络名称
    MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-mysql-master}"
    MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-mysql-slave-1}"
    MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-mysql-slave-2}"
    ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://orchestrator-raft-1:3000}"
else
    # 在 Host 上：使用本地端口映射
    MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
    MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-127.0.0.1}"
    MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-127.0.0.1}"
    ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
fi
```

### 方案 2: 环境变量显式指定

```bash
# 在启动脚本时指定环境
# 对于 Host 本地：
./monitor-raft.sh

# 对于 Docker 容器内：
MYSQL_MASTER_HOST=mysql-master \
MYSQL_SLAVE1_HOST=mysql-slave-1 \
MYSQL_SLAVE2_HOST=mysql-slave-2 \
ORCHESTRATOR_API=http://orchestrator-raft-1:3000 \
bash monitor-raft.sh

# 对于远端服务器：
MYSQL_MASTER_HOST=192.168.1.10 \
MYSQL_SLAVE1_HOST=192.168.1.11 \
MYSQL_SLAVE2_HOST=192.168.1.12 \
ORCHESTRATOR_API=http://192.168.1.10:3000 \
bash monitor-raft.sh
```

### 方案 3: 创建专用的 Docker 监控容器

```yaml
# docker-compose.raft.yml 中添加
services:
  # ... 其他服务 ...
  
  monitor:
    image: ubuntu:latest  # 或 alpine:latest
    depends_on:
      - mysql-master
      - mysql-slave-1
      - mysql-slave-2
      - orchestrator-raft-1
    networks:
      - mysql-replication
    volumes:
      - ./monitor-raft.sh:/app/monitor-raft.sh:ro
      - ./recovery-hooks.sh:/app/recovery-hooks.sh:ro
    environment:
      # 使用容器网络名称
      MYSQL_MASTER_HOST: mysql-master
      MYSQL_SLAVE1_HOST: mysql-slave-1
      MYSQL_SLAVE2_HOST: mysql-slave-2
      ORCHESTRATOR_API: http://orchestrator-raft-1:3000
      MONITOR_INTERVAL: "10"
    command: bash -c "while true; do bash /app/monitor-raft.sh once; sleep 10; done"
```

---

## 🔧 实施建议

### 快速修复（现有脚本）

所有脚本都应该添加配置检测逻辑，位置在配置部分（第 15-35 行）：

```bash
# ... 现有配置 ...

# 自动检测运行环境
if [ -f "/.dockerenv" ] || grep -q "docker" /proc/self/cgroup 2>/dev/null; then
    # 在 Docker 容器内运行
    MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-mysql-master}"
    MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-mysql-slave-1}"
    MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-mysql-slave-2}"
    MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"    # ← 注意：容器内是原始端口！
    MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3306}"
    MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3306}"
    ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://orchestrator-raft-1:3000}"
    PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-orchestrator-proxysql}"
else
    # 在 Host 或远端运行
    MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-127.0.0.1}"
    MYSQL_SLAVE1_HOST="${MYSQL_SLAVE1_HOST:-127.0.0.1}"
    MYSQL_SLAVE2_HOST="${MYSQL_SLAVE2_HOST:-127.0.0.1}"
    MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
    MYSQL_SLAVE1_PORT="${MYSQL_SLAVE1_PORT:-3307}"
    MYSQL_SLAVE2_PORT="${MYSQL_SLAVE2_PORT:-3308}"
    ORCHESTRATOR_API="${ORCHESTRATOR_API:-http://127.0.0.1:3000}"
    PROXYSQL_ADMIN_HOST="${PROXYSQL_ADMIN_HOST:-127.0.0.1}"
fi
```

---

## 🎯 需要修改的脚本清单

| 脚本 | 当前问题 | 改进方案 |
|------|--------|--------|
| monitor-raft.sh | Host 本地访问方式 | ✅ 添加自动检测 |
| test-failover.sh | Host 本地访问方式 | ✅ 添加自动检测 |
| recover-from-power-failure.sh | Host 本地访问方式 | ✅ 添加自动检测 |
| recovery-hooks.sh | ProxySQL Host 访问 | ✅ 添加容器支持 |
| deploy-proxysql.sh | 假设 localhost | ✅ 添加事件检测 |

---

## 📊 改进效果对比

### 改进前

```bash
bash monitor-raft.sh          # ✅ 工作（Host 本地）
docker exec monitor-container bash monitor-raft.sh
# ❌ 失败！无法连接 127.0.0.1:3306
```

### 改进后

```bash
bash monitor-raft.sh          # ✅ 工作（自动检测 Host）
docker exec monitor-container bash monitor-raft.sh
# ✅ 工作！自动检测到容器内，使用 mysql-master:3306
```

---

## 🔗 相关文件

- Docker Compose: [docker-compose.raft.yml](docker-compose.raft.yml)
- 监控脚本: [monitor-raft.sh](monitor-raft.sh)
- 测试脚本: [test-failover.sh](test-failover.sh)
- 恢复脚本: [recover-from-power-failure.sh](recover-from-power-failure.sh)

---

## 📝 修改步骤

1. ☐ 更新 monitor-raft.sh（添加自动检测）
2. ☐ 更新 test-failover.sh（添加自动检测）
3. ☐ 更新 recover-from-power-failure.sh（添加自动检测）
4. ☐ 更新 recovery-hooks.sh（支持容器 ProxySQL）
5. ☐ 创建示例 docker-compose 监控容器配置
6. ☐ 测试所有脚本在 Docker 容器内的运行

---

**优先级：高** - 这会影响容器化部署的可操作性
