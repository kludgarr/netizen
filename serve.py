#!/usr/bin/env python3
"""Single-surface Netizen Swagger launcher and OpenAPI-route-aware forwarder.

Configuration is optional. Without --config, the launcher uses
netizen.config.json beside the script, creating it after the OpenAPI document
has been resolved unambiguously.

OpenAPI document resolution order:

1. --spec
2. specPath from the configuration document
3. exactly one adjacent versioned OpenAPI JSON document
4. failure

Configuration shape:

    {
      "specPath": "./tvmaze_openapi_v3.0.3.json",
      "upstream": {
        "baseUrl": null,
        "requestHeaders": {}
      }
    }

When upstream.baseUrl is absent, blank, or null, the first root OpenAPI Server
Object is resolved using each Server Variable Object's default. An explicitly
configured base URL becomes the default server in the in-memory document served
to Swagger. The source document is never modified.
"""

from __future__ import annotations

import argparse
import copy
import html
import http.client
import http.server
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


HTTP_METHODS = ("get", "post", "put", "patch", "delete", "head", "options", "trace")
FORWARDING_ROUTE = "/api"
SPEC_ROUTE = "/openapi.json"
UPSTREAM_BASE_HEADER = "X-Netizen-Upstream-Base"
IDLE_TIMEOUT_SECONDS = 120
MAX_CONCURRENT_REQUESTS = 8
OUTBOUND_TIMEOUT_SECONDS = 100
FIXED_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}
ASSETS = {
    "stylesheet": ("swagger-ui.css", "/assets/swagger-ui.css", "text/css; charset=utf-8"),
    "bundle": ("swagger-ui-bundle.js", "/assets/swagger-ui-bundle.js", "application/javascript; charset=utf-8"),
    "preset": (
        "swagger-ui-standalone-preset.js",
        "/assets/swagger-ui-standalone-preset.js",
        "application/javascript; charset=utf-8",
    ),
}


class ConfigurationError(ValueError):
    """Configuration or OpenAPI input cannot satisfy the runtime contract."""


@dataclass(frozen=True)
class Route:
    method: str
    template: str
    matcher: re.Pattern[str]
    suffix_pattern: str
    is_templated: bool
    request_content_types: tuple[str, ...]


@dataclass(frozen=True)
class Asset:
    path: Path
    content_type: str


def require_properties(value: Any, names: Iterable[str], prefix: str = "") -> None:
    if not isinstance(value, dict):
        raise ConfigurationError(f"{prefix.rstrip('.')} must be an object.")
    for name in names:
        if name not in value or value[name] is None:
            raise ConfigurationError(f"Config property '{prefix}{name}' is required.")


def resolve_config_path(base_directory: Path, value: str) -> Path:
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = base_directory / candidate
    return candidate.resolve()


def resolve_local_reference(spec: dict[str, Any], value: Any, kind: str) -> Any:
    resolved = value
    visited: set[str] = set()
    while isinstance(resolved, dict) and "$ref" in resolved:
        reference = str(resolved["$ref"])
        if not reference.startswith("#/"):
            raise ConfigurationError(
                f"External OpenAPI {kind} reference is not supported for runtime routing: {reference}"
            )
        if reference in visited:
            raise ConfigurationError(
                f"Cyclic OpenAPI {kind} reference is not supported for runtime routing: {reference}"
            )
        visited.add(reference)
        resolved = spec
        for token in reference[2:].split("/"):
            name = token.replace("~1", "/").replace("~0", "~")
            if not isinstance(resolved, dict) or name not in resolved:
                raise ConfigurationError(f"OpenAPI {kind} reference did not resolve: {reference}")
            resolved = resolved[name]
    return resolved


def _template_parts(path: str) -> Iterable[tuple[str, bool]]:
    offset = 0
    for match in re.finditer(r"\{[^}]+\}", path):
        yield path[offset : match.start()], False
        yield match.group(0), True
        offset = match.end()
    yield path[offset:], False


def _javascript_regex_escape(value: str) -> str:
    return re.sub(r"([\\^$.*+?()\[\]{}|])", r"\\\1", value)


def path_regex(path: str) -> re.Pattern[str]:
    if path == "/":
        return re.compile(r"^/$")
    normalized = path.rstrip("/")
    pieces = ["^"]
    for text, variable in _template_parts(normalized):
        pieces.append(r"[^/]+" if variable else re.escape(text))
    pieces.append(r"/?$")
    return re.compile("".join(pieces))


def path_suffix_regex_source(path: str) -> str:
    if path == "/":
        return "/$"
    normalized = path.rstrip("/")
    pieces: list[str] = []
    for text, variable in _template_parts(normalized):
        pieces.append("[^/]+" if variable else _javascript_regex_escape(text))
    pieces.append("/?$")
    return "".join(pieces)


def openapi_routes(spec: dict[str, Any]) -> list[Route]:
    paths = spec.get("paths")
    if not isinstance(paths, dict):
        raise ConfigurationError("OpenAPI document.paths must be an object.")
    routes: list[Route] = []
    for template, unresolved_path_item in paths.items():
        path_item = resolve_local_reference(spec, unresolved_path_item, "Path Item")
        if not isinstance(path_item, dict):
            raise ConfigurationError(f"OpenAPI Path Item did not resolve to an object: {template}")
        for method in HTTP_METHODS:
            operation = path_item.get(method)
            if not isinstance(operation, dict):
                continue
            request_body = resolve_local_reference(spec, operation.get("requestBody"), "request body")
            content = request_body.get("content") if isinstance(request_body, dict) else None
            routes.append(
                Route(
                    method=method.upper(),
                    template=template,
                    matcher=path_regex(template),
                    suffix_pattern=path_suffix_regex_source(template),
                    is_templated="{" in template,
                    request_content_types=tuple(content.keys()) if isinstance(content, dict) else (),
                )
            )
    return routes


def find_route(routes: list[Route], method: str, path: str) -> tuple[Route | None, bool]:
    path_matches = [route for route in routes if route.matcher.fullmatch(path)]
    method_matches = [route for route in path_matches if route.method == method]
    method_matches.sort(key=lambda route: route.is_templated)
    return (method_matches[0] if method_matches else None, bool(path_matches))


def _validate_http_base_url(value: str, label: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ConfigurationError(f"{label} must be an absolute HTTP or HTTPS URL: '{value}'.")
    if parsed.query or parsed.fragment:
        raise ConfigurationError(f"{label} must not contain a query or fragment: '{value}'.")
    return value.rstrip("/")


def default_upstream_base_url(spec: dict[str, Any]) -> str:
    servers = spec.get("servers")
    if not isinstance(servers, list) or not servers:
        raise ConfigurationError(
            "upstream.baseUrl was not configured and the OpenAPI document declares no root servers."
        )
    server = servers[0]
    if not isinstance(server, dict) or not str(server.get("url") or "").strip():
        raise ConfigurationError("The first root OpenAPI Server Object has no URL.")
    url = str(server["url"])
    variables = server.get("variables")
    if isinstance(variables, dict):
        for name, variable in variables.items():
            if not isinstance(variable, dict) or variable.get("default") is None:
                raise ConfigurationError(f"OpenAPI server variable '{name}' has no default value.")
            url = url.replace("{" + name + "}", str(variable["default"]))
    if re.search(r"\{[^}]+\}", url):
        raise ConfigurationError(f"The first root OpenAPI server URL contains an unresolved variable: '{url}'.")
    return url


def resolve_upstream_base_url(spec: dict[str, Any], upstream: Any) -> tuple[str, bool]:
    configured = upstream.get("baseUrl") if isinstance(upstream, dict) else None
    explicitly_configured = isinstance(configured, str) and bool(configured.strip())
    candidate = configured if explicitly_configured else default_upstream_base_url(spec)
    return _validate_http_base_url(str(candidate), "The resolved upstream base URL"), explicitly_configured


def runtime_openapi_document(spec: dict[str, Any], configured_base_url: str) -> dict[str, Any]:
    runtime = copy.deepcopy(spec)
    configured_server = {
        "url": configured_base_url,
        "description": "Runtime-configured default upstream.",
    }

    def prepend(container: Any, required: bool) -> None:
        if not isinstance(container, dict):
            return
        if not required and "servers" not in container:
            return
        existing = container.get("servers")
        existing = existing if isinstance(existing, list) else []
        matching = next(
            (
                server
                for server in existing
                if isinstance(server, dict)
                and str(server.get("url", "")).casefold() == configured_base_url.casefold()
            ),
            None,
        )
        default_server = matching if matching is not None else configured_server
        container["servers"] = [default_server] + [
            server
            for server in existing
            if not (
                isinstance(server, dict)
                and str(server.get("url", "")).casefold() == configured_base_url.casefold()
            )
        ]

    prepend(runtime, True)
    for unresolved_path_item in runtime.get("paths", {}).values():
        path_item = resolve_local_reference(runtime, unresolved_path_item, "Path Item")
        prepend(path_item, False)
        if isinstance(path_item, dict):
            for method in HTTP_METHODS:
                prepend(path_item.get(method), False)
    return runtime


def hop_by_hop_names(headers: Iterable[tuple[str, str]]) -> set[str]:
    names = set(FIXED_HOP_BY_HOP)
    for name, value in headers:
        if name.casefold() == "connection":
            names.update(token.strip().casefold() for token in value.split(",") if token.strip())
    return names


def validate_request_headers(headers: Any) -> dict[str, str]:
    if headers is None:
        return {}
    if not isinstance(headers, dict):
        raise ConfigurationError("upstream.requestHeaders must be an object or null.")
    validated: dict[str, str] = {}
    for name, value in headers.items():
        if name.casefold() == UPSTREAM_BASE_HEADER.casefold():
            raise ConfigurationError(
                f"upstream.requestHeaders cannot configure reserved header '{UPSTREAM_BASE_HEADER}'."
            )
        if name.casefold() in FIXED_HOP_BY_HOP:
            raise ConfigurationError(f"upstream.requestHeaders cannot configure hop-by-hop header '{name}'.")
        validated[str(name)] = str(value)
    return validated


def html_safe_json(value: Any) -> str:
    return (
        json.dumps(value, separators=(",", ":"), ensure_ascii=False)
        .replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def swagger_html(title: str, runtime_json: str) -> bytes:
    encoded_title = html.escape(title, quote=True)
    document = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{encoded_title}</title>
  <style>
    body{{margin:0;padding:0}}.asset-toolbar{{position:sticky;top:0;z-index:10;padding:10px 12px;background:#101017;color:#d5d5e0;font:12px "Segoe UI",Arial,sans-serif;border-bottom:1px solid #ffffff24}}.auth-guidance{{margin-top:6px;color:#ffe08a}}.auth-guidance strong{{color:#fff}}
    #swagger-ui .topbar{{background-color:#1a1a2e}}#swagger-ui .topbar-wrapper img{{display:none}}
  </style>
</head>
<body><div class="asset-toolbar"><div id="asset-status">Initializing Swagger UI assets...</div><div class="auth-guidance">After entering a credential, click <strong>Authorize</strong> inside that credential block. Closing the dialog does not apply it; a closed lock confirms it is active.</div></div><div id="swagger-ui"></div>
<script>
const CONFIG={runtime_json},statusEl=document.getElementById('asset-status');
const load=(tag,attrs)=>new Promise((resolve,reject)=>{{const el=document.createElement(tag);Object.assign(el,attrs);el.onload=resolve;el.onerror=()=>reject(new Error('Failed to load '+(attrs.src||attrs.href)));document[tag==='link'?'head':'body'].appendChild(el)}});
const ROUTES=CONFIG.routes.map(route=>({{...route,matcher:new RegExp(route.suffixPattern)}}));
function requestInterceptor(req){{
  const target=new URL(req.url,window.location.origin);
  const localControlRoutes=[CONFIG.specRoute,...Object.values(CONFIG.assets)];
  if(target.origin===window.location.origin&&localControlRoutes.includes(target.pathname))return req;
  if(target.origin===window.location.origin&&(target.pathname===CONFIG.forwardingRoute||target.pathname.startsWith(CONFIG.forwardingRoute+'/')))return req;
  const method=(req.method||'GET').toUpperCase();
  let selected=null;
  for(const route of ROUTES){{if(route.method!==method)continue;const match=route.matcher.exec(target.pathname);if(match){{selected={{route,match}};break}}}}
  if(!selected)throw new Error('Computed Swagger request URL did not end with a declared OpenAPI operation path.');
  const renderedBase=target.origin+target.pathname.slice(0,selected.match.index);
  req.headers=Object.assign({{}},req.headers||{{}},{{[CONFIG.upstreamBaseHeader]:renderedBase}});
  req.url=window.location.origin+CONFIG.forwardingRoute+selected.match[0]+target.search;
  return req;
}}
(async()=>{{try{{await load('link',{{rel:'stylesheet',href:CONFIG.assets.stylesheet}});await load('script',{{src:CONFIG.assets.bundle}});await load('script',{{src:CONFIG.assets.preset}});SwaggerUIBundle({{url:CONFIG.specRoute,dom_id:'#swagger-ui',presets:[SwaggerUIBundle.presets.apis,SwaggerUIStandalonePreset],layout:'StandaloneLayout',tryItOutEnabled:true,persistAuthorization:true,deepLinking:true,displayRequestDuration:true,defaultModelsExpandDepth:1,defaultModelExpandDepth:2,docExpansion:'list',filter:true,validatorUrl:null,requestInterceptor}});statusEl.textContent='Swagger UI loaded from local assets.'}}catch(error){{statusEl.textContent='Swagger UI load failed: '+error.message}}}})();
</script></body></html>"""
    return document.encode("utf-8")


def install_swagger_assets(cache_directory: Path) -> dict[str, Asset]:
    cache_directory.mkdir(parents=True, exist_ok=True)
    installed = {
        key: Asset(cache_directory / filename, content_type)
        for key, (filename, _route, content_type) in ASSETS.items()
    }
    if all(asset.path.is_file() for asset in installed.values()):
        return installed

    archive_path = cache_directory / "swagger-ui-release.zip"
    if not archive_path.is_file():
        request = urllib.request.Request(
            "https://api.github.com/repos/swagger-api/swagger-ui/releases/latest",
            headers={"User-Agent": "netizen-local-swagger"},
        )
        with urllib.request.urlopen(request) as response:
            release = json.load(response)
        zipball_url = release.get("zipball_url")
        if not zipball_url:
            raise RuntimeError("The latest Swagger UI GitHub release did not provide zipball_url.")
        download_path = archive_path.with_suffix(".zip.download")
        print(f"Downloading latest Swagger UI release archive ({release.get('tag_name', 'unknown')})...")
        try:
            download_request = urllib.request.Request(
                zipball_url, headers={"User-Agent": "netizen-local-swagger"}
            )
            with urllib.request.urlopen(download_request) as source, download_path.open("wb") as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
            os.replace(download_path, archive_path)
        finally:
            download_path.unlink(missing_ok=True)

    with zipfile.ZipFile(archive_path) as archive:
        for key, (filename, _route, _content_type) in ASSETS.items():
            matches = [
                name
                for name in archive.namelist()
                if name == f"dist/{filename}" or name.endswith(f"/dist/{filename}")
            ]
            if len(matches) != 1:
                raise RuntimeError(
                    f"Swagger UI archive must contain exactly one dist/{filename}; found {len(matches)}."
                )
            temporary = installed[key].path.with_suffix(installed[key].path.suffix + ".extract")
            try:
                with archive.open(matches[0]) as source, temporary.open("wb") as target:
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
                os.replace(temporary, installed[key].path)
            finally:
                temporary.unlink(missing_ok=True)
    return installed


class GatewayState:
    def __init__(
        self,
        *,
        source_spec: dict[str, Any],
        served_spec: dict[str, Any],
        upstream_base_url: str,
        request_headers: dict[str, str],
        assets: dict[str, Asset],
    ) -> None:
        self.routes = openapi_routes(source_spec)
        if not self.routes:
            raise ConfigurationError("The OpenAPI document contains no supported routes.")
        self.upstream_base_url = upstream_base_url
        self.request_headers = request_headers
        self.assets_by_route = {
            ASSETS[key][1]: asset for key, asset in assets.items()
        }
        runtime = {
            "title": str(source_spec["info"]["title"]),
            "specRoute": SPEC_ROUTE,
            "forwardingRoute": FORWARDING_ROUTE,
            "assets": {key: ASSETS[key][1] for key in ASSETS},
            "upstreamBaseHeader": UPSTREAM_BASE_HEADER,
            "routes": [
                {
                    "method": route.method,
                    "template": route.template,
                    "suffixPattern": route.suffix_pattern,
                }
                for route in sorted(
                    self.routes, key=lambda route: (route.is_templated, -len(route.template))
                )
            ],
        }
        self.index_bytes = swagger_html(runtime["title"], html_safe_json(runtime))
        self.spec_bytes = json.dumps(served_spec, ensure_ascii=False, indent=2).encode("utf-8")
        self.last_request = time.monotonic()
        self.initial_load = False
        self.activity_lock = threading.Lock()

    def record_request(self, root: bool) -> None:
        with self.activity_lock:
            self.last_request = time.monotonic()
            if root:
                self.initial_load = True


class BoundedThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, server_address: tuple[str, int], handler: type[http.server.BaseHTTPRequestHandler], state: GatewayState):
        self.state = state
        self._request_slots = threading.BoundedSemaphore(MAX_CONCURRENT_REQUESTS)
        super().__init__(server_address, handler)

    def process_request(self, request: Any, client_address: Any) -> None:
        self._request_slots.acquire()
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


class NetizenHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def state(self) -> GatewayState:
        return self.server.state  # type: ignore[attr-defined, no-any-return]

    def do_GET(self) -> None:
        self._handle()

    def do_POST(self) -> None:
        self._handle()

    def do_PUT(self) -> None:
        self._handle()

    def do_PATCH(self) -> None:
        self._handle()

    def do_DELETE(self) -> None:
        self._handle()

    def do_HEAD(self) -> None:
        self._handle()

    def do_OPTIONS(self) -> None:
        self._handle()

    def do_TRACE(self) -> None:
        self._handle()

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _send_bytes(
        self,
        status: int,
        body: bytes,
        content_type: str | None = None,
        headers: Iterable[tuple[str, str]] = (),
    ) -> None:
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _local_failure(self, status: int, code: str) -> None:
        self._send_bytes(
            status,
            json.dumps({"error": code}, separators=(",", ":")).encode("utf-8"),
            "application/json; charset=utf-8",
        )

    def _handle(self) -> None:
        target = urllib.parse.urlsplit(self.path)
        path = target.path
        self.state.record_request(path == "/")
        try:
            if path == "/":
                self._send_bytes(200, self.state.index_bytes, "text/html; charset=utf-8")
                return
            if path == SPEC_ROUTE:
                self._send_bytes(200, self.state.spec_bytes, "application/json; charset=utf-8")
                return
            asset = self.state.assets_by_route.get(path)
            if asset is not None:
                self._send_bytes(200, asset.path.read_bytes(), asset.content_type)
                return
            if path != FORWARDING_ROUTE and not path.startswith(FORWARDING_ROUTE + "/"):
                self._local_failure(404, "route_not_found")
                return
            api_path = path[len(FORWARDING_ROUTE) :] or "/"
            route, path_matched = find_route(self.state.routes, self.command, api_path)
            if route is None:
                self._local_failure(
                    405 if path_matched else 404,
                    "method_not_allowed" if path_matched else "openapi_route_not_found",
                )
                return
            try:
                request_base = self._request_upstream_base_url()
            except ConfigurationError:
                self._local_failure(400, "invalid_upstream_base")
                return
            self._proxy(route, request_base, api_path, target.query)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception:
            print("Warning: request worker failed: request_worker_failed.", file=sys.stderr)
            try:
                self._local_failure(500, "request_worker_failed")
            except Exception:
                return

    def _request_upstream_base_url(self) -> str:
        values = self.headers.get_all(UPSTREAM_BASE_HEADER)
        if values is None:
            return self.state.upstream_base_url
        if len(values) != 1 or not values[0].strip():
            raise ConfigurationError(
                f"Request header '{UPSTREAM_BASE_HEADER}' must contain exactly one non-empty value."
            )
        return _validate_http_base_url(
            values[0].strip(), f"Request header '{UPSTREAM_BASE_HEADER}'"
        )

    def _read_chunked_body(self) -> bytes:
        chunks: list[bytes] = []
        while True:
            size_line = self.rfile.readline(65537)
            if not size_line or len(size_line) > 65536:
                raise ValueError("Invalid chunked request body.")
            size = int(size_line.split(b";", 1)[0].strip(), 16)
            if size == 0:
                while self.rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                    pass
                break
            chunk = self.rfile.read(size)
            if len(chunk) != size or self.rfile.read(2) != b"\r\n":
                raise ValueError("Invalid chunked request body.")
            chunks.append(chunk)
        return b"".join(chunks)

    def _request_body(self) -> bytes:
        transfer_encoding = self.headers.get("Transfer-Encoding", "")
        if transfer_encoding:
            if transfer_encoding.casefold().strip() != "chunked":
                raise ValueError("Unsupported request Transfer-Encoding.")
            return self._read_chunked_body()
        content_length = self.headers.get("Content-Length")
        if content_length is None:
            return b""
        length = int(content_length)
        if length < 0:
            raise ValueError("Invalid Content-Length.")
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("Request body ended before Content-Length bytes were read.")
        return body

    def _proxy(self, route: Route, base_url: str, api_path: str, query: str) -> None:
        upstream_request: http.client.HTTPConnection | None = None
        try:
            body = self._request_body()
            parsed_base = urllib.parse.urlsplit(base_url)
            base_path = parsed_base.path.rstrip("/")
            upstream_path = (base_path + api_path) or "/"
            if query:
                upstream_path += "?" + query

            raw_headers = list(self.headers.raw_items())
            excluded = hop_by_hop_names(raw_headers)
            excluded.update(
                {
                    "host",
                    "content-length",
                    "accept-encoding",
                    "content-type",
                    UPSTREAM_BASE_HEADER.casefold(),
                }
            )
            forwarded = [(name, value) for name, value in raw_headers if name.casefold() not in excluded]
            caller_content_type = self.headers.get("Content-Type")

            configured_by_name = {
                name.casefold(): (name, value) for name, value in self.state.request_headers.items()
            }
            forwarded = [
                (name, value) for name, value in forwarded if name.casefold() not in configured_by_name
            ]
            configured_content_type = None
            for folded, (name, value) in configured_by_name.items():
                if folded == "content-type":
                    configured_content_type = value
                elif folded not in {"host", "content-length", "accept-encoding"}:
                    forwarded.append((name, value))

            has_content_metadata = bool(
                caller_content_type
                or configured_content_type
                or any(name.casefold().startswith("content-") for name, _value in forwarded)
            )
            content_type = configured_content_type or caller_content_type
            if body and not content_type and route.request_content_types:
                content_type = route.request_content_types[0]
            if content_type:
                has_content_metadata = True

            connection_type: type[http.client.HTTPConnection]
            connection_type = (
                http.client.HTTPSConnection if parsed_base.scheme == "https" else http.client.HTTPConnection
            )
            kwargs: dict[str, Any] = {"timeout": OUTBOUND_TIMEOUT_SECONDS}
            if parsed_base.scheme == "https":
                kwargs["context"] = ssl.create_default_context()
            upstream_request = connection_type(parsed_base.hostname, parsed_base.port, **kwargs)
            upstream_request.putrequest(self.command, upstream_path, skip_accept_encoding=True)
            for name, value in forwarded:
                upstream_request.putheader(name, value)
            if body or has_content_metadata:
                upstream_request.putheader("Content-Length", str(len(body)))
            if content_type:
                upstream_request.putheader("Content-Type", content_type)
            upstream_request.endheaders(body if body else None)

            upstream_response = upstream_request.getresponse()
            raw_body = upstream_response.read()
            response_headers = upstream_response.getheaders()
            excluded_response = hop_by_hop_names(response_headers)
            excluded_response.update({"content-length", "content-type"})
            content_types = [
                value for name, value in response_headers if name.casefold() == "content-type"
            ]
            safe_headers = [
                (name, value)
                for name, value in response_headers
                if name.casefold() not in excluded_response
            ]
            self._send_bytes(
                upstream_response.status,
                raw_body,
                content_types[0] if content_types else None,
                safe_headers,
            )
        except Exception:
            print("Warning: upstream forwarding failed: upstream_forwarding_failed.", file=sys.stderr)
            self._local_failure(502, "upstream_forwarding_failed")
        finally:
            if upstream_request is not None:
                upstream_request.close()


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve Netizen Swagger UI and its local gateway.")
    parser.add_argument(
        "-c",
        "--config",
        help="Optional service configuration JSON document (default: adjacent netizen.config.json)",
    )
    parser.add_argument(
        "-s",
        "--spec",
        help="OpenAPI document; takes precedence over config specPath and adjacent discovery",
    )
    parser.add_argument("-p", "--port", type=int, default=8080, help="Preferred loopback port")
    parser.add_argument(
        "-k", "--keep-alive", action="store_true", help="Disable the 120-second inactivity shutdown"
    )
    return parser.parse_args(argv)


def build_state(config_path: Path, selected_spec: Path | None = None) -> tuple[GatewayState, Path, str]:
    config_path = config_path.resolve()
    if not config_path.parent.is_dir():
        raise ConfigurationError(f"Configuration directory not found: {config_path.parent}")

    config_exists = config_path.is_file()
    if config_exists:
        with config_path.open(encoding="utf-8-sig") as stream:
            settings = json.load(stream)
        if not isinstance(settings, dict):
            raise ConfigurationError("Configuration document must be an object.")
    else:
        settings = {
            "specPath": None,
            "upstream": {
                "baseUrl": None,
                "requestHeaders": {},
            },
        }

    configured_spec = settings.get("specPath")
    if selected_spec is not None:
        spec_path = resolve_config_path(Path.cwd(), str(selected_spec))
    elif configured_spec is not None and str(configured_spec).strip():
        spec_path = resolve_config_path(config_path.parent, str(configured_spec))
    else:
        script_directory = Path(__file__).resolve().parent
        discovery_pattern = re.compile(
            r"(?:^|[_-])openapi[_-]v\d+(?:\.\d+)+.*\.json$", re.IGNORECASE
        )
        discovered_specs = sorted(
            (
                candidate
                for candidate in script_directory.glob("*.json")
                if candidate.is_file() and discovery_pattern.search(candidate.name)
            ),
            key=lambda candidate: candidate.name,
        )
        if not discovered_specs:
            raise ConfigurationError(
                "No OpenAPI document was selected: supply --spec, set config specPath, "
                "or place exactly one versioned OpenAPI JSON file beside the launcher."
            )
        if len(discovered_specs) > 1:
            names = ", ".join(candidate.name for candidate in discovered_specs)
            raise ConfigurationError(
                f"Multiple adjacent OpenAPI documents were found ({names}): "
                "supply --spec or set config specPath."
            )
        spec_path = discovered_specs[0].resolve()

    if not spec_path.is_file():
        raise ConfigurationError(f"Required file not found: {spec_path}")
    source_json = spec_path.read_text(encoding="utf-8-sig")
    spec = json.loads(source_json)
    require_properties(spec, ("openapi", "info", "paths"), "OpenAPI document.")
    require_properties(spec["info"], ("title",), "OpenAPI document.info.")

    if not config_exists:
        try:
            relative_spec_path = os.path.relpath(spec_path, config_path.parent)
        except ValueError:
            relative_spec_path = str(spec_path)
        relative_spec_path = relative_spec_path.replace(os.sep, "/")
        if not Path(relative_spec_path).is_absolute() and not relative_spec_path.startswith("."):
            relative_spec_path = f"./{relative_spec_path}"
        settings["specPath"] = relative_spec_path
        temporary_config_path = config_path.with_name(config_path.name + ".new")
        try:
            temporary_config_path.write_text(
                json.dumps(settings, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            temporary_config_path.replace(config_path)
        finally:
            temporary_config_path.unlink(missing_ok=True)
        print(f"Created configuration: {config_path}")

    upstream = settings.get("upstream")
    upstream_base_url, explicitly_configured = resolve_upstream_base_url(spec, upstream)
    request_headers = validate_request_headers(
        upstream.get("requestHeaders") if isinstance(upstream, dict) else None
    )
    served_spec = (
        runtime_openapi_document(spec, upstream_base_url) if explicitly_configured else copy.deepcopy(spec)
    )
    assets = install_swagger_assets(Path(__file__).resolve().parent / ".swagger-ui")
    return (
        GatewayState(
            source_spec=spec,
            served_spec=served_spec,
            upstream_base_url=upstream_base_url,
            request_headers=request_headers,
            assets=assets,
        ),
        spec_path,
        str(spec["openapi"]),
    )


def bind_server(preferred_port: int, state: GatewayState) -> tuple[BoundedThreadingHTTPServer, int]:
    last_error: OSError | None = None
    for port in range(preferred_port, preferred_port + 11):
        try:
            return BoundedThreadingHTTPServer(("127.0.0.1", port), NetizenHandler, state), port
        except OSError as error:
            last_error = error
    raise OSError(
        f"Could not bind to any port in range {preferred_port}-{preferred_port + 10}. {last_error}"
    )


def idle_watcher(server: BoundedThreadingHTTPServer, state: GatewayState) -> None:
    while not getattr(server, "_BaseServer__shutdown_request", False):
        time.sleep(1)
        with state.activity_lock:
            expired = state.initial_load and time.monotonic() - state.last_request >= IDLE_TIMEOUT_SECONDS
        if expired:
            print(f"No activity for {IDLE_TIMEOUT_SECONDS} seconds - shutting down.")
            server.shutdown()
            return


def main(argv: list[str] | None = None) -> int:
    args = parse_arguments(argv)
    if args.config is not None and not args.config.strip():
        raise ConfigurationError("--config must name a configuration document when supplied.")
    if args.spec is not None and not args.spec.strip():
        raise ConfigurationError("--spec must name an OpenAPI document when supplied.")

    script_directory = Path(__file__).resolve().parent
    config_path = (
        resolve_config_path(Path.cwd(), args.config)
        if args.config is not None
        else script_directory / "netizen.config.json"
    )
    selected_spec = Path(args.spec) if args.spec is not None else None
    state, spec_path, openapi_version = build_state(config_path, selected_spec)
    server, port = bind_server(args.port, state)
    browser_url = f"http://127.0.0.1:{port}/"

    print(f"Serving configuration: {config_path.resolve()}")
    print(f"Serving OpenAPI document: {spec_path}")
    print(f"Loaded OpenAPI routes: {len(state.routes)}")
    print(f"OpenAPI version: {openapi_version}")
    print(f"Open: {browser_url}")
    if args.keep_alive:
        print("KeepAlive enabled - Ctrl+C to stop.")
    else:
        print(
            f"Auto-stops after {IDLE_TIMEOUT_SECONDS} seconds of inactivity following the initial page load."
        )

    threading.Timer(0.5, lambda: webbrowser.open(browser_url)).start()
    if not args.keep_alive:
        threading.Thread(target=idle_watcher, args=(server, state), daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        print("Stopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
