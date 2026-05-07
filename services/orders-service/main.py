"""
orders-service: orchestrates an order.
Flow when POST /orders is called:
  1. Look up the pet via catalog-service  (HTTP)
  2. Reserve stock via catalog-service    (HTTP)
  3. Charge payment via payments-service  (HTTP)
  4. Insert the order row into Postgres   (DB)
This produces a nice multi-hop trace when we instrument it later.
"""

import os
import logging
import sys
from contextlib import asynccontextmanager

import httpx
import psycopg
import structlog
from fastapi import FastAPI, HTTPException
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, EmailStr

# --- Structured logging configuration ---
# We pipe stdlib logging through structlog so that uvicorn's logs are also JSON.
logging.basicConfig(format="%(message)s", stream=sys.stdout, level=logging.INFO)
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
)
log = structlog.get_logger()

# --- Config from env ---
DB_DSN = (
    f"host={os.getenv('DB_HOST', 'postgres')} "
    f"port={os.getenv('DB_PORT', '5432')} "
    f"user={os.getenv('DB_USER', 'petstore')} "
    f"password={os.getenv('DB_PASSWORD', 'petstore')} "
    f"dbname={os.getenv('DB_NAME', 'petstore')}"
)
CATALOG_URL = os.getenv("CATALOG_URL", "http://catalog-service:3001")
PAYMENTS_URL = os.getenv("PAYMENTS_URL", "http://payments-service:8080")

# --- Lifespan: set up shared resources (DB pool, HTTP client) on startup ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.db_pool = ConnectionPool(conninfo=DB_DSN, min_size=2, max_size=10, open=True)
    app.state.http_client = httpx.AsyncClient(timeout=10.0)
    log.info("orders_service_started")
    yield
    app.state.db_pool.close()
    await app.state.http_client.aclose()


app = FastAPI(lifespan=lifespan)


class CreateOrderRequest(BaseModel):
    pet_id: int
    quantity: int = 1
    customer_email: EmailStr


@app.get("/health")
async def health():
    return {"status": "ok", "service": "orders"}


@app.get("/orders/{order_id}")
async def get_order(order_id: int):
    with app.state.db_pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, pet_id, quantity, total_cents, status, customer_email, created_at "
                "FROM orders WHERE id = %s",
                (order_id,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="order not found")
            return {
                "id": row[0], "pet_id": row[1], "quantity": row[2],
                "total_cents": row[3], "status": row[4],
                "customer_email": row[5], "created_at": row[6].isoformat(),
            }


@app.post("/orders")
async def create_order(req: CreateOrderRequest):
    log_ctx = log.bind(pet_id=req.pet_id, quantity=req.quantity, customer=req.customer_email)
    log_ctx.info("create_order_started")

    client: httpx.AsyncClient = app.state.http_client

    # Step 1: get pet info (price, existence)
    try:
        r = await client.get(f"{CATALOG_URL}/pets/{req.pet_id}")
        if r.status_code == 404:
            log_ctx.warn("pet_not_found")
            raise HTTPException(status_code=404, detail="pet not found")
        r.raise_for_status()
        pet = r.json()
    except httpx.HTTPError as e:
        log_ctx.error("catalog_lookup_failed", error=str(e))
        raise HTTPException(status_code=502, detail="catalog service unreachable")

    total_cents = pet["price_cents"] * req.quantity

    # Step 2: reserve stock
    try:
        r = await client.post(
            f"{CATALOG_URL}/pets/{req.pet_id}/reserve",
            json={"quantity": req.quantity},
        )
        if r.status_code == 409:
            log_ctx.warn("insufficient_stock")
            raise HTTPException(status_code=409, detail="insufficient stock")
        r.raise_for_status()
    except httpx.HTTPError as e:
        log_ctx.error("reservation_failed", error=str(e))
        raise HTTPException(status_code=502, detail="reservation failed")

    # Step 3: charge payment
    try:
        r = await client.post(
            f"{PAYMENTS_URL}/charge",
            json={"amount_cents": total_cents, "customer_email": req.customer_email},
        )
        if r.status_code != 200:
            log_ctx.error("payment_declined", status=r.status_code)
            # In a real system we'd compensate the stock reservation here.
            raise HTTPException(status_code=402, detail="payment declined")
        payment = r.json()
    except httpx.HTTPError as e:
        log_ctx.error("payment_service_error", error=str(e))
        raise HTTPException(status_code=502, detail="payment service unreachable")

    # Step 4: persist
    try:
        with app.state.db_pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO orders (pet_id, quantity, total_cents, status, customer_email) "
                    "VALUES (%s, %s, %s, %s, %s) RETURNING id",
                    (req.pet_id, req.quantity, total_cents, "confirmed", req.customer_email),
                )
                order_id = cur.fetchone()[0]
                conn.commit()
        log_ctx.info("order_created", order_id=order_id, total_cents=total_cents,
                     payment_id=payment.get("payment_id"))
        return {
            "order_id": order_id, "pet_id": req.pet_id, "quantity": req.quantity,
            "total_cents": total_cents, "status": "confirmed",
            "payment_id": payment.get("payment_id"),
        }
    except psycopg.Error as e:
        log_ctx.error("db_insert_failed", error=str(e))
        raise HTTPException(status_code=500, detail="failed to persist order")
