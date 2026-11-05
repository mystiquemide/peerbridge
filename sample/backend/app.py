"""Dev A's in-progress backend: one checkout endpoint on loopback."""

import os
import time

from fastapi import FastAPI, Request
from pydantic import BaseModel, Field

ACCESS_LOG = os.environ.get("PEERBRIDGE_ACCESS_LOG", "access.log")

app = FastAPI(title="sample-backend")


class LineItem(BaseModel):
    sku: str
    quantity: int = Field(gt=0)


class CheckoutRequest(BaseModel):
    amount_cents: int = Field(gt=0)
    currency: str = Field(min_length=3, max_length=3)
    items: list[LineItem] = Field(min_length=1)


@app.middleware("http")
async def access_log(request: Request, call_next):
    started = time.monotonic()
    response = await call_next(request)
    ms = (time.monotonic() - started) * 1000
    client = request.client.host if request.client else "-"
    line = (
        f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())}Z {client} "
        f"{request.method} {request.url.path} -> {response.status_code} {ms:.1f}ms"
    )
    print(line, flush=True)
    with open(ACCESS_LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    return response


@app.post("/v2/checkout")
def checkout(order: CheckoutRequest) -> dict:
    return {
        "status": "accepted",
        "amount_cents": order.amount_cents,
        "currency": order.currency.upper(),
        "items": len(order.items),
    }


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
