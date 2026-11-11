"""Web search for the lab agents: an MCP server (streamable HTTP) on tassan, next to vLLM.

Tools:
  web_search(query, ...)  results from the SearXNG instance on tassan (no API key, no third party)
  fetch(url, ...)         a web page as readable text (markdown), fetched from tassan

Claude Code's own WebSearch runs on Anthropic's servers and can't work with a self-hosted model; this
replaces it. Clients reach it through the same SSH tunnel as vLLM and send the lab key, like for vLLM.

Settings (environment, set by serve_search.sh from vllm.env):
  SEARCH_MCP_PORT   port on 127.0.0.1 (default 8002)
  SEARXNG_URL       the SearXNG instance (default http://127.0.0.1:8888)
  LAB_KEY_FILE      the lab key (default ~/llm-bench/vllm.key)
"""
import ipaddress
import os
import secrets
import socket
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx
import trafilatura
from mcp.server.fastmcp import FastMCP

PORT = int(os.environ.get("SEARCH_MCP_PORT", "8002"))
SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://127.0.0.1:8888").rstrip("/")
KEY_FILE = Path(os.environ.get("LAB_KEY_FILE", Path.home() / "llm-bench" / "vllm.key"))

MAX_PAGE_BYTES = 5_000_000      # stop downloading a page past this
MAX_REDIRECTS = 5
USER_AGENT = "Mozilla/5.0 (compatible; NeuroPoly-lab-agent/1.0; +https://neuro.polymtl.ca)"

mcp = FastMCP(
    "lab-search",
    instructions="Web search and page fetching for the lab's self-hosted model. Use web_search to find "
    "pages, then fetch to read one. Cite the URLs you used.",
    host="127.0.0.1",
    port=PORT,
    stateless_http=True,
    json_response=True,
)


@mcp.tool()
async def web_search(query: str, max_results: int = 8, time_range: str = "", language: str = "auto") -> str:
    """Search the web. Returns titles, URLs and snippets; use fetch to read a page.

    Args:
        query: what to search for, like in a search engine.
        max_results: how many results to return (1 to 20).
        time_range: "" for any time, or "day", "week", "month", "year".
        language: "auto", or a code like "en" or "fr".
    """
    params = {"q": query, "format": "json", "language": language or "auto"}
    if time_range in ("day", "week", "month", "year"):
        params["time_range"] = time_range
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.get(f"{SEARXNG_URL}/search", params=params)
    if r.status_code != 200:
        return f"Search failed: the search engine on tassan answered HTTP {r.status_code}."
    data = r.json()
    results = data.get("results", [])[: max(1, min(max_results, 20))]
    lines = []
    for a in data.get("answers", [])[:2]:
        lines.append(f"Answer: {a if isinstance(a, str) else a.get('answer', '')}")
    for i, res in enumerate(results, 1):
        date = f" ({res['publishedDate'][:10]})" if res.get("publishedDate") else ""
        lines.append(f"{i}. {res.get('title', '').strip()}{date}\n   {res.get('url', '')}\n   {(res.get('content') or '').strip()}")
    if not results:
        lines.append("No results.")
    down = data.get("unresponsive_engines") or []
    if down and not results:
        lines.append("Engines that did not answer: " + ", ".join(e[0] if isinstance(e, list) else str(e) for e in down))
    return "\n".join(lines)


def _public_host(host: str) -> bool:
    """True if every address the host resolves to is public. The server runs on tassan, so a page must
    not be able to make the agent read services that only listen on tassan's own network (loopback,
    private ranges): other users' notebooks, the vLLM server itself."""
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global or ip.is_multicast:
            return False
    return True


@mcp.tool()
async def fetch(url: str, max_chars: int = 20000, start_index: int = 0) -> str:
    """Fetch a web page and return its main text as markdown (scripts, menus and ads removed).

    Args:
        url: the page, http:// or https://.
        max_chars: how much text to return at most.
        start_index: where to start in the text, to read a long page in several calls.
    """
    async with httpx.AsyncClient(timeout=30, follow_redirects=False, headers={"User-Agent": USER_AGENT}) as client:
        for _ in range(MAX_REDIRECTS + 1):
            parsed = urlparse(url)
            if parsed.scheme not in ("http", "https") or not parsed.hostname:
                return f"Cannot fetch {url}: only http:// and https:// URLs."
            if not _public_host(parsed.hostname):
                return f"Cannot fetch {url}: the host does not resolve, or it is a private or local address."
            async with client.stream("GET", url) as r:
                if r.is_redirect and "location" in r.headers:
                    url = urljoin(url, r.headers["location"])
                    continue
                if r.status_code >= 400:
                    return f"Fetching {url} failed: HTTP {r.status_code}."
                body = b""
                async for chunk in r.aiter_bytes():
                    body += chunk
                    if len(body) > MAX_PAGE_BYTES:
                        break
                ctype = r.headers.get("content-type", "")
                encoding = r.encoding or "utf-8"
            break
        else:
            return f"Fetching {url} failed: too many redirects."

    if "html" in ctype or body.lstrip()[:15].lower().startswith((b"<!doctype", b"<html")):
        html = body.decode(encoding, errors="replace")
        text = trafilatura.extract(html, output_format="markdown", include_links=True, include_tables=True, url=url)
        if not text:
            text = trafilatura.html2txt(html)
    elif ctype.startswith("text/") or "json" in ctype or "xml" in ctype:
        text = body.decode(encoding, errors="replace")
    else:
        return f"{url} is not a text page ({ctype or 'unknown type'}); download it with a shell command instead."

    text = (text or "").strip()
    part = text[start_index : start_index + max_chars]
    header = f"URL: {url}\n"
    if start_index + max_chars < len(text):
        header += f"(characters {start_index} to {start_index + len(part)} of {len(text)}: call again with start_index={start_index + len(part)} for more)\n"
    return header + "\n" + part


class LabKey:
    """ASGI middleware: only requests with the lab key (Authorization: Bearer <key>) get through."""

    def __init__(self, app, key: str):
        self.app, self.expected = app, f"Bearer {key}".encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            got = dict(scope["headers"]).get(b"authorization", b"")
            if not secrets.compare_digest(got, self.expected):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"missing or wrong lab key\n"})
                return
        await self.app(scope, receive, send)


def main():
    import uvicorn
    key = KEY_FILE.read_text().strip()
    if not key:
        raise SystemExit(f"empty lab key in {KEY_FILE}")
    app = LabKey(mcp.streamable_http_app(), key)
    print(f"lab-search MCP on http://127.0.0.1:{PORT}/mcp, SearXNG at {SEARXNG_URL}", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")


if __name__ == "__main__":
    main()
