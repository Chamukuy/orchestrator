# 掉电恢复功能部署指南

快速启用全掉电自动恢复功能

## 🚀 快速启用（5 分钟）

### Step 1: 复制脚本和服务文件

```bash
# 复制恢复脚本
cp recover-from-power-failure.sh /usr/local/bin/
chmod +x /usr/local/bin/recover-from-power-failure.sh

# 复制 systemd 服务文件
cp orchestrator-power-recovery.service /etc/systemd/system/
```

### Step 2: 编辑服务配置

根据你的环境修改环境变量：

```bash
vim /etc/systemd/system/orchestrator-power-recovery.service
```

**需要修改的环境变量：**

```ini
Environment="ORCHESTRATOR_API=http://YOUR_ORCH_IP:3000"
Environment="MYSQL_MASTER_HOST=YOUR_MASTER_IP"
Environment="MYSQL_MASTER_PORT=3306"
Environment="MYSQL_USER=root"
Environment="MYSQL_PASS=your_password"
Environment="ALERT_EMAIL=ops@company.com"
```

### Step 3: 启用自启动

```bash
# 重新加载 systemd 配置
systemctl daemon-reload

# 启用服务（在系统启动时自动运行）
systemctl enable orchestrator-power-recovery.service

# 验证已启用
systemctl is-enabled orchestrator-power-recovery.service
# 输出应为 enabled
```

### Step 4: 验证配置

```bash
# 查看服务状态
systemctl status orchestrator-power-recovery.service

# 查看日志
journalctl -u orchestrator-power-recovery.service -f

# 手动测试（已启用后可选）
systemctl start orchestrator-power-recovery.service
```

---

## 🧪 测试恢复流程

### 测试 1: 模拟完整掉电恢复

```bash
# 1. 停止所有服务
docker-compose -f docker-compose.raft.yml down
docker-compose -f docker-compose.proxysql.yml down

# 2. 等待 30 秒
sleep 30

# 3. 重新启动
docker-compose -f docker-compose.raft.yml up -d
docker-compose -f docker-compose.proxysql.yml up -d

# 4. 自动恢复脚本应该触发（如已配置）
# 或手动运行
bash /usr/local/bin/recover-from-power-failure.sh

# 5. 监控恢复过程
bash monitor-raft.sh once
```

### 测试 2: 验证日志

```bash
# 查看恢复日志
tail -50 /var/log/orchestrator/power-recovery.log

# 查看恢复过程中的关键步骤
grep "SUCCESS\|ERROR\|WARNING" /var/log/orchestrator/power-recovery.log
```

---

## 📊 恢复流程详解

```
系统启动
    ↓
systemd 启动 orchestrator-power-recovery.service
    ↓
recover-from-power-failure.sh 执行
    ↓
┌─────────────────────────────────────────┐
│ 第一阶段: 等待系统稳定 (1-2 min)       │
│ - 等待 30 秒电源稳定                    │
│ - 等待网络连接                         │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│ 第二阶段: 等待 Orchestrator (2-5 min)  │
│ - curl Orchestrator API                │
│ - 等待响应（最长 5 分钟）               │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│ 第三阶段: 等待 Raft Leader (2-5 min)   │
│ - 检查 /api/leader-check               │
│ - 等待 Leader 选举完成                 │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│ 第四阶段: 等待 MySQL (1-5 min)         │
│ - 连接 MySQL Master                    │
│ - 等待启动完成                         │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│ 第五阶段: 检查拓扑 (5-30 sec)          │
│ - /api/cluster/master-slave            │
│ - 检查是否需要故障转移                 │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│ 第六阶段: 触发故障转移（如需）(1-2 min)│
│ - POST /api/recover/cluster/           │
│ - 等待转移完成                         │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│ 第七阶段: 验证系统 (10-30 sec)         │
│ - 健康检查                            │
│ - 生成恢复报告                         │
└─────────────────────────────────────────┘
    ↓
系统完全恢复！✅
```

---

## ⚙️ 配置参数说明

### 监控和日志

```bash
# 恢复日志位置
/var/log/orchestrator/power-recovery.log

# 恢复过程中的故障转移日志
/var/log/orchestrator/recovery-hooks.log

# Orchestrator 主日志
/var/log/orchestrator/orchestrator.log
```

### 超时配置

在脚本中修改超时时间（单位：秒）：

```bash
MAX_WAIT_TIME=600        # 总最长等待时间（10 分钟）
CHECK_INTERVAL=10        # 每次检查间隔（10 秒）

# 各个阶段的超时可以单独修改
# 例如第二阶段: max_wait=300
```

### 告警邮件

配置 systemd 环境变量中的 `ALERT_EMAIL`：

```bash
Environment="ALERT_EMAIL=ops-team@company.com"
```

脚本会在恢复完成后发送报告邮件。

---

## 🔍 故障排查

### 问题 1: 恢复脚本没有执行

**症状**：系统启动后，`/var/log/orchestrator/power-recovery.log` 不存在

**排查：**

```bash
# 1. 检查服务状态
systemctl status orchestrator-power-recovery.service

# 2. 查看 systemd 日志
journalctl -u orchestrator-power-recovery.service -n 50

# 3. 检查文件权限
ls -lh /usr/local/bin/recover-from-power-failure.sh
# 应该有 x 权限

# 4. 手动运行测试
bash /usr/local/bin/recover-from-power-failure.sh
```

**常见原因**：
- [ ] 服务未启用：`systemctl enable orchestrator-power-recovery.service`
- [ ] 脚本权限不足：`chmod +x /usr/local/bin/recover-from-power-failure.sh`
- [ ] 日志目录不存在：`mkdir -p /var/log/orchestrator`

### 问题 2: 恢复超时

**症状**：脚本等待超过 5 分钟后给出超时错误

**原因和解决**：

| 超时阶段 | 可能原因 | 解决方案 |
|---------|--------|--------|
| Orchestrator | API 服务未启动 | 检查 Docker 容器或进程状态 |
| Raft Leader | 少于 2 个节点启动 | 等待更多节点启动，或手动恢复 |
| MySQL | MySQL 服务未启动 | 检查 MySQL 进程和数据完整性 |
| 故障转移 | Raft 无法转移 | 检查复制拓扑和 GTID 状态 |

**手动恢复：**

```bash
# 如果脚本超时，可以手动检查和恢复

# 1. 检查 Orchestrator 是否有 Leader
curl http://127.0.0.1:3000/api/leader-check

# 2. 查看拓扑
curl http://127.0.0.1:3000/api/cluster/master-slave | jq .

# 3. 如果有 Master 故障，手动触发转移
curl -X POST http://127.0.0.1:3000/api/recover/cluster/master-slave

# 4. 验证恢复
bash monitor-raft.sh once
```

### 问题 3: systemd 无法找到脚本

**症状**：`systemctl status` 显示 "ExecStart specified nonexistent file"

**解决**：

```bash
# 检查脚本路径
which recover-from-power-failure.sh
ls -l /usr/local/bin/recover-from-power-failure.sh

# 重新复制脚本
cp recover-from-power-failure.sh /usr/local/bin/
chmod +x /usr/local/bin/recover-from-power-failure.sh

# 更新 systemd 配置
systemctl daemon-reload
```

---

## 📈 监控恢复进度

### 实时监控（推荐）

```bash
# 终端 1: 观看恢复脚本日志
tail -f /var/log/orchestrator/power-recovery.log

# 终端 2: 观看 Orchestrator 日志
tail -f /var/log/orchestrator/orchestrator.log

# 终端 3: 运行监控脚本
bash monitor-raft.sh continuous
```

### 关键日志指标

```bash
# 查看恢复是否成功完成
grep "SUCCESS" /var/log/orchestrator/power-recovery.log | tail -5

# 查看是否有故障转移发生
grep "failover" /var/log/orchestrator/*.log

# 查看是否有错误
grep "ERROR" /var/log/orchestrator/power-recovery.log
```

---

## 🎯 最佳实践

### 1. 定期测试恢复流程

```bash
# 每月测试一次
# 注意：会影响生产环境，请选择低峰期

bash /usr/local/bin/recover-from-power-failure.sh
```

### 2. 配置监控告警

```bash
# 配置 Slack 或邮件告警
export SLACK_WEBHOOK="https://hooks.slack.com/..."
bash monitor-raft.sh continuous &

# 确保监控脚本在后台持续运行
# 可以配置到 systemd 或 supervisor
```

### 3. 定期备份配置

```bash
# 备份 Orchestrator 配置
cp conf/orchestrator-raft.conf.json /backup/orchestrator-raft.conf.json.$(date +%Y%m%d)

# 备份 ProxySQL 配置
docker cp orchestrator-proxysql:/etc/proxysql.cnf /backup/proxysql.cnf.$(date +%Y%m%d)
```

### 4. 记录故障日志

```bash
# 每次故障后，存档日志用于事后分析
cp /var/log/orchestrator/power-recovery.log /var/log/orchestrator/archives/power-recovery-$(date +%Y%m%d-%H%M%S).log
```

---

## 📚 相关文档

- **掉电恢复详细指南**: [POWER-FAILURE-RECOVERY.md](POWER-FAILURE-RECOVERY.md)
- **故障管理**: [FAILURE-MANAGEMENT.md](FAILURE-MANAGEMENT.md)
- **监控脚本**: [monitor-raft.sh](monitor-raft.sh)

---

## 快速命令参考

```bash
# 查看服务状态
systemctl status orchestrator-power-recovery.service

# 启用自启动
systemctl enable orchestrator-power-recovery.service

# 禁用自启动
systemctl disable orchestrator-power-recovery.service

# 手动运行
bash /usr/local/bin/recover-from-power-failure.sh

# 查看日志
tail -f /var/log/orchestrator/power-recovery.log

# 查看 systemd 日志
journalctl -u orchestrator-power-recovery.service -f

# 重新加载配置
systemctl daemon-reload

# 重启服务
systemctl restart orchestrator-power-recovery.service
```

---

**版本**: 1.0  
**更新日期**: 2026-02-05  
**适用**: Orchestrator 3.2+, systemd 服务管理系统
