"""
api-gateway: thin routing layer in front of the backend services.
Exposes a stable public API regardless of how backends evolve.
"""

import os
import logging
import sys
from contextlib import asynccontextmanager

import httpx
import structlog
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware

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

CATALOG_URL = os.getenv("CATALOG_URL", "http://catalog-service:3001")
ORDERS_URL = os.getenv("ORDERS_URL", "http://orders-service:8001")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.client = httpx.AsyncClient(timeout=15.0)
    log.info("api_gateway_started")
    yield
    await app.state.client.aclose()


app = FastAPI(lifespan=lifespan)
# Allow the frontend (running on a different port locally) to call us.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.get("/health")
async def health():
    return {"status": "ok", "service": "api-gateway"}


@app.get("/api/pets")
async def list_pets():
    try:
        r = await app.state.client.get(f"{CATALOG_URL}/pets")
        r.raise_for_status()
        return r.json()
    except httpx.HTTPError as e:
        log.error("catalog_unreachable", error=str(e))
        raise HTTPException(status_code=502, detail="catalog unavailable")


@app.get("/api/pets/{pet_id}")
async def get_pet(pet_id: int):
    try:
        r = await app.state.client.get(f"{CATALOG_URL}/pets/{pet_id}")
        if r.status_code == 404:
            raise HTTPException(status_code=404, detail="pet not found")
        r.raise_for_status()
        return r.json()
    except httpx.HTTPError as e:
        log.error("catalog_unreachable", error=str(e))
        raise HTTPException(status_code=502, detail="catalog unavailable")


@app.post("/api/orders")
async def create_order(req: Request):
    body = await req.json()
    try:
        r = await app.state.client.post(f"{ORDERS_URL}/orders", json=body)
        if r.status_code >= 400:
            log.warn("order_creation_failed", status=r.status_code, body=r.text)
            raise HTTPException(status_code=r.status_code, detail=r.json().get("detail", "order failed"))
        return r.json()
    except httpx.HTTPError as e:
        log.error("orders_unreachable", error=str(e))
        raise HTTPException(status_code=502, detail="orders unavailable")


@app.get("/api/orders/{order_id}")
async def get_order(order_id: int):
    try:
        r = await app.state.client.get(f"{ORDERS_URL}/orders/{order_id}")
        if r.status_code == 404:
            raise HTTPException(status_code=404, detail="order not found")
        r.raise_for_status()
        return r.json()
    except httpx.HTTPError as e:
        log.error("orders_unreachable", error=str(e))
        raise HTTPException(status_code=502, detail="orders unavailable")
