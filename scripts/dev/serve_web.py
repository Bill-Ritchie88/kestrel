"""
Serve the Flutter release build (client/build/web) for demos.

    python scripts/dev/serve_web.py            # http://localhost:8080
    python scripts/dev/serve_web.py --port 8081 --root client/build/web

`flutter run` is for development: it serves an unoptimised debug build.
This serves what `flutter build web --release` produced, the way a static
host would:

* gzip for .js, .mjs, .wasm, .json, .css, .html, .svg, .txt and fonts, when
  the browser accepts it (all compressed at start-up, kept in memory, and
  recompressed only when a file changes);
* `Cache-Control: public, max-age=31536000, immutable` for files whose name
  carries a content hash, `no-cache` (revalidate with an ETag, answered 304
  when unchanged) for everything else, including index.html, so a new build
  is picked up on the next load;
* any path without a file extension falls back to index.html, as a
  single-page app needs;
* it listens on 127.0.0.1 and ::1: a browser tries localhost over IPv6
  first, and without an answer there every new connection waited for the
  fallback (seconds, in Chrome).

`--cross-origin-isolated` adds the COOP/COEP headers that let a `--wasm`
build's renderer use a second thread. Measured on the demo laptop it made no
difference to start-up, and cross-origin isolation can get in the way of
sign-in redirects, so `.\tasks.ps1 web` does not use it.

Standard library only.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import re
import socket
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WEB_ROOT = ROOT / "client" / "build" / "web"

# Explicit, because Python's mimetypes reads the Windows registry, which can
# map .js to text/plain - and a browser refuses to run a module served so.
CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".json": "application/json",
    ".wasm": "application/wasm",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".ico": "image/x-icon",
    ".ttf": "font/ttf",
    ".otf": "font/otf",
    ".woff2": "font/woff2",
    ".txt": "text/plain; charset=utf-8",
    ".map": "application/json",
    ".frag": "application/octet-stream",
    ".bin": "application/octet-stream",
}
COMPRESSIBLE = {".html", ".js", ".mjs", ".json", ".wasm", ".css", ".svg", ".txt", ".ttf", ".otf", ".map"}
# e.g. main.3f9a1c2b.js, chunk-5d41402abc4b2a76.js
HASHED_NAME = re.compile(r"[.-][0-9a-f]{8,}\.[a-z0-9]+$")

IMMUTABLE = "public, max-age=31536000, immutable"
REVALIDATE = "no-cache"


class Site:
    """The build folder, with a cache of compressed files."""

    def __init__(self, root: Path):
        self.root = root.resolve()
        self._gz: dict[tuple[Path, int], bytes] = {}
        self._lock = threading.Lock()

    def resolve(self, url_path: str) -> Path | None:
        rel = url_path.split("?", 1)[0].split("#", 1)[0].lstrip("/") or "index.html"
        candidate = (self.root / rel).resolve()
        if not candidate.is_relative_to(self.root):
            return None  # ../ out of the build folder
        if candidate.is_dir():
            candidate = candidate / "index.html"
        if candidate.is_file():
            return candidate
        # Single-page app: /trip, /help ... are the app's own routes.
        if "." not in Path(rel).name:
            return self.root / "index.html"
        return None

    def precompress(self) -> tuple[int, float]:
        """Compress every compressible file now, so the first visitor does
        not wait while the 5 MB CanvasKit module is gzipped."""
        started = time.perf_counter()
        files = [
            f for f in self.root.rglob("*") if f.is_file() and f.suffix.lower() in COMPRESSIBLE
        ]
        for f in files:
            self.gzipped(f, f.stat().st_mtime_ns)
        return len(files), time.perf_counter() - started

    def gzipped(self, path: Path, mtime_ns: int) -> bytes:
        key = (path, mtime_ns)
        with self._lock:
            cached = self._gz.get(key)
        if cached is None:
            cached = gzip.compress(path.read_bytes(), compresslevel=6, mtime=0)
            with self._lock:
                self._gz[key] = cached
        return cached


def cache_control(path: Path) -> str:
    if path.name == "index.html":
        return REVALIDATE
    return IMMUTABLE if HASHED_NAME.search(path.name) else REVALIDATE


def make_handler(site: Site, isolated: bool = False):
    class Handler(BaseHTTPRequestHandler):
        server_version = "KestrelWeb/1.0"
        # Keep-alive: the page's dozen files reuse one connection. Every
        # response carries a Content-Length, which HTTP/1.1 needs for that.
        protocol_version = "HTTP/1.1"

        def do_HEAD(self):  # noqa: N802 - the http.server naming convention
            self._serve(head=True)

        def do_GET(self):  # noqa: N802
            self._serve(head=False)

        def _serve(self, head: bool) -> None:
            path = site.resolve(self.path)
            if path is None:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            stat = path.stat()
            etag = '"' + hashlib.sha1(  # noqa: S324 - a cache validator, not security
                f"{path}:{stat.st_mtime_ns}:{stat.st_size}".encode()
            ).hexdigest()[:20] + '"'
            if self.headers.get("If-None-Match") == etag:
                self.send_response(HTTPStatus.NOT_MODIFIED)
                self.send_header("ETag", etag)
                self.send_header("Cache-Control", cache_control(path))
                self.end_headers()
                return

            suffix = path.suffix.lower()
            accepts_gzip = "gzip" in self.headers.get("Accept-Encoding", "")
            if accepts_gzip and suffix in COMPRESSIBLE:
                body = site.gzipped(path, stat.st_mtime_ns)
                encoding = "gzip"
            else:
                body = path.read_bytes()
                encoding = None

            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", CONTENT_TYPES.get(suffix, "application/octet-stream"))
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache_control(path))
            self.send_header("ETag", etag)
            if suffix in COMPRESSIBLE:
                self.send_header("Vary", "Accept-Encoding")
            if encoding:
                self.send_header("Content-Encoding", encoding)
            if isolated:
                self.send_header("Cross-Origin-Opener-Policy", "same-origin")
                self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def log_message(self, format, *args):  # noqa: A002 - signature of the base class
            if "--quiet" not in sys.argv:
                super().log_message(format, *args)

    return Handler


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Serve the Flutter release build.")
    parser.add_argument("--root", default=str(DEFAULT_WEB_ROOT))
    parser.add_argument(
        "--host",
        action="append",
        help="address to listen on (repeatable); default 127.0.0.1 and ::1, since a browser "
        "tries localhost over IPv6 first and waits for the fallback if nothing answers there",
    )
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--quiet", action="store_true", help="do not log each request")
    parser.add_argument(
        "--cross-origin-isolated",
        action="store_true",
        help="send COOP/COEP headers, which a --wasm build's renderer needs to use a second thread",
    )
    args = parser.parse_args(argv)

    root = Path(args.root)
    if not (root / "index.html").is_file():
        print(f"[ERROR] No build in {root}. Run: .\\tasks.ps1 web (or flutter build web --release)")
        return 1
    site = Site(root)
    count, seconds = site.precompress()
    print(f"[INFO] Compressed {count} files in {seconds:.1f} s", flush=True)
    handler = make_handler(site, isolated=args.cross_origin_isolated)
    servers = []
    for host in args.host or ["127.0.0.1", "::1"]:
        server_class = _IPv6Server if ":" in host else ThreadingHTTPServer
        try:
            servers.append(server_class((host, args.port), handler))
        except OSError as exc:
            print(f"[WARN] Not listening on {host}: {exc}", flush=True)
    if not servers:
        return 1
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"[INFO] Serving {root} on http://localhost:{args.port}  (Ctrl+C to stop)", flush=True)
    try:
        servers[0].serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for server in servers:
            server.server_close()
    return 0


class _IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


if __name__ == "__main__":
    sys.exit(main())
