"""Small proxy in front of vLLM on tassan: makes PDFs readable by the lab model.

When Claude Code reads a PDF (Read tool, @file.pdf, drag and drop), it sends it as an Anthropic
`document` content block. vLLM's /v1/messages doesn't accept that block type and rejects the whole
request with a 400; since the PDF stays in the history, every later request of the session fails too
(issue #4). This proxy rewrites each `document` block into blocks vLLM accepts:
  - the text of every page (pypdfium2),
  - and, when the model has a vision encoder, an image of the pages that hold figures or no text
    (scanned pages), so figures aren't lost.
Everything else (other paths, other block types, streamed answers) goes through unchanged.

Settings (environment, set by serve_vllm.sh from vllm.env):
  DOC_PROXY_PORT      where clients connect (default 8000, the port the tunnels use)
  VLLM_URL            vLLM behind it (default http://127.0.0.1:8010)
  PDF_PAGE_IMAGES     auto (images if the model has a vision encoder), 1 or 0
  PDF_MAX_IMAGES      most page images per document (default 12)
  PDF_IMAGE_PX        longest side of a page image, in pixels (default 1024)
  MODEL, HF_HOME      to find the model's config.json for "auto"
"""
import base64
import glob
import hashlib
import io
import json
import os
from collections import OrderedDict

import httpx
from starlette.applications import Starlette
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool
from starlette.requests import Request
from starlette.responses import StreamingResponse
from starlette.routing import Route

PORT = int(os.environ.get("DOC_PROXY_PORT", "8000"))
UPSTREAM = os.environ.get("VLLM_URL", "http://127.0.0.1:8010").rstrip("/")
MAX_IMAGES = int(os.environ.get("PDF_MAX_IMAGES", "12"))
IMAGE_PX = int(os.environ.get("PDF_IMAGE_PX", "1024"))
REWRITE_PATHS = ("/v1/messages", "/v1/messages/count_tokens")
# Not forwarded as is: the HTTP client and server set them for each hop.
HOP_HEADERS = {"host", "content-length", "transfer-encoding", "connection", "keep-alive"}


def model_has_vision() -> bool:
    """For PDF_PAGE_IMAGES=auto: does the served model's config.json declare a vision encoder?"""
    model, hf_home = os.environ.get("MODEL", ""), os.environ.get("HF_HOME", "")
    pattern = os.path.join(hf_home, "hub", "models--" + model.replace("/", "--"), "snapshots", "*", "config.json")
    for path in glob.glob(pattern):
        try:
            cfg = json.load(open(path))
        except (OSError, ValueError):
            continue
        return "vision_config" in cfg or "image_token_id" in cfg or "vision_start_token_id" in cfg
    return False


setting = os.environ.get("PDF_PAGE_IMAGES", "auto").lower()
PAGE_IMAGES = model_has_vision() if setting == "auto" else setting in ("1", "true", "yes")


# --- PDF to blocks ----------------------------------------------------------------------------

def _page_wants_image(page, text: str) -> bool:
    """Render a page when text alone would lose something: it has a picture, many vector paths
    (plots, diagrams), or almost no text (a scan)."""
    import pypdfium2.raw as pdfium_c
    images = paths = 0
    for obj in page.get_objects():
        if obj.type == pdfium_c.FPDF_PAGEOBJ_IMAGE:
            images += 1
        elif obj.type == pdfium_c.FPDF_PAGEOBJ_PATH:
            paths += 1
    return images > 0 or paths > 50 or len(text.strip()) < 200


def _render(page) -> str:
    width, height = page.get_size()   # in points (1/72 inch)
    pil = page.render(scale=IMAGE_PX / max(width, height)).to_pil().convert("RGB")
    buf = io.BytesIO()
    pil.save(buf, format="JPEG", quality=80)
    return base64.b64encode(buf.getvalue()).decode()


def pdf_to_blocks(data: bytes, title: str, with_images: bool) -> list:
    import pypdfium2 as pdfium
    try:
        pdf = pdfium.PdfDocument(data)
    except Exception as e:  # encrypted, corrupt, not a PDF
        return [{"type": "text", "text": f"[{title}: this PDF could not be read ({type(e).__name__}).]"}]
    pages, rendered, skipped = [], [], 0
    for i in range(len(pdf)):
        page = pdf[i]
        text = page.get_textpage().get_text_range()
        pages.append(f"--- page {i + 1} ---\n{text.strip()}")
        if with_images and _page_wants_image(page, text):
            if len(rendered) < MAX_IMAGES:
                rendered.append((i + 1, _render(page)))
            else:
                skipped += 1
    note = ""
    if rendered:
        note = f"\n[Images of pages {', '.join(str(n) for n, _ in rendered)} follow, for their figures.]"
    if skipped:
        note += f"\n[{skipped} more pages have figures; ask to see a page range of the PDF to get them.]"
    if not with_images:
        note = "\n[Text only: figures in this PDF are not shown to the model.]"
    blocks = [{"type": "text", "text": f"<document title=\"{title}\" pages=\"{len(pdf)}\">\n"
               + "\n\n".join(pages) + f"\n</document>{note}"}]
    for n, jpeg in rendered:
        blocks.append({"type": "text", "text": f"[{title}, page {n}]"})
        blocks.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": jpeg}})
    return blocks


# Each turn resends the whole history, so the same PDF comes back on every request: convert it once.
# Identical output each time also keeps vLLM's prefix cache hitting.
_cache: "OrderedDict[str, list]" = OrderedDict()


def document_to_blocks(block: dict) -> list:
    source = block.get("source") or {}
    title = block.get("title") or "document"
    kind = source.get("type")
    if kind == "base64" and source.get("media_type") == "application/pdf":
        data = base64.b64decode(source.get("data", ""))
        key = hashlib.sha256(data).hexdigest() + f":{PAGE_IMAGES}:{MAX_IMAGES}:{IMAGE_PX}:{title}"
        if key not in _cache:
            _cache[key] = pdf_to_blocks(data, title, PAGE_IMAGES)
            print(f"converted PDF '{title}' ({len(data) // 1024} KB) into {len(_cache[key])} blocks", flush=True)
            while len(_cache) > 32:
                _cache.popitem(last=False)
        _cache.move_to_end(key)
        return _cache[key]
    if kind == "text":
        return [{"type": "text", "text": f"<document title=\"{title}\">\n{source.get('data', '')}\n</document>"}]
    if kind == "content":
        inner = source.get("content")
        if isinstance(inner, str):
            return [{"type": "text", "text": inner}]
        return [b for b in inner or [] if isinstance(b, dict) and b.get("type") in ("text", "image")]
    if kind == "base64":
        try:
            text = base64.b64decode(source.get("data", "")).decode()
        except (ValueError, UnicodeDecodeError):
            text = None
        if text is not None:
            return [{"type": "text", "text": f"<document title=\"{title}\">\n{text}\n</document>"}]
    return [{"type": "text", "text": f"[{title}: a {source.get('media_type') or kind} document the lab server can't read.]"}]


def rewrite_blocks(blocks: list) -> tuple[list, int]:
    """Replace document blocks in a content list, also inside tool_result contents. Returns the new
    list and how many documents were replaced."""
    out, count = [], 0
    for b in blocks:
        if isinstance(b, dict) and b.get("type") == "document":
            out.extend(document_to_blocks(b))
            count += 1
            continue
        if isinstance(b, dict) and b.get("type") == "tool_result" and isinstance(b.get("content"), list):
            inner, n = rewrite_blocks(b["content"])
            if n:
                b = {**b, "content": inner}
                count += n
        out.append(b)
    return out, count


def rewrite_payload(payload: dict) -> int:
    count = 0
    for msg in payload.get("messages") or []:
        if isinstance(msg, dict) and isinstance(msg.get("content"), list):
            msg["content"], n = rewrite_blocks(msg["content"])
            count += n
    return count


# --- the proxy ------------------------------------------------------------------------------

client = httpx.AsyncClient(timeout=httpx.Timeout(None, connect=10))


async def forward(request: Request):
    body = await request.body()
    if request.method == "POST" and request.url.path in REWRITE_PATHS and b'"document"' in body:
        try:
            payload = json.loads(body)
        except ValueError:
            payload = None
        if isinstance(payload, dict) and await run_in_threadpool(rewrite_payload, payload):
            body = json.dumps(payload).encode()
    headers = [(k, v) for k, v in request.headers.items() if k.lower() not in HOP_HEADERS]
    upstream = client.build_request(request.method, UPSTREAM + request.url.path,
                                    params=request.url.query or None, headers=headers, content=body)
    try:
        r = await client.send(upstream, stream=True)
    except httpx.TransportError:
        return StreamingResponse(iter([b'{"type":"error","error":{"type":"api_error","message":"vLLM is not answering behind the lab proxy (starting, or stopped)."}}']),
                                 status_code=503, media_type="application/json")
    resp_headers = {k: v for k, v in r.headers.items() if k.lower() not in HOP_HEADERS}
    return StreamingResponse(r.aiter_raw(), status_code=r.status_code, headers=resp_headers,
                             background=BackgroundTask(r.aclose))


app = Starlette(routes=[Route("/{path:path}", forward, methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"])])


def main():
    import uvicorn
    print(f"doc proxy on 127.0.0.1:{PORT} -> {UPSTREAM} (page images: {'on' if PAGE_IMAGES else 'off'})", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")


if __name__ == "__main__":
    main()
