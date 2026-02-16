# etcd + HAProxy Dynamic Load Balancing Demo

This project demonstrates **dynamic service discovery and load
balancing** using:

-   **etcd v3** as the source of truth
-   **HAProxy** as the data plane
-   **Docker Compose** for local orchestration
-   A custom **controller-style** GO program that watches etcd and
    reconciles HAProxy config

Backends register themselves in etcd, and HAProxy updates automatically
when backends are added or removed --- no restarts required.

------------------------------------------------------------------------

## 🧠 Architecture Overview

    +------------+        +------------------+
    |  backend   | -----> |                  |
    |  containers|        |                  |
    +------------+        |                  |
           |              |                  |
           |  PUT /lease  |      etcd        |
           +------------> |   (v3 API)       |
                          |                  |
                          +------------------+
                                   |
                                   | watch + reconcile
                                   v
                          +------------------+
                          |     HAProxy      |
                          | (lb1, lb2, ...)  |
                          +------------------+
                                   |
                                   v
                               Clients

-   Backends register under `/services/backend/<id>`
-   HAProxy nodes **watch etcd**, then **re-render config from full
    state**
-   Config updates are **atomic and debounced**
-   HAProxy reloads gracefully (`-sf`)

------------------------------------------------------------------------

## ✨ Key Features

-   Dynamic backend discovery via etcd v3
-   Multiple HAProxy instances (active/active)
-   No dropped backends
-   Atomic config updates
-   Safe reloads (no downtime)
-   Debounced watch handling (no flapping)
-   Docker-native, no host dependencies
-   Works on **amd64 and arm64** (Apple Silicon)

------------------------------------------------------------------------

## 🚀 Quick Start

### 1. Clone the repo

``` bash
git clone https://github.com/ketilaa/etcd-haproxy-demo.git
cd etcd-haproxy-demo
```

### 2. Start the stack

``` bash
docker compose up -d
```

### 3. Scale backends

``` bash
docker compose up -d --scale backend=3
```

### 4. Test load balancing

``` bash
curl http://localhost:8001
curl http://localhost:8001
curl http://localhost:8001
```

You should see responses coming from different backend containers.

------------------------------------------------------------------------

## 🔍 Inspect etcd State

List registered backends:

``` bash
docker exec -e ETCDCTL_API=3 etcd1 \
  etcdctl get /services/backend --prefix
```

Watch backend changes live:

``` bash
docker exec -e ETCDCTL_API=3 etcd1 \
  etcdctl watch /services/backend --prefix
```

------------------------------------------------------------------------

## 📂 Project Structure

    .
    ├── backend/          # Example backend service (self-registers in etcd)
    ├── lb-node-go        # HAProxy image + GO controller
    ├── docker-compose.yml
    ├── README.md

------------------------------------------------------------------------

## ⚠️ Important Design Notes

### etcd Watch Semantics

etcd watch events are **edge-triggered**, not state snapshots.

This project follows the correct controller pattern:

    watch event → debounce → read full state → reconcile

Failing to debounce can result in **partial configs**.

------------------------------------------------------------------------

### Why not confd?

This project intentionally **does not use confd**:

- confd binaries are architecture-sensitive
- confd hides important controller logic
- rolling your own makes failure modes explicit

The result is more code --- but far more understanding.

------------------------------------------------------------------------

## 🧪 What This Is (and Is Not)

**This is:**
- a learning-oriented distributed systems demo
- a minimal controller-style reconciler
- a clear example of etcd + HAProxy integration

**This is not:**
- a production-ready service mesh
- a replacement for Consul/Nomad/Kubernetes

If you want this pattern in production, look at:
- **Consul**
- **Nomad**
- **Kubernetes**

------------------------------------------------------------------------

## 📜 License

This work is licensed under **Creative Commons Zero v1.0 Universal (CC0
1.0)**.

You are free to:
- use
- modify
- distribute
- sell

with **no attribution required**.

See: https://creativecommons.org/publicdomain/zero/1.0/

------------------------------------------------------------------------

## ❤️ Final Note

This repository exists because distributed systems are best learned by
**building the sharp edges yourself**.

If this helped you understand:
- service discovery
- control planes vs data planes
- watch semantics
- or why controllers are hard

then it did its job.