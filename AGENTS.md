# AGENTS.md

## Cursor Cloud specific instructions

### Overview

**orchestrator** is a MySQL high availability and replication management tool written in Go 1.16. It provides a CLI, HTTP API, and web UI (port 3000). Dependencies are vendored under `vendor/`.

### System prerequisites

- **Go 1.16.x** (must match `go1.1[6789]` pattern; Go 1.20+ will fail due to removed `-i` build flag)
- **gcc** (required for SQLite3 CGO compilation)
- **rsync** (used by `script/build` to copy resources)

### Build

```
export PATH=/usr/local/go/bin:$PATH
script/build
```

Binary is output to `bin/orchestrator`. The `script/bootstrap` step creates a `.gopath` symlink workspace; `script/build` calls it automatically.

### Lint

```
script/test-source
```

Runs `gofmt -s -w go/` and checks for uncommitted formatting changes.

### Unit tests

```
script/test-unit
```

Runs `go test ./go/...` inside the `.gopath` workspace. No external services required.

### Integration tests

```
script/test-integration
```

Requires a running local MySQL instance (used via `dbdeployer` in CI). Not needed for basic dev work.

### Running the application (dev mode)

orchestrator can run with SQLite backend (zero external dependencies). Create a config pointing `SQLite3DataFile` to a writable path:

```bash
mkdir -p /tmp/orchestrator-data
cat conf/orchestrator-sample-sqlite.conf.json | python3 -c "
import json, sys
c = json.load(sys.stdin)
c['SQLite3DataFile'] = '/tmp/orchestrator-data/orchestrator.sqlite3'
json.dump(c, sys.stdout, indent=2)
" > /tmp/orchestrator-data/orchestrator-dev.conf.json

bin/orchestrator --debug --config /tmp/orchestrator-data/orchestrator-dev.conf.json http
```

Web UI at http://localhost:3000, API at http://localhost:3000/api/.

### Cluster environment (orchestrator-ci-env)

For full end-to-end testing with a MySQL replication topology, use `orchestrator-ci-env` (Docker-based):

```bash
# Clone and build (one-time)
cd /tmp && git clone https://github.com/openark/orchestrator-ci-env.git
cd /tmp/orchestrator-ci-env && sudo docker build . -f Dockerfile -t orchestrator-ci-env

# Start the cluster environment (detached)
sudo docker run -d --name orchestrator-ci-env \
  -p 13306:13306 -p 10111:10111 -p 10112:10112 -p 10113:10113 -p 10114:10114 -p 8500:8500 \
  -e "REPORT_HOSTNAME=127.0.0.1" \
  orchestrator-ci-env:latest bash -c "script/docker-entry; sleep infinity"
```

This provides:
- **4 MySQL nodes** (ports 10111-10114): master-replica topology with GTID, user `ci`/`ci`
- **HAProxy** (port 13306): routes to current master
- **Consul** (port 8500): service discovery + KV store

Connect orchestrator to the cluster (disable Raft for single-node dev):

```bash
cat conf/orchestrator-ci-env.conf.json | python3 -c "
import json, sys
c = json.load(sys.stdin)
c['SQLite3DataFile'] = '/tmp/orchestrator-cluster.sqlite3'
c['RaftEnabled'] = False
json.dump(c, sys.stdout, indent=2)
" > /tmp/orchestrator-cluster.conf.json

bin/orchestrator --debug --config /tmp/orchestrator-cluster.conf.json http
```

Orchestrator will auto-discover the 4-node topology within ~15 seconds. Web UI at http://localhost:3000/web/cluster/alias/ci.

To rebuild the MySQL topology after destructive tests: `sudo docker exec orchestrator-ci-env script/deploy-replication 127.0.0.1`

### Gotchas

- The `script/build` script recreates `.gopath/` on every invocation (deletes and re-symlinks). This is normal.
- `go build -i` flag warning is expected on Go 1.16 (deprecated but functional).
- The sample SQLite config's `SQLite3DataFile` points to `/usr/local/orchestrator/orchestrator.sqlite3` which likely doesn't exist; override it as shown above.
- System tests (`script/test-system`) require a full Docker-based `orchestrator-ci-env` setup with MySQL topology, HAProxy, and Consul — not needed for development.
- The `conf/orchestrator-ci-env.conf.json` has `RaftEnabled: true` by default. For single-node local dev, set it to `false` to avoid Raft consensus issues.
- Docker-in-Docker in Cloud Agent VMs requires `fuse-overlayfs` storage driver and `iptables-legacy`.
