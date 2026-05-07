# PetStore OTEL Demo — Build & Onboarding Guide

This is a step-by-step guide to building, instrumenting, and deploying the PetStore demo app for OpenTelemetry + Coralogix demos. Each phase is self-contained: you finish one, you have something that works.

---

## Phase 1 — Build the vanilla microservices app

**Goal:** Get a multi-service app with a database running on your laptop with `docker compose up`.

**You will end with:**
- A working PetStore at `http://localhost:3000`
- Six services running side-by-side
- A `main` branch on GitHub that anyone can clone and `docker compose up`

### Architecture chosen

A polyglot e-commerce-style app with intentional latency and failure injection in the payments service so that observability data is *interesting*, not flat.

```
 Frontend (Node)  →  API Gateway (Python)  →  Catalog (Node)   ─┐
                                           └→  Orders  (Python) ─┼→ Postgres
                                                  │
                                                  ↓
                                            Payments (Go)
```

### Why these tech choices

- **Polyglot (Node + Python + Go):** real customers run zoos of languages. Demoing OTEL across all three proves the universal value prop.
- **HTTP between services:** OTEL auto-instruments HTTP clients/servers everywhere. (gRPC is cooler but less common, and adds proto complexity.)
- **Postgres shared by 2 services:** keeps infra small while still producing real DB spans.
- **Chaos in payments:** boring telemetry teaches nothing. We want to see red spans, p99 spikes, error logs.
- **`docker-compose` for local:** simplest path. Translates cleanly to ECS task definitions and K8s manifests later.

### Step 1 — Prerequisites

You need:
- Docker Desktop (or Docker Engine + Compose plugin) — `docker --version` and `docker compose version`
- ~4 GB of free RAM
- Ports 3000, 3001, 5432, 8000, 8001, 8080 free on your laptop

### Step 2 — Project layout

```
petstore-otel-demo/
├── docker-compose.yml
├── README.md
├── db/
│   └── init.sql                  # creates tables + seed data on first DB start
├── services/
│   ├── frontend/                 # Node.js — UI + same-origin proxy
│   ├── api-gateway/              # Python FastAPI — public API
│   ├── catalog-service/          # Node.js — pets read + reserve
│   ├── orders-service/           # Python FastAPI — order orchestration
│   ├── payments-service/         # Go — simulated payment gateway
│   └── load-generator/           # Locust — synthetic traffic
└── docs/
    └── GUIDE.md                  # this file
```

Each service is fully self-contained (its own `Dockerfile`, deps, code).

### Step 3 — Build & run locally

```bash
git clone <your-repo>
cd petstore-otel-demo
docker compose up --build
```

First boot takes a few minutes (downloading base images, installing deps). Subsequent runs are seconds.

### Step 4 — Verify it works

Open `http://localhost:3000` — you should see eight pets. Click **Buy** on one of them. You should see either:
- ✅ "Order N confirmed"
- ❌ "Order failed: payment declined" (10% of the time, by design)

### Step 5 — Generate continuous load (optional)

```bash
docker compose --profile load up -d load-generator
```

This starts 5 simulated users browsing and buying continuously. Tail logs to see the activity:

```bash
docker compose logs -f orders-service payments-service
```

### Step 6 — Push to GitHub

```bash
git init
git add .
git commit -m "Phase 1: vanilla PetStore microservices app"
git branch -M main
git remote add origin git@github.com:<you>/petstore-otel-demo.git
git push -u origin main
```

### Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `port already allocated` | Something else on your laptop already listens on 3000/8000/etc. | Either kill the other process or change the host-side port mapping in `docker-compose.yml`. |
| `connection refused` from orders → catalog | A service started before the one it depends on. | The `depends_on` + `service_healthy` for postgres handles the worst case; for service-to-service order, the app's HTTP retries (or restart `docker compose up`) will sort it. |
| Postgres data persists across `down` | Default behavior — the volume `pgdata` survives. | Use `docker compose down -v` to wipe it. |
| Buy button always errors | Likely payments-service down OR your `FAILURE_RATE=1.0`. | `docker compose ps` and check logs. |

---

## Phase 2 — Add OpenTelemetry zero-code instrumentation

*(coming next)*

---

## Phase 3 — Connect to Coralogix

*(later)*

---

## Phase 4 — Deploy to AWS ECS on EC2 Spot

*(later)*

---

## Phase 5 — Deploy to EKS

*(later)*
