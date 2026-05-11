# PetStore OTEL Demo — Build & Onboarding Guide

A polyglot microservices demo app instrumented with OpenTelemetry and shipping telemetry to Coralogix. This guide takes you from zero to a fully working observability stack in three phases, with documented gotchas and fixes from real build experience.
---

## Repository Branches

- **`main`** — vanilla app, no instrumentation. The "before" state.
- **`instrumented`** — same app with OpenTelemetry zero-code instrumentation and Coralogix integration. The "after" state.
---

## Architecture

A polyglot e-commerce-style app with intentional latency and failure injection in the payments service so observability data is *interesting*, not flat.

```
 Frontend (Node)  →  API Gateway (Python)  →  Catalog (Node)   ─┐
                                           └→  Orders  (Python) ─┼→ Postgres
                                                  │
                                                  ↓
                                            Payments (Go)
```

| Service           | Language          | Port | Role                                          |
|-------------------|-------------------|------|-----------------------------------------------|
| `frontend`        | Node.js / Express | 3000 | Static UI + same-origin API proxy             |
| `api-gateway`     | Python / FastAPI  | 8000 | Public API, routes to backends                |
| `catalog-service` | Node.js / Express | 3001 | Pet catalog reads + stock reservation         |
| `orders-service`  | Python / FastAPI  | 8001 | Order orchestration (calls catalog + payments)|
| `payments-service`| Go (stdlib)       | 8080 | Simulated payment gateway with chaos          |
| `postgres`        | Postgres 16       | 5432 | Shared DB for catalog & orders                |
| `load-generator`  | Python / Locust   | —    | Continuous synthetic traffic                  |
| `otel-collector`  | otel-contrib      | 4318 | Receives + exports telemetry (Phase 2+)       |
---

## Prerequisites

Install these before starting:

- **Docker Desktop** (or Docker Engine + Compose plugin) — `docker --version` and `docker compose version`
- **Git**
- **A text editor** (VS Code recommended)
- **A modern browser** (Chrome, Edge, Firefox, or Safari — Chrome best for DevTools)
- **~4 GB of free RAM**
- **Free TCP ports** on your machine: 3000, 3001, 4317, 4318, 5432, 8000, 8001, 8080, 8888

For Phase 3 you also need:

- **A Coralogix account** with a "Send-Your-Data" API key
- **Knowledge of which Coralogix region** your account is in (US1, US2, EU1, EU2, AP1, AP2)

---

# Phase 1 — Build the Vanilla App

**Goal:** Get a multi-service app with a database running on your laptop with `docker compose up`.

**Branch:** `main`

## Step 1: Project layout

```
petstore-otel-demo/
├── docker-compose.yml
├── README.md
├── .gitignore
├── db/
│   └── init.sql                  # creates tables + seeds data on first DB start
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

Each service is fully self-contained: own `Dockerfile`, own dependencies, own code.

## Step 2: Why these tech choices

| Decision | Why |
|---|---|
| **Polyglot (Node + Python + Go)** | Real customers run zoos of languages. Demoing OTEL across all three proves the universal value prop. |
| **HTTP between services** | OTEL auto-instruments HTTP clients/servers everywhere. (gRPC is more efficient but adds proto complexity.) |
| **Postgres shared by 2 services** | Keeps infra small while still producing real DB spans. In a "true" microservices architecture each service owns its DB; for a demo this is fine. |
| **Chaos in payments** | Boring telemetry teaches nothing. We want red spans, p99 spikes, error logs. |
| **`docker-compose` for local** | Simplest path. Translates cleanly to ECS task definitions and K8s manifests later. |
| **Structured JSON logs from day one** | Foundation for searchable, queryable logs. `console.log("user 123 logged in")` is unparseable; `{"event":"login","user_id":123}` is filterable by every field. |

## Step 3: Build & run locally

```bash
git clone https://github.com/<your-username>/petstore-otel-demo.git
cd petstore-otel-demo
docker compose up --build
```

First boot takes a few minutes (downloading base images, installing deps). Subsequent runs are seconds.

## Step 4: Verify

Open `http://localhost:3000` — you should see eight pets. Click **Buy** on one of them.

Expected behavior:
- ✅ ~90% of orders succeed → "Order N confirmed"
- ❌ ~10% fail → "Order failed: payment declined" (by design)
- Stock decrements on success (rare pets like Slinky drain quickly)

## Step 5: Generate continuous load (optional)

```bash
docker compose --profile load up -d load-generator
```

Five simulated users browse and buy continuously. Tail logs to watch the activity:

```bash
docker compose logs -f orders-service payments-service
```

Stop the load generator with:

```bash
docker compose --profile load down load-generator
```

## Step 6: Push to GitHub

```bash
git init
git config user.name "Your Name"
git config user.email "you@example.com"   # or a noreply email if repo is public
git add .
git status                                # always review before committing
git commit -m "Phase 1: vanilla PetStore polyglot microservices app"
git branch -M main
git remote add origin git@github.com:<your-username>/petstore-otel-demo.git
git push -u origin main
```

For HTTPS auth, use a [Personal Access Token (PAT)](https://github.com/settings/tokens) with `repo` scope, not your GitHub password.

## Common Phase 1 issues we hit (and fixes)

### Issue: `email-validator is not installed`

**Symptom:** orders-service crashes on startup with `ImportError: email-validator is not installed`.

**Cause:** Pydantic's `EmailStr` type requires the optional `email_validator` library. We declared `pydantic` in `requirements.txt` without the `[email]` extra.

**Fix:** Change `pydantic==2.9.2` to `pydantic[email]==2.9.2` in `services/orders-service/requirements.txt`. Rebuild that service.

**TAM lesson:** when you see `package[extra]` in Python error messages, it always means "install with optional extras." Common examples: `uvicorn[standard]`, `fastapi[all]`, `sqlalchemy[asyncio]`.

### Issue: `[object Object]` error in browser

**Symptom:** Click Buy → red banner says "Order failed: [object Object]".

**Cause:** Frontend interpolates `data.detail` into a string, but FastAPI returns validation errors as an array of objects. Default JS string conversion gives the useless `[object Object]`.

**Fix:** Add a `formatError()` helper to `services/frontend/public/index.html` that handles all backend error shapes (string, `{detail: "..."}`, FastAPI's `{detail: [{msg, loc}, ...]}`).

**TAM lesson:** every framework's validation error format is different. Frontends that hardcode `data.detail` break the moment validation kicks in. Defensive frontend code at API boundaries is essential.

### Issue: `value is not a valid email address: special-use or reserved name`

**Symptom:** All orders fail with this error after fixing Pydantic.

**Cause:** The `email_validator` library does *strict* validation including blocking RFC-reserved TLDs. `.local` is reserved for mDNS (RFC 6762). Our hardcoded demo email was `demo@petstore.local`.

**Fix:** Change to `demo@example.com`. The `example.com` domain is IANA-reserved specifically for documentation/demos.

**TAM lesson:** strict validators are great for production but a footgun in demos. Customers' staging environments often use `.local`, `.test`, or `.invalid` and hit similar issues.

### Issue: Phantom folders with `{...}` in their names

**Symptom:** After extracting tarball, weird folders like `{db,services` exist.

**Cause:** Bash brace expansion (`mkdir services/{a,b,c}`) doesn't work in all shells. When it fails to expand, you get one literal folder with the brace syntax in its name.

**Fix:** `rm -rf "{db,services"`. Quote special characters when working with such filenames.

**TAM lesson:** when extracting customer artifacts, always run `find . -name "*{*" -o -name "*,*"` to catch shell-expansion bugs early.

### Issue: macOS adds `.DS_Store` to your repo

**Cause:** macOS Finder creates `.DS_Store` metadata files in any folder you open. They're not part of your project.

**Fix:** Add `.DS_Store` to `.gitignore` (already done in this project). To clean existing ones: `find . -name ".DS_Store" -delete`.

---

# Phase 2 — Add OpenTelemetry Zero-Code Instrumentation

**Goal:** Each service emits traces, metrics, and logs via OpenTelemetry. A local OTEL Collector receives them and prints to stdout.

**Branch:** `instrumented` (branch off `main`)

## What "zero-code instrumentation" actually means

OTEL provides language-specific agents/launchers that automatically wrap your app's framework calls (HTTP servers, HTTP clients, DB drivers, async runtimes) and emit spans/metrics/logs. **You don't change your application code.** You just run your app *through* the OTEL launcher.

| Language | Mechanism | Coverage |
|----------|-----------|----------|
| **Python** | `opentelemetry-instrument python main.py` | Excellent — most popular libs supported |
| **Node.js** | `node --require @opentelemetry/auto-instrumentations-node/register app.js` | Excellent |
| **Java** | `-javaagent:opentelemetry-javaagent.jar` | Best in class |
| **Go** | ⚠️ Different — Go compiles to a static binary; no runtime monkey-patching. Standard practice is **manual SDK wiring** (~80 lines of boilerplate). | Limited zero-code |

For our app:
- ✅ Zero-code: Node services (frontend, catalog) and Python services (api-gateway, orders)
- ✏️ Minimal manual: Go service (payments) — about 80 lines of OTEL setup in `otel.go`, no business logic changes

## Step 1: Branch off

```bash
cd petstore-otel-demo
git checkout -b instrumented
```

This keeps `main` as the "vanilla" reference. All Phase 2/3 changes happen here.

## Step 2: The OTEL Collector

The Collector is a separate container that:
1. **Receives** telemetry from your apps (via OTLP, the OTEL native protocol)
2. **Processes** it (batches, enriches, samples, redacts)
3. **Exports** to one or more backends

Why a Collector instead of having apps export directly to Coralogix?

- Apps don't need to know about Coralogix (or any backend). They speak OTLP.
- Centralized config — change exporter once, all apps benefit.
- Buffering, retries, batching handled in one place.
- API keys never live in app containers — security win.
- You can send the same data to multiple backends without app changes.

This is the **gateway pattern**. Same as ECS sidecars or K8s DaemonSets in production.

## Step 3: Add the Collector to docker-compose

```yaml
otel-collector:
  image: otel/opentelemetry-collector-contrib:0.111.0
  command: ["--config=/etc/otelcol/config.yaml"]
  volumes:
    - ./otel/collector-config.yaml:/etc/otelcol/config.yaml:ro
  ports:
    - "4317:4317"   # OTLP gRPC
    - "4318:4318"   # OTLP HTTP
    - "8888:8888"   # Collector self-metrics
    - "13133:13133" # health_check
  environment:
    CORALOGIX_PRIVATE_KEY: ${CORALOGIX_PRIVATE_KEY}  # populated in Phase 3
```

Pin a specific version (`0.111.0`), not `:latest`. OTEL Collector has frequent breaking changes between minor versions.

## Step 4: Configure each service to export OTLP to the Collector

Add these environment variables to **every** app service in `docker-compose.yml`:

```yaml
environment:
  OTEL_SERVICE_NAME: <service-name>             # e.g. catalog-service
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
  OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
  OTEL_RESOURCE_ATTRIBUTES: "service.namespace=petstore,service.version=1.0.0"
  OTEL_LOGS_EXPORTER: otlp
  OTEL_TRACES_EXPORTER: otlp
  OTEL_METRICS_EXPORTER: otlp
```

These are the OTEL spec's standard environment variables. Every SDK reads them. Customers can switch SDK versions or even languages without changing config.

For Node services, also add:

```yaml
NODE_OPTIONS: "--require @opentelemetry/auto-instrumentations-node/register"
```

## Step 5: Per-language changes

### Python services (api-gateway, orders-service)

Add to `requirements.txt`:

```
opentelemetry-distro==0.49b2
opentelemetry-exporter-otlp==1.28.2
opentelemetry-instrumentation-fastapi==0.49b2
opentelemetry-instrumentation-httpx==0.49b2
opentelemetry-instrumentation-psycopg==0.49b2
opentelemetry-instrumentation-logging==0.49b2
```

Modify `Dockerfile`:

```dockerfile
RUN pip install --no-cache-dir -r requirements.txt
RUN opentelemetry-bootstrap -a install   # auto-discovers and installs missing instrumentations

# THE key change: prefix the entrypoint with opentelemetry-instrument
CMD ["opentelemetry-instrument", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
```

That's it. The launcher monkey-patches FastAPI, httpx, psycopg, and the logging module at import time.

### Node services (frontend, catalog-service)

Add to `package.json`:

```json
{
  "dependencies": {
    "@opentelemetry/api": "^1.9.0",
    "@opentelemetry/auto-instrumentations-node": "^0.53.0",
    "@opentelemetry/exporter-trace-otlp-http": "^0.55.0",
    "@opentelemetry/exporter-logs-otlp-http": "^0.55.0",
    "@opentelemetry/exporter-metrics-otlp-http": "^0.55.0",
    "@opentelemetry/sdk-node": "^0.55.0"
  }
}
```

The Dockerfile doesn't change — `NODE_OPTIONS` injected via docker-compose does the work.

### Go service (payments-service)

Go is the exception — manual instrumentation. Create `services/payments-service/otel.go` with SDK setup that:

1. **Sets the global propagator to W3C TraceContext** (this is the #1 missed step)
2. Creates resource (from env vars)
3. Builds trace, metric, and log providers
4. Registers them globally

Modify `main.go`:

```go
import (
    otelslog "go.opentelemetry.io/contrib/bridges/otelslog"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// Initialize OTEL before anything else
shutdown, err := initOTel(ctx)
defer shutdown(ctx)

// Wire slog through OTEL bridge
otelHandler := otelslog.NewHandler("payments-service")
logger = slog.New(teeHandler{stdoutHandler, otelHandler})

// Wrap the HTTP mux with otelhttp
instrumented := otelhttp.NewHandler(mux, "payments-service")
http.ListenAndServe(":"+port, instrumented)
```

See `services/payments-service/otel.go` and `main.go` in this repo for the complete implementation.

## Step 6: Build and run

```bash
docker compose up --build
```

First build takes 5–10 minutes (lots of OTEL packages to install across languages).

## Step 7: Verify telemetry is flowing

In a second terminal:

```bash
docker compose logs -f otel-collector
```

Click Buy on a pet. You should see a wall of OTEL output — spans, metrics, log records — printed to stdout.

For deeper verification, copy the diagnostic scripts from this repo (`otel-diagnostics.sh`, `trace-flow-check.sh`) and run them. They'll show you span counts per service, trace context propagation, and signal type breakdowns.

## Common Phase 2 issues (and fixes)

### Issue: Go service emits its own trace IDs, doesn't join distributed traces

**Symptom:** All other services share a trace ID for one Buy, but payments-service shows its own unrelated trace IDs.

**Cause:** In Go, the global propagator must be **explicitly set**. By default it's empty, meaning `otelhttp` extracts headers but doesn't know what format to look for.

**Fix:** In `otel.go`:

```go
otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
    propagation.TraceContext{}, // W3C traceparent header
    propagation.Baggage{},      // W3C baggage header
))
```

**TAM lesson — memorize this one:** *"Customer's traces show 4 services in the trace, but the 5th appears with its OWN unrelated trace IDs. Bug: missing `otel.SetTextMapPropagator()` call in their Go (or sometimes Java) service."*

This is the #1 most common Go OTEL bug. You'll diagnose it many times.

### Issue: After `git pull` or config change, behavior doesn't match Dockerfile

**Symptom:** You changed your Dockerfile but the container still behaves the old way.

**Cause:** Docker reuses cached image layers. Even with `docker compose up --build`, sometimes layers don't get invalidated.

**Fix:** Force full rebuild:

```bash
docker compose build --no-cache
docker compose up -d
```

**TAM lesson:** when container behavior doesn't match the Dockerfile, you're running an old image. Always confirm with `--no-cache` rebuild before deeper debugging.

---

# Phase 3 — Connect to Coralogix

**Goal:** Telemetry flows from your apps → Collector → Coralogix UI.

**Apps don't change.** Only the Collector config changes.

## Step 1: Get your Coralogix details

1. **Region domain** — based on your account URL:

| Coralogix URL | Domain to use |
|---|---|
| `app.coralogix.com` | `coralogix.com` (US1) |
| `app.coralogix.us` | `coralogix.us` (US2) |
| `app.eu2.coralogix.com` | `eu2.coralogix.com` (EU2) |
| `app.coralogix.in` | `coralogix.in` (AP1 — India) |
| `app.coralogixsg.com` | `coralogixsg.com` (AP2 — Singapore) |

2. **Send-Your-Data API key** — Coralogix UI: top-right user menu → Data Flow → API Keys → create a new key with "Send Data" permission. The key starts with `cxtp_`.

⚠️ **Never commit the API key.** Use the patterns below.

## Step 2: Create `.env` (gitignored)

In project root:

```bash
echo "CORALOGIX_PRIVATE_KEY=cxtp_your_actual_key_here" > .env
```

Verify `.gitignore` excludes it:

```bash
grep -c "^\.env$" .gitignore   # should output 1
git check-ignore -v .env        # should output gitignore line that excludes it
```

Also commit a placeholder `.env.example` for other developers:

```
CORALOGIX_PRIVATE_KEY=cxtp_replace_with_your_send_your_data_api_key
```

## Step 3: Update Collector config with Coralogix exporter

Edit `otel/collector-config.yaml`:

```yaml
exporters:
  coralogix:
    domain: "eu2.coralogix.com"                # YOUR REGION
    private_key: "${env:CORALOGIX_PRIVATE_KEY}"

    # REQUIRED: static defaults (validation fails without these)
    application_name: "petstore"
    subsystem_name: "default"

    # Dynamic mapping (overrides defaults when attributes are present)
    application_name_attributes:
      - "service.namespace"     # apps set this to "petstore"
    subsystem_name_attributes:
      - "service.name"          # e.g. "orders-service"

    timeout: "30s"
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [resource, batch]
      exporters: [coralogix]    # add coralogix to all 3 pipelines

    metrics:
      receivers: [otlp]
      processors: [resource, batch]
      exporters: [coralogix]

    logs:
      receivers: [otlp]
      processors: [resource, batch]
      exporters: [coralogix]
```

**Coralogix's Application/Subsystem model** is a 2-level hierarchy for organizing telemetry. Common patterns:

| Pattern | Application | Subsystem | When |
|---------|-------------|-----------|------|
| Per-app, per-service | `petstore`, `bookstore` | `frontend`, `orders` | Multi-app environments |
| Per-environment, per-service | `production`, `staging` | `petstore-orders` | Single team, multiple envs |
| Per-team, per-service | `payments-team` | `<service>` | Team-based ownership |

We use the first pattern. The `service.namespace=petstore` resource attribute set on each app routes correctly without changes when you add a `bookstore` app later.

## Step 4: Force recreation of the Collector

```bash
docker compose down
docker compose up -d
```

`down` then `up` is the bulletproof reload — Docker's volume-mounted config files don't always trigger container recreation.

## Step 5: Verify the Coralogix exporter loaded

```bash
docker compose logs otel-collector 2>&1 | grep "exporter"
```

You want to see lines like:

```
{"kind": "exporter", "data_type": "logs",    "name": "coralogix"}
{"kind": "exporter", "data_type": "traces",  "name": "coralogix"}
{"kind": "exporter", "data_type": "metrics", "name": "coralogix"}
```

If you only see `name: "debug"`, the Coralogix exporter is NOT loading. Check `application_name`/`subsystem_name` are set (validation requires them) and that `${env:CORALOGIX_PRIVATE_KEY}` resolves (the env var is reaching the container).

## Step 6: Generate load and verify export

```bash
# Generate 30 orders
for i in $(seq 1 30); do
  curl -s -X POST http://localhost:3000/api/orders \
    -H "Content-Type: application/json" \
    -d "{\"pet_id\": $((RANDOM % 8 + 1)), \"quantity\": 1, \"customer_email\": \"verify$i@example.com\"}" \
    > /dev/null
done
echo "Done"

sleep 8

# Check Collector self-metrics — these come from port 8888
curl -s http://localhost:8888/metrics | grep -E "otelcol_exporter_(sent|send_failed)" | sort
```

What you want to see:

```
otelcol_exporter_send_failed_log_records  {exporter="coralogix"} 0
otelcol_exporter_send_failed_metric_points{exporter="coralogix"} 0
otelcol_exporter_send_failed_spans        {exporter="coralogix"} 0
otelcol_exporter_sent_log_records         {exporter="coralogix"} 143
otelcol_exporter_sent_metric_points       {exporter="coralogix"} 388
otelcol_exporter_sent_spans               {exporter="coralogix"} 1167
```

`sent_*` numbers > 0 with `send_failed_*` = 0 means **data is being accepted by Coralogix.**

## Step 7: Find your data in the Coralogix UI

1. Open the Coralogix UI for your region (e.g. https://app.eu2.coralogix.com)
2. Hard-refresh: `Cmd+Shift+R`
3. Set time picker to **"Last 15 minutes"** (most common gotcha — narrow time picker hides recent data)
4. Don't apply filters yet — see what's there
5. Look at the Application dropdown — you should see `petstore`
6. Visit each signal view:
   - **Logs** — JSON log lines from all 5 services
   - **APM/Tracing** — distributed traces; click one to see the waterfall across services
   - **Custom Metrics / Metrics Explorer** — histograms like `http_server_duration`

## Common Phase 3 issues (and fixes)

### Issue: `exporters::coralogix: \`application_name\` not specified`

**Symptom:** Collector refuses to start with this validation error.

**Cause:** The Coralogix exporter requires `application_name` and `subsystem_name` as static fallbacks even if you set the `*_attributes` dynamic mappings.

**Fix:** Add `application_name: "petstore"` and `subsystem_name: "default"` to the exporter config.

### Issue: Container has new config file but loads old config

**Symptom:** You changed `collector-config.yaml`, restarted with `docker compose up -d --force-recreate`, but the new exporter doesn't load.

**Cause:** Even `--force-recreate` sometimes reuses cached state.

**Fix:** Full down/up:

```bash
docker compose down
docker compose up -d
```

### Issue: `.env` not reaching the Collector container

**Symptom:** Coralogix exporter loads but reports auth failures, OR `${env:CORALOGIX_PRIVATE_KEY}` resolves to empty.

**Diagnostic:**

```bash
docker inspect petstore-otel-demo-otel-collector-1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep CORALOGIX_PRIVATE_KEY \
  | awk -F= '{print "Length:", length($2)}'
```

A length of 0 means env var is empty in the container.

**Fix:** Verify:
1. `.env` is in the project root (same directory as `docker-compose.yml`)
2. Format is `CORALOGIX_PRIVATE_KEY=cxtp_...` (no quotes, no spaces around `=`)
3. The Collector service in `docker-compose.yml` has `environment: CORALOGIX_PRIVATE_KEY: ${CORALOGIX_PRIVATE_KEY}`

### Issue: `sent_*` counters all zero, no errors

**Symptom:** Collector starts cleanly, no errors, but exporter counters stay at 0.

**Cause:** Apps aren't sending to the Collector. Common reasons:
- Apps started before Collector was ready
- Apps are running old (pre-Phase-2) images that don't have OTEL packages installed
- `OTEL_EXPORTER_OTLP_ENDPOINT` not set in app env

**Diagnostic:**

```bash
docker compose ps -a    # check ALL containers, including exited ones
```

If frontend or catalog show `Exited (1)` with `Cannot find module '@opentelemetry/auto-instrumentations-node/register'` in their logs → cached image without OTEL packages.

**Fix:**

```bash
docker compose down
docker compose build --no-cache
docker compose up -d
```

### Issue: Misreading `sent` vs `send_failed`

**Symptom:** Customer says "my data isn't reaching Coralogix" but their `sent_spans` is 1167.

**Cause:** The metric names look similar — `sent_*` (success) and `send_failed_*` (failure). Easy to confuse.

**Memorize:** `*_sent_*` = successful sends. `*_send_failed_*` = unsuccessful sends. Both are counters; both can grow simultaneously.

### Issue: Data is in Coralogix but UI shows nothing

**Cause:** UI filters/time-range issue, not a transmission issue. If `sent_*` is growing and `send_failed_*` is 0, the data IS in Coralogix.

**Fix:**
1. Time picker → "Last 15 minutes" (default is often "Last 5 min")
2. Clear all filters
3. Check Application dropdown for what's actually there
4. Hard refresh: `Cmd+Shift+R`

---

# Understanding Severity in OTEL

A topic that catches every customer off-guard. Worth a dedicated section.

## OTEL's severity model

Two fields per log record:
- `SeverityNumber` (1–24) — machine-comparable scale
- `SeverityText` (string) — human-readable label

The 24 levels group into 6 classes:

| Range  | Class | Common name |
|--------|-------|-------------|
| 1–4    | TRACE | trace       |
| 5–8    | DEBUG | debug       |
| 9–12   | INFO  | info        |
| 13–16  | WARN  | warn        |
| 17–20  | ERROR | error       |
| 21–24  | FATAL | fatal       |

## Where severity comes from

In order of priority:

1. **Your code's logger call.** `log.error(...)` → SeverityNumber 17. `log.info(...)` → 9.
2. **The SDK's mapping** of language-native levels (Python `logging`, Node `pino`, Go `slog`) to OTEL numbers.
3. **Collector processors** can rewrite severity if needed (escape hatch for legacy apps).

**OTEL doesn't infer severity from message content.** If you call `log.info("DB connection failed")`, it's INFO. Severity comes from the call, not the words.

## Coralogix mapping

The Coralogix exporter maps OTEL classes to Coralogix's 1–6 severity scale:

| OTEL Class | Coralogix severity | Label |
|------------|--------------------|-------|
| TRACE/DEBUG| 1                  | Debug |
| INFO       | 3                  | Info  |
| WARN       | 4                  | Warning |
| ERROR      | 5                  | Error |
| FATAL      | 6                  | Critical |

Automatic — no configuration needed.

## Common severity pitfalls

| Pitfall | What customers see | Fix |
|---------|---------------------|-----|
| All logs land at INFO | "We never see ERRORs" | App uses `print()` instead of a real logger |
| Everything is ERROR | "Everything looks broken" | stderr captured as ERROR by default; use JSON logs with explicit `level` field |
| Severity vs message text | "I logged 'failure' but it shows INFO" | OTEL trusts the logger call. The message is opaque to severity. |
| Span status confused with log severity | "Why does my OK trace contain ERRORs?" | Different concepts — a trace can succeed with intermediate errors (retries) |

---

# Repository Layout (after Phase 3)

```
petstore-otel-demo/
├── .env                          # GITIGNORED — your real Coralogix key
├── .env.example                  # template, committed
├── .gitignore
├── docker-compose.yml            # all 7 services + load profile
├── README.md
├── coralogix-check.sh            # Phase 3 verification script
├── otel-diagnostics.sh           # Phase 2 diagnostic script
├── trace-flow-check.sh           # Phase 2 trace propagation verification
├── db/
│   └── init.sql
├── docs/
│   └── GUIDE.md                  # this file
├── otel/
│   └── collector-config.yaml     # Phase 2/3 Collector config
└── services/
    ├── api-gateway/              # Python + OTEL
    ├── catalog-service/          # Node + OTEL
    ├── frontend/                 # Node + OTEL
    ├── load-generator/           # Locust
    ├── orders-service/           # Python + OTEL
    └── payments-service/         # Go + manual OTEL (otel.go)
```

---

# Quick Reference Commands

```bash
# Start everything
docker compose up -d

# Tail all logs
docker compose logs -f

# Tail specific service
docker compose logs -f orders-service

# Check container status
docker compose ps -a              # -a includes stopped/crashed

# Restart one service
docker compose restart payments-service

# Force rebuild after code/Dockerfile change
docker compose build --no-cache <service>
docker compose up -d

# Full reset (DESTROYS DB DATA)
docker compose down -v
docker compose up --build

# Generate load
for i in $(seq 1 30); do
  curl -s -X POST http://localhost:3000/api/orders \
    -H "Content-Type: application/json" \
    -d "{\"pet_id\": $((RANDOM % 8 + 1)), \"quantity\": 1, \"customer_email\": \"loadgen$i@example.com\"}" \
    > /dev/null
done

# Continuous load (Locust)
docker compose --profile load up -d load-generator
docker compose --profile load down load-generator     # stop it

# Check Coralogix exporter health
curl -s http://localhost:8888/metrics | grep -E "otelcol_exporter_(sent|send_failed)"

# Verify trace propagation across services
./trace-flow-check.sh
```

---

# Tuning the Chaos

The payments service has two env vars to adjust failure modes:

| Variable | Default | Effect |
|----------|---------|--------|
| `FAILURE_RATE` | `0.10` | Fraction of charges that get declined (0.0–1.0) |
| `MAX_LATENCY_MS` | `800` | Upper bound of normal processing latency. ~5% of calls also get an extra 1.5–3.5s "slow tail" added to demo p99 latency anomaly detection. |

Change in `docker-compose.yml` and restart payments-service.

For demo scenarios:
- **Healthy demo:** `FAILURE_RATE=0.05`, `MAX_LATENCY_MS=300`
- **Incident demo:** `FAILURE_RATE=0.50`, `MAX_LATENCY_MS=2000` (then drop back to defaults to "fix")
- **Latency demo:** `FAILURE_RATE=0.0`, `MAX_LATENCY_MS=3000` (just slow, no errors)

---

# What's Next

## Phase 4 — Deploy to AWS ECS on EC2 Spot

*(coming next)*

ECS task definitions translate cleanly from `docker-compose.yml`. Plans:
- Single VPC with public + private subnets
- ECS cluster on EC2 Auto Scaling Group with Spot capacity provider
- ECR repos for each service image (multi-arch builds for ARM64 if using Graviton)
- ALB in front of frontend
- AWS Secrets Manager for `CORALOGIX_PRIVATE_KEY`
- CloudWatch + Coralogix dual ingestion as a "before/after" demo

## Phase 5 — Deploy to EKS

*(later)*

The "real" production setup:
- EKS cluster (managed control plane)
- Coralogix Helm chart (`otel-integration`) for the Collector as DaemonSet + Cluster Collector
- Apps deployed as Deployments with the OTEL Operator handling auto-instrumentation injection
- ServiceAccount + Secrets for the API key
- Demonstrates the K8s-native observability story end-to-end

---

# A Final Word — TAM Lessons From Building This

Things you internalize after building this app from scratch:

1. **Observability without diligent severity is just noise.** Apps must use real loggers and call appropriate methods. OTEL doesn't infer.

2. **The OTEL Collector is the integration point, not the apps.** Apps speak OTLP. The Collector decides where data goes. Customers can switch backends without app changes.

3. **Go's manual instrumentation has one gotcha that catches everyone.** `otel.SetTextMapPropagator()` is mandatory for distributed tracing. Memorize this.

4. **Image cache is the most subtle bug source in containerized stacks.** When behavior doesn't match Dockerfile/config, suspect cached images. `--no-cache` is your friend.

5. **`docker compose ps -a` before debugging anything.** A crashed container is invisible in regular `ps`. Always check stopped containers first.

6. **`sent_*` ≠ `send_failed_*`.** Read metric names character by character. Customers misread these constantly.

7. **Time pickers hide more data than wrong configs do.** Always start with "Last 1 hour" and zero filters before assuming your data isn't there.

These six are the most useful muscle-memory tools you'll have as a Coralogix TAM. Each one will save you hours per customer engagement.
