import asyncio
import os
import time
import uuid
from itertools import cycle
from typing import Dict, Iterable, List

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}


def parse_upstream_urls(raw_urls: str) -> List[str]:
    urls = [url.strip().rstrip("/") for url in raw_urls.split(",") if url.strip()]
    if not urls:
        raise ValueError("UPSTREAM_URLS must contain at least one URL")
    return urls


def filter_headers(headers: Iterable[tuple[str, str]]) -> Dict[str, str]:
    return {
        key: value
        for key, value in headers
        if key.lower() not in HOP_BY_HOP_HEADERS
    }


RAW_UPSTREAM_URLS = os.getenv("UPSTREAM_URLS", "http://127.0.0.1:8101,http://127.0.0.1:8102")
UPSTREAM_URLS = parse_upstream_urls(RAW_UPSTREAM_URLS)
REQUEST_TIMEOUT_SECONDS = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "180"))
QUEUE_WAIT_TIMEOUT_SECONDS = float(os.getenv("QUEUE_WAIT_TIMEOUT_SECONDS", "2.5"))
MAX_IN_FLIGHT = int(os.getenv("MAX_IN_FLIGHT", "64"))

app = FastAPI(title="PaddleX FastAPI Gateway", version="1.0.0")
app.state.semaphore = asyncio.Semaphore(MAX_IN_FLIGHT)
app.state.next_upstream = cycle(UPSTREAM_URLS)
app.state.upstream_lock = asyncio.Lock()
app.state.client = None


@app.on_event("startup")
async def on_startup() -> None:
    timeout = httpx.Timeout(REQUEST_TIMEOUT_SECONDS)
    app.state.client = httpx.AsyncClient(timeout=timeout)


@app.on_event("shutdown")
async def on_shutdown() -> None:
    client = app.state.client
    if client is not None:
        await client.aclose()


async def pick_upstream_url() -> str:
    async with app.state.upstream_lock:
        return next(app.state.next_upstream)


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse(
        {
            "status": "ok",
            "upstreams": UPSTREAM_URLS,
            "max_in_flight": MAX_IN_FLIGHT,
        }
    )


@app.api_route("/", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"])
@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"])
async def proxy(full_path: str, request: Request) -> Response:
    started_at = time.perf_counter()
    request_id = request.headers.get("x-request-id", str(uuid.uuid4()))

    try:
        await asyncio.wait_for(app.state.semaphore.acquire(), timeout=QUEUE_WAIT_TIMEOUT_SECONDS)
    except TimeoutError:
        return JSONResponse(
            status_code=429,
            content={
                "error": "server_busy",
                "message": "Too many in-flight requests. Retry shortly.",
                "request_id": request_id,
            },
            headers={"x-request-id": request_id},
        )

    try:
        upstream_base = await pick_upstream_url()
        upstream_url = f"{upstream_base}/{full_path}" if full_path else upstream_base
        body = await request.body()
        forwarded_headers = filter_headers(request.headers.items())

        upstream_response = await app.state.client.request(
            method=request.method,
            url=upstream_url,
            params=request.query_params,
            content=body,
            headers=forwarded_headers,
        )

        response_headers = filter_headers(upstream_response.headers.items())
        response_headers["x-request-id"] = request_id
        response_headers["x-upstream-url"] = upstream_base
        response_headers["x-gateway-latency-ms"] = f"{(time.perf_counter() - started_at) * 1000:.2f}"

        return Response(
            content=upstream_response.content,
            status_code=upstream_response.status_code,
            headers=response_headers,
            media_type=upstream_response.headers.get("content-type"),
        )
    except httpx.HTTPError:
        return JSONResponse(
            status_code=503,
            content={
                "error": "upstream_unavailable",
                "message": "Failed to reach PaddleX worker.",
                "request_id": request_id,
            },
            headers={"x-request-id": request_id},
        )
    finally:
        app.state.semaphore.release()
