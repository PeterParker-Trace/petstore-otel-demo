# PetStore — OpenTelemetry Demo App

A polyglot microservices demo application designed to generate rich, varied telemetry (logs, metrics, traces) for OpenTelemetry instrumentation demos. Backend telemetry is shipped to **Coralogix**.

## Branches

- **`main`** — vanilla app, no instrumentation. The "before" state.
- **`instrumented`** — same app with zero-code OpenTelemetry instrumentation. The "after" state.

## Architecture

```
 Frontend (Node)  →  API Gateway (Python)  →  Catalog (Node)   ─┐
                                           └→  Orders  (Python) ─┼→ Postgres
                                                  │
                                                  ↓
                                            Payments (Go)   [simulates flaky 3rd-party]
```

| Service           | Language         | Port  | Purpose                                      |
|-------------------|------------------|-------|----------------------------------------------|
| `frontend`        | Node.js / Express | 3000 | Static UI + same-origin API proxy            |
| `api-gateway`     | Python / FastAPI  | 8000 | Public API, routes to backends               |
| `catalog-service` | Node.js / Express | 3001 | Pet catalog reads & stock reservation        |
| `orders-service`  | Python / FastAPI  | 8001 | Order orchestration (calls catalog+payments) |
| `payments-service`| Go (stdlib)       | 8080 | Simulated payment gateway with chaos         |
| `postgres`        | Postgres 16       | 5432 | Shared DB for catalog & orders               |
| `load-generator`  | Python / Locust   | —    | Continuous synthetic traffic                 |

## Local quickstart

```bash
docker compose up --build
```

Then open http://localhost:3000 — you should see the pet catalog. Click **Buy** on any pet.

To start continuous load:
```bash
docker compose --profile load up -d load-generator
```

To tear everything down (including DB volume):
```bash
docker compose down -v
```

## Useful curl probes

```bash
# Health checks
curl localhost:3000/health
curl localhost:8000/health
curl localhost:3001/health
curl localhost:8001/health
curl localhost:8080/health

# List pets via the gateway
curl localhost:8000/api/pets

# Place an order via the gateway
curl -X POST localhost:8000/api/orders \
  -H "Content-Type: application/json" \
  -d '{"pet_id": 1, "quantity": 1, "customer_email": "alice@example.com"}'
```

## Configurable chaos

The payments service has two env vars to tune what failures look like:
- `FAILURE_RATE` (default `0.10`) — fraction of charges that get declined
- `MAX_LATENCY_MS` (default `800`) — upper bound of normal processing latency. ~5% of calls also get an extra 1.5–3.5s "slow tail" added.

Set them in `docker-compose.yml` to demo different scenarios.
