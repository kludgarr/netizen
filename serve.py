#!/usr/bin/env python3
"""Open a Netizen OpenAPI document in a local Swagger UI.

The launcher resolves a document from --spec, config.json, or unambiguous
adjacent discovery; serves a runtime copy to Swagger UI; and forwards declared
operations to an upstream selected by config, the OpenAPI document, or Swagger's
spec-defined Server Object controls.
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
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator


SWAGGER_UI_VERSION = "5.32.8"
SERVER_SELECTION_HEADER = "X-Netizen-Upstream-Base"
SPEC_ROUTE = "/openapi.json"
PROXY_ROUTE = "/api"
IDLE_TIMEOUT_SECONDS = 120
OUTBOUND_TIMEOUT_SECONDS = 100
HTTP_METHODS = ("get", "post", "put", "patch", "delete", "head", "options", "trace")
TOKEN = r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+"
HEADER_NAME = re.compile(rf"^{TOKEN}$")
PROHIBITED_HEADER_VALUE = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")
CONTENT_TYPE = re.compile(
    rf"^{TOKEN}/{TOKEN}(?:[ \t]*;[ \t]*{TOKEN}[ \t]*=[ \t]*"
    rf'(?:{TOKEN}|"(?:[\t !#-\[\]-~\x80-\xff]|\\[\t !-~\x80-\xff])*")'
    r")*[ \t]*$"
)
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


class ConfigurationError(ValueError):
    """Local configuration or OpenAPI input is invalid."""


@dataclass(frozen=True)
class Asset:
    name: str
    route: str
    content_type: str
    path: Path


@dataclass(frozen=True)
class Destination:
    url: str
    scheme: str
    host: str
    port: int | None
    path: str


@dataclass(frozen=True)
class Route:
    method: str
    template: str
    matcher: re.Pattern[str]
    suffix_pattern: str
    allowed_bases: tuple[re.Pattern[str], ...]

    @property
    def is_templated(self) -> bool:
        return "{" in self.template

    def destination(self, candidate: str) -> Destination:
        # Keep this as a direct fullmatch guard: the selected URL is permitted
        # only when config or an effective OpenAPI Server Object describes it.
        for allowed in self.allowed_bases:
            if allowed.fullmatch(candidate):
                return parse_destination(candidate, "Selected upstream base URL")
        raise ConfigurationError(
            "Selected upstream base URL is not declared by config or the "
            "effective OpenAPI Server Objects."
        )


ASSET_DEFINITIONS = (
    ("swagger-ui.css", "/assets/swagger-ui.css", "text/css; charset=utf-8"),
    (
        "swagger-ui-bundle.js",
        "/assets/swagger-ui-bundle.js",
        "application/javascript; charset=utf-8",
    ),
    (
        "swagger-ui-standalone-preset.js",
        "/assets/swagger-ui-standalone-preset.js",
        "application/javascript; charset=utf-8",
    ),
)


def resolve_path(base: Path, value: str) -> Path:
    path = Path(value)
    return (path if path.is_absolute() else base / path).resolve()


def header_name(name: str, source: str) -> str:
    if not HEADER_NAME.fullmatch(name):
        raise ValueError(f"{source} contains an invalid HTTP header name.")
    return name


def header_value(value: str, source: str) -> str:
    if PROHIBITED_HEADER_VALUE.search(value):
        raise ValueError(f"{source} contains a prohibited HTTP control character.")
    return value


def content_type(value: str, source: str) -> str:
    header_value(value, source)
    if not CONTENT_TYPE.fullmatch(value):
        raise ValueError(f"{source} is not a valid media type.")
    return value


def validated_headers(headers: Iterable[tuple[str, str]], source: str) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    for name, value in headers:
        name = str(name)
        value = str(value)
        header_name(name, f"{source} header")
        header_value(value, f"{source} header '{name}'")
        if name.casefold() == "content-type":
            content_type(value, f"{source} Content-Type")
        result.append((name, value))
    return result


def hop_by_hop_names(headers: Iterable[tuple[str, str]]) -> set[str]:
    result = set(FIXED_HOP_BY_HOP)
    for name, value in headers:
        if name.casefold() == "connection":
            for item in value.split(","):
                item = item.strip()
                if item:
                    header_name(item, "Connection")
                    result.add(item.casefold())
    return result


def parse_destination(value: str, source: str) -> Destination:
    if not isinstance(value, str) or not value.strip():
        raise ConfigurationError(f"{source} must be a non-empty URL.")
    value = value.strip().rstrip("/")
    if any(ord(character) <= 0x20 or ord(character) == 0x7F for character in value):
        raise ConfigurationError(f"{source} contains whitespace or a control character.")
    if "\\" in value:
        raise ConfigurationError(f"{source} must not contain a backslash.")

    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise ConfigurationError(f"{source} is not a valid URL: '{value}'.") from error
    if parsed.scheme.casefold() not in {"http", "https"} or not parsed.hostname:
        raise ConfigurationError(f"{source} must be an absolute HTTP or HTTPS URL: '{value}'.")
    if parsed.query or parsed.fragment:
        raise ConfigurationError(f"{source} must not contain a query or fragment: '{value}'.")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigurationError(f"{source} must not contain user information: '{value}'.")

    return Destination(
        url=value,
        scheme=parsed.scheme.casefold(),
        host=parsed.hostname,
        port=port,
        path=parsed.path.rstrip("/"),
    )


def resolve_reference(document: dict[str, Any], value: Any, kind: str) -> Any:
    resolved = value
    visited: set[str] = set()
    while isinstance(resolved, dict) and "$ref" in resolved:
        reference = resolved["$ref"]
        if not isinstance(reference, str) or not reference.startswith("#/"):
            raise ConfigurationError(
                f"External OpenAPI {kind} reference is not supported by the local proxy: {reference}"
            )
        if reference in visited:
            raise ConfigurationError(
                f"Cyclic OpenAPI {kind} reference is not supported by the local proxy: {reference}"
            )
        visited.add(reference)
        resolved = document
        for token in reference[2:].split("/"):
            key = token.replace("~1", "/").replace("~0", "~")
            if not isinstance(resolved, dict) or key not in resolved:
                raise ConfigurationError(f"OpenAPI {kind} reference did not resolve: {reference}")
            resolved = resolved[key]
    return resolved


def template_parts(template: str) -> Iterator[tuple[str, str | None]]:
    offset = 0
    for match in re.finditer(r"\{([^}]+)\}", template):
        yield template[offset : match.start()], None
        yield "", match.group(1)
        offset = match.end()
    yield template[offset:], None


def path_pattern(template: str) -> re.Pattern[str]:
    if template == "/":
        return re.compile(r"^/$")
    pieces = ["^"]
    for literal, variable in template_parts(template.rstrip("/")):
        pieces.append(r"[^/]+" if variable is not None else re.escape(literal))
    pieces.append(r"/?$")
    return re.compile("".join(pieces))


def javascript_suffix_pattern(template: str) -> str:
    if template == "/":
        return "/$"
    pieces: list[str] = []
    for literal, variable in template_parts(template.rstrip("/")):
        if variable is not None:
            pieces.append("[^/]+")
        else:
            pieces.append(re.sub(r"([\\^$.*+?()\[\]{}|])", r"\\\1", literal))
    pieces.append("/?$")
    return "".join(pieces)


def server_variables(server: dict[str, Any]) -> dict[str, Any]:
    variables = server.get("variables", {})
    if not isinstance(variables, dict):
        raise ConfigurationError("OpenAPI Server Object.variables must be an object.")
    return variables


def expand_server_url(server: Any, source: str) -> str:
    if not isinstance(server, dict):
        raise ConfigurationError(f"{source} must be an object.")
    template = server.get("url")
    if not isinstance(template, str) or not template.strip():
        raise ConfigurationError(f"{source} has no URL.")
    expanded = template
    variables = server_variables(server)
    for match in re.finditer(r"\{([^}]+)\}", template):
        name = match.group(1)
        variable = variables.get(name)
        if not isinstance(variable, dict) or "default" not in variable:
            raise ConfigurationError(f"OpenAPI server variable '{name}' has no default value.")
        default = variable["default"]
        if default is None or isinstance(default, (list, dict)):
            raise ConfigurationError(f"OpenAPI server variable '{name}' has an invalid default value.")
        expanded = expanded.replace("{" + name + "}", str(default))
    if re.search(r"\{[^}]+\}", expanded):
        raise ConfigurationError(f"{source} contains an unresolved variable: '{expanded}'.")
    return expanded


def server_base_pattern(server: Any) -> re.Pattern[str]:
    if not isinstance(server, dict):
        raise ConfigurationError("An effective OpenAPI Server Object must be an object.")
    template = server.get("url")
    if not isinstance(template, str) or not template.strip():
        raise ConfigurationError("An effective OpenAPI Server Object has no URL.")

    # Validate the default rendering as a usable destination as well as the
    # complete family of renderings accepted below.
    parse_destination(expand_server_url(server, "An effective OpenAPI server"), "OpenAPI server")
    variables = server_variables(server)
    pieces = ["^"]
    for literal, variable_name in template_parts(template.rstrip("/")):
        if variable_name is None:
            pieces.append(re.escape(literal))
            continue
        variable = variables.get(variable_name)
        if not isinstance(variable, dict):
            raise ConfigurationError(
                f"OpenAPI server URL references undeclared variable '{variable_name}'."
            )
        choices = variable.get("enum")
        if choices is not None:
            if not isinstance(choices, list) or not choices:
                raise ConfigurationError(
                    f"OpenAPI server variable '{variable_name}'.enum must be a non-empty array."
                )
            if any(choice is None or isinstance(choice, (list, dict)) for choice in choices):
                raise ConfigurationError(
                    f"OpenAPI server variable '{variable_name}'.enum contains a non-scalar value."
                )
            pieces.append("(?:" + "|".join(re.escape(str(choice)) for choice in choices) + ")")
        else:
            pieces.append(r"[^?#]+?")
    pieces.append(r"/?$")
    return re.compile("".join(pieces), re.IGNORECASE)


def server_list(container: dict[str, Any], inherited: list[Any], source: str) -> list[Any]:
    if "servers" not in container:
        return inherited
    servers = container["servers"]
    if not isinstance(servers, list):
        raise ConfigurationError(f"{source}.servers must be an array.")
    return servers


def build_routes(document: dict[str, Any], configured_base: str | None) -> list[Route]:
    paths = document.get("paths")
    if not isinstance(paths, dict):
        raise ConfigurationError("OpenAPI document.paths must be an object.")
    root_servers = server_list(document, [], "OpenAPI document")
    configured_pattern = (
        re.compile(r"^" + re.escape(configured_base.rstrip("/")) + r"/?$", re.IGNORECASE)
        if configured_base
        else None
    )

    routes: list[Route] = []
    for template, unresolved in paths.items():
        if not isinstance(template, str) or not template.startswith("/"):
            raise ConfigurationError("Every OpenAPI path template must begin with '/'.")
        path_item = resolve_reference(document, unresolved, "Path Item")
        if not isinstance(path_item, dict):
            raise ConfigurationError(f"OpenAPI Path Item '{template}' must resolve to an object.")
        path_servers = server_list(path_item, root_servers, f"OpenAPI path '{template}'")
        for method in HTTP_METHODS:
            operation = path_item.get(method)
            if not isinstance(operation, dict):
                continue
            effective = server_list(
                operation,
                path_servers,
                f"OpenAPI operation {method.upper()} {template}",
            )
            allowed = ([configured_pattern] if configured_pattern is not None else []) + [
                server_base_pattern(server) for server in effective
            ]
            if not allowed:
                raise ConfigurationError(
                    f"OpenAPI operation {method.upper()} {template} has no effective upstream server."
                )
            routes.append(
                Route(
                    method=method.upper(),
                    template=template,
                    matcher=path_pattern(template),
                    suffix_pattern=javascript_suffix_pattern(template),
                    allowed_bases=tuple(allowed),
                )
            )
    if not routes:
        raise ConfigurationError("The OpenAPI document declares no supported HTTP operations.")
    return routes


def find_route(routes: list[Route], method: str, path: str) -> tuple[Route | None, bool]:
    matches = [route for route in routes if route.matcher.fullmatch(path)]
    matching_method = [route for route in matches if route.method == method]
    matching_method.sort(key=lambda route: route.is_templated)
    return (matching_method[0] if matching_method else None, bool(matches))


def validate_configured_headers(value: Any) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ConfigurationError("Config upstream.requestHeaders must be an object or null.")
    result: dict[str, str] = {}
    for raw_name, raw_value in value.items():
        name = str(raw_name)
        if raw_value is None or isinstance(raw_value, (list, dict)):
            raise ConfigurationError(f"Config upstream.requestHeaders.{name} must be a scalar value.")
        rendered = str(raw_value)
        try:
            header_name(name, f"Config upstream.requestHeaders.{name}")
            header_value(rendered, f"Config upstream.requestHeaders.{name}")
            if name.casefold() == "content-type":
                content_type(rendered, "Config upstream.requestHeaders.Content-Type")
        except ValueError as error:
            raise ConfigurationError(str(error)) from error
        folded = name.casefold()
        if folded == SERVER_SELECTION_HEADER.casefold():
            raise ConfigurationError(
                f"Config upstream.requestHeaders cannot set reserved header '{SERVER_SELECTION_HEADER}'."
            )
        if folded in FIXED_HOP_BY_HOP:
            raise ConfigurationError(
                f"Config upstream.requestHeaders cannot set hop-by-hop header '{name}'."
            )
        if folded in {"host", "content-length"}:
            raise ConfigurationError(
                f"Config upstream.requestHeaders cannot set transport-managed header '{name}'."
            )
        result[name] = rendered
    return result


def configured_default(document: dict[str, Any], upstream: dict[str, Any]) -> tuple[Destination, str | None]:
    configured = upstream.get("baseUrl")
    if configured is not None and not isinstance(configured, str):
        raise ConfigurationError("Config upstream.baseUrl must be a string or null.")
    configured = configured.strip() if isinstance(configured, str) else ""
    if configured:
        destination = parse_destination(configured, "Config upstream.baseUrl")
        return destination, destination.url

    servers = document.get("servers")
    if not isinstance(servers, list) or not servers:
        raise ConfigurationError(
            "Config upstream.baseUrl is empty and the OpenAPI document declares no root servers."
        )
    expanded = expand_server_url(servers[0], "The first root OpenAPI Server Object")
    return parse_destination(expanded, "The first root OpenAPI server"), None


def runtime_spec(document: dict[str, Any], configured_base: str | None) -> dict[str, Any]:
    if configured_base is None:
        return document
    result = copy.deepcopy(document)
    existing = result.get("servers")
    if existing is not None and not isinstance(existing, list):
        raise ConfigurationError("OpenAPI document.servers must be an array.")
    existing = existing or []
    matching = next(
        (
            server
            for server in existing
            if isinstance(server, dict)
            and isinstance(server.get("url"), str)
            and server["url"].casefold() == configured_base.casefold()
        ),
        None,
    )
    first = matching if matching is not None else {"url": configured_base}
    result["servers"] = [first] + [server for server in existing if server is not matching]
    return result


def relative_config_spec(config_directory: Path, spec_path: Path) -> str:
    try:
        value = os.path.relpath(spec_path, config_directory).replace(os.sep, "/")
    except ValueError:
        return str(spec_path)
    return value if value.startswith(".") else "./" + value


def write_config_atomic(path: Path, settings: dict[str, Any]) -> None:
    payload = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=path.name + ".", suffix=".new", dir=path.parent, delete=False
        ) as stream:
            temporary = stream.name
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        # Linking publishes the fully-written file atomically and, unlike
        # replace(), cannot overwrite a config created by another launcher.
        os.link(temporary, path)
        Path(temporary).unlink()
        temporary = None
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


def install_swagger_ui(cache: Path) -> list[Asset]:
    version_directory = cache / SWAGGER_UI_VERSION
    assets = [
        Asset(name, route, media_type, version_directory / name)
        for name, route, media_type in ASSET_DEFINITIONS
    ]
    if all(asset.path.is_file() for asset in assets):
        return assets

    cache.mkdir(parents=True, exist_ok=True)
    version_directory.mkdir(parents=True, exist_ok=True)
    archive_path = cache / f"swagger-ui-v{SWAGGER_UI_VERSION}.zip"
    if not archive_path.is_file():
        release_request = urllib.request.Request(
            "https://api.github.com/repos/swagger-api/swagger-ui/releases/tags/"
            f"v{SWAGGER_UI_VERSION}",
            headers={"User-Agent": "netizen"},
        )
        with urllib.request.urlopen(release_request, timeout=30) as response:
            release = json.load(response)
        archive_url = release.get("zipball_url")
        if not isinstance(archive_url, str) or not archive_url:
            raise RuntimeError(
                f"Swagger UI release v{SWAGGER_UI_VERSION} did not provide a source archive."
            )
        download = archive_path.with_name(archive_path.name + ".download")
        print(f"Downloading Swagger UI v{SWAGGER_UI_VERSION}...")
        try:
            request = urllib.request.Request(archive_url, headers={"User-Agent": "netizen"})
            with urllib.request.urlopen(request, timeout=60) as source, download.open("wb") as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
            os.replace(download, archive_path)
        finally:
            download.unlink(missing_ok=True)

    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        for asset in assets:
            matches = [
                name
                for name in names
                if name == f"dist/{asset.name}" or name.endswith(f"/dist/{asset.name}")
            ]
            if len(matches) != 1:
                raise RuntimeError(
                    f"Swagger UI v{SWAGGER_UI_VERSION} archive must contain exactly one "
                    f"dist/{asset.name}; found {len(matches)}."
                )
            temporary = asset.path.with_name(asset.path.name + ".extract")
            try:
                with archive.open(matches[0]) as source, temporary.open("wb") as target:
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
                os.replace(temporary, asset.path)
            finally:
                temporary.unlink(missing_ok=True)
    return assets


def html_json(value: Any) -> str:
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        .replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def swagger_html(title: str, routes: list[Route], asset_routes: list[str]) -> bytes:
    runtime = {
        "specRoute": SPEC_ROUTE,
        "proxyRoute": PROXY_ROUTE,
        "localRoutes": [SPEC_ROUTE, *asset_routes],
        "serverSelectionHeader": SERVER_SELECTION_HEADER,
        "routes": [
            {"method": route.method, "suffixPattern": route.suffix_pattern}
            for route in sorted(routes, key=lambda route: (route.is_templated, -len(route.template)))
        ],
    }
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{html.escape(title, quote=True)}</title>
  <link rel="stylesheet" href="/assets/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="/assets/swagger-ui-bundle.js"></script>
<script src="/assets/swagger-ui-standalone-preset.js"></script>
<script>
const NETIZEN={html_json(runtime)};
const ROUTES=NETIZEN.routes.map(route=>({{...route,matcher:new RegExp(route.suffixPattern)}}));
function requestInterceptor(req){{
  const target=new URL(req.url,window.location.origin);
  if(target.origin===window.location.origin&&NETIZEN.localRoutes.includes(target.pathname))return req;
  if(target.origin===window.location.origin&&(target.pathname===NETIZEN.proxyRoute||target.pathname.startsWith(NETIZEN.proxyRoute+'/')))return req;
  const method=(req.method||'GET').toUpperCase();
  let selected=null;
  for(const route of ROUTES){{
    if(route.method!==method)continue;
    const match=route.matcher.exec(target.pathname);
    if(match){{selected=match;break;}}
  }}
  if(!selected)throw new Error('Swagger request did not match a declared OpenAPI operation.');
  const selectedBase=target.origin+target.pathname.slice(0,selected.index);
  req.headers=Object.assign({{}},req.headers||{{}},{{[NETIZEN.serverSelectionHeader]:selectedBase}});
  req.url=window.location.origin+NETIZEN.proxyRoute+selected[0]+target.search;
  return req;
}}
SwaggerUIBundle({{
  url:NETIZEN.specRoute,
  dom_id:'#swagger-ui',
  presets:[SwaggerUIBundle.presets.apis,SwaggerUIStandalonePreset],
  layout:'StandaloneLayout',
  tryItOutEnabled:true,
  validatorUrl:null,
  requestInterceptor
}});
</script>
</body>
</html>
""".encode("utf-8")


class Runtime:
    def __init__(
        self,
        document: dict[str, Any],
        served_document: dict[str, Any],
        routes: list[Route],
        default_destination: Destination,
        configured_headers: dict[str, str],
        assets: list[Asset],
    ) -> None:
        self.routes = routes
        self.default_destination = default_destination
        self.configured_headers = configured_headers
        self.assets = {asset.route: asset for asset in assets}
        self.index = swagger_html(
            str(document["info"]["title"]), routes, [asset.route for asset in assets]
        )
        self.spec = json.dumps(served_document, ensure_ascii=False, indent=2).encode("utf-8")
        self.last_activity = time.monotonic()
        self.loaded = False
        self.activity_lock = threading.Lock()

    def record(self, initial_load: bool = False) -> None:
        with self.activity_lock:
            self.last_activity = time.monotonic()
            self.loaded = self.loaded or initial_load


class NetizenServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        handler: type[http.server.BaseHTTPRequestHandler],
        runtime: Runtime,
    ) -> None:
        self.runtime = runtime
        super().__init__(address, handler)


class NetizenHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def runtime(self) -> Runtime:
        return self.server.runtime  # type: ignore[attr-defined, no-any-return]

    def do_GET(self) -> None:
        self.handle_request()

    def do_POST(self) -> None:
        self.handle_request()

    def do_PUT(self) -> None:
        self.handle_request()

    def do_PATCH(self) -> None:
        self.handle_request()

    def do_DELETE(self) -> None:
        self.handle_request()

    def do_HEAD(self) -> None:
        self.handle_request()

    def do_OPTIONS(self) -> None:
        self.handle_request()

    def do_TRACE(self) -> None:
        self.handle_request()

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def send_bytes(
        self,
        status: int,
        body: bytes,
        response_headers: Iterable[tuple[str, str]] = (),
    ) -> None:
        if not 100 <= status <= 599:
            raise ValueError(f"Invalid HTTP response status code: {status}")
        headers = validated_headers(response_headers, "Response")
        headers = [(name, value) for name, value in headers if name.casefold() != "content-length"]
        self.send_response_only(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def failure(self, status: int, code: str) -> None:
        body = json.dumps({"error": code}, separators=(",", ":")).encode("utf-8")
        self.send_bytes(status, body, [("Content-Type", "application/json; charset=utf-8")])

    def handle_request(self) -> None:
        target = urllib.parse.urlsplit(self.path)
        path = target.path
        self.runtime.record(path == "/")
        response_started = False
        try:
            if path == "/":
                response_started = True
                self.send_bytes(200, self.runtime.index, [("Content-Type", "text/html; charset=utf-8")])
                return
            if path == SPEC_ROUTE:
                response_started = True
                self.send_bytes(
                    200, self.runtime.spec, [("Content-Type", "application/json; charset=utf-8")]
                )
                return
            asset = self.runtime.assets.get(path)
            if asset is not None:
                response_started = True
                self.send_bytes(200, asset.path.read_bytes(), [("Content-Type", asset.content_type)])
                return

            if path == PROXY_ROUTE:
                api_path = "/"
            elif path.startswith(PROXY_ROUTE + "/"):
                api_path = path[len(PROXY_ROUTE) :]
            else:
                response_started = True
                self.failure(404, "route_not_found")
                return

            route, path_matched = find_route(self.runtime.routes, self.command, api_path)
            if route is None:
                response_started = True
                self.failure(
                    405 if path_matched else 404,
                    "method_not_allowed" if path_matched else "openapi_route_not_found",
                )
                return
            try:
                destination = self.selected_destination(route)
            except (ConfigurationError, ValueError):
                response_started = True
                self.failure(400, "invalid_upstream_base")
                return

            response_started = True
            self.proxy(route, destination, api_path, target.query)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as error:
            print(f"Warning: local request failed: {error}", file=sys.stderr)
            if not response_started:
                try:
                    self.failure(500, "local_request_failed")
                except Exception:
                    pass

    def selected_destination(self, route: Route) -> Destination:
        values = self.headers.get_all(SERVER_SELECTION_HEADER)
        if values is None:
            candidate = self.runtime.default_destination.url
        elif len(values) == 1 and values[0].strip():
            candidate = header_value(values[0].strip(), f"Header '{SERVER_SELECTION_HEADER}'")
        else:
            raise ConfigurationError(
                f"Header '{SERVER_SELECTION_HEADER}' must contain exactly one non-empty value."
            )
        return route.destination(candidate)

    def request_body(self) -> tuple[bytes, bool]:
        transfer_encodings = self.headers.get_all("Transfer-Encoding") or []
        content_lengths = self.headers.get_all("Content-Length") or []
        if transfer_encodings and content_lengths:
            raise ValueError("Request must not contain both Transfer-Encoding and Content-Length.")
        if transfer_encodings:
            if len(transfer_encodings) != 1 or transfer_encodings[0].casefold().strip() != "chunked":
                raise ValueError("Unsupported request Transfer-Encoding.")
            return self.read_chunked_body(), True
        if not content_lengths:
            return b"", False
        if len(content_lengths) != 1 or not re.fullmatch(r"[0-9]+", content_lengths[0].strip()):
            raise ValueError("Invalid request Content-Length.")
        length = int(content_lengths[0])
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("Request body ended before Content-Length bytes were read.")
        return body, True

    def read_chunked_body(self) -> bytes:
        chunks: list[bytes] = []
        while True:
            line = self.rfile.readline(65537)
            if not line or len(line) > 65536 or not line.endswith(b"\r\n"):
                raise ValueError("Invalid chunked request body.")
            try:
                size = int(line[:-2].split(b";", 1)[0], 16)
            except ValueError as error:
                raise ValueError("Invalid chunked request body.") from error
            if size < 0:
                raise ValueError("Invalid chunked request body.")
            if size == 0:
                while True:
                    trailer = self.rfile.readline(65537)
                    if trailer == b"\r\n":
                        return b"".join(chunks)
                    if not trailer or len(trailer) > 65536 or not trailer.endswith(b"\r\n"):
                        raise ValueError("Invalid chunked request trailer.")
            chunk = self.rfile.read(size)
            if len(chunk) != size or self.rfile.read(2) != b"\r\n":
                raise ValueError("Invalid chunked request body.")
            chunks.append(chunk)

    def proxy(self, route: Route, destination: Destination, api_path: str, query: str) -> None:
        connection: http.client.HTTPConnection | None = None
        try:
            inbound = validated_headers(self.headers.raw_items(), "Request")
            body, had_framing = self.request_body()
            excluded = hop_by_hop_names(inbound)
            excluded.update(
                {"host", "content-length", SERVER_SELECTION_HEADER.casefold()}
            )
            configured = {
                name.casefold(): (name, value)
                for name, value in self.runtime.configured_headers.items()
            }
            outbound = [
                (name, value)
                for name, value in inbound
                if name.casefold() not in excluded and name.casefold() not in configured
            ]
            outbound.extend(configured.values())
            has_content_metadata = any(name.casefold().startswith("content-") for name, _ in outbound)

            path = destination.path + api_path
            if not path:
                path = "/"
            if query:
                path += "?" + query

            connection_type: type[http.client.HTTPConnection]
            connection_type = (
                http.client.HTTPSConnection
                if destination.scheme == "https"
                else http.client.HTTPConnection
            )
            arguments: dict[str, Any] = {"timeout": OUTBOUND_TIMEOUT_SECONDS}
            if destination.scheme == "https":
                arguments["context"] = ssl.create_default_context()
            connection = connection_type(destination.host, destination.port, **arguments)
            connection.putrequest(self.command, path, skip_accept_encoding=True)
            for name, value in outbound:
                connection.putheader(name, value)
            if body or had_framing or has_content_metadata:
                connection.putheader("Content-Length", str(len(body)))
            connection.endheaders(body if body else None)

            upstream = connection.getresponse()
            response_body = upstream.read()
            response_headers = validated_headers(upstream.getheaders(), "Upstream response")
            content_types = [
                value for name, value in response_headers if name.casefold() == "content-type"
            ]
            if len(content_types) > 1:
                raise ValueError("Upstream response contained multiple Content-Type values.")
            excluded_response = hop_by_hop_names(response_headers)
            excluded_response.update({"content-length", "content-type"})
            response_headers = [
                (name, value)
                for name, value in response_headers
                if name.casefold() not in excluded_response
            ]
            if content_types:
                response_headers.append(("Content-Type", content_types[0]))
            self.send_bytes(upstream.status, response_body, response_headers)
        except (OSError, http.client.HTTPException, ssl.SSLError, ValueError) as error:
            print(f"Warning: upstream request failed: {error}", file=sys.stderr)
            self.failure(502, "upstream_request_failed")
        finally:
            if connection is not None:
                connection.close()


def load_runtime(
    script_directory: Path,
    config_path: Path,
    explicit_spec: str | None,
) -> tuple[Runtime, Path, str]:
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
            "upstream": {"baseUrl": None, "requestHeaders": {}},
        }

    upstream = settings.get("upstream")
    if upstream is None:
        upstream = {"baseUrl": None, "requestHeaders": {}}
        settings["upstream"] = upstream
    if not isinstance(upstream, dict):
        raise ConfigurationError("Config upstream must be an object or null.")
    configured_headers = validate_configured_headers(upstream.get("requestHeaders"))

    if explicit_spec is not None:
        spec_path = resolve_path(Path.cwd(), explicit_spec)
    else:
        configured_spec = settings.get("specPath")
        if configured_spec is not None and not isinstance(configured_spec, str):
            raise ConfigurationError("Config specPath must be a string or null.")
        if isinstance(configured_spec, str) and configured_spec.strip():
            spec_path = resolve_path(config_path.parent, configured_spec)
        else:
            pattern = re.compile(r"_openapi_v\d+(?:\.\d+)+\.json$", re.IGNORECASE)
            discovered = sorted(
                (
                    path
                    for path in script_directory.glob("*.json")
                    if path.is_file() and pattern.search(path.name)
                ),
                key=lambda path: path.name.casefold(),
            )
            if not discovered:
                raise ConfigurationError(
                    "No OpenAPI document was selected: use --spec, set config specPath, "
                    "or place exactly one versioned OpenAPI JSON file beside serve.py."
                )
            if len(discovered) != 1:
                raise ConfigurationError(
                    "Multiple adjacent OpenAPI documents were found "
                    f"({', '.join(path.name for path in discovered)}): use --spec or config specPath."
                )
            spec_path = discovered[0].resolve()
    if not spec_path.is_file():
        raise ConfigurationError(f"OpenAPI document not found: {spec_path}")

    source = spec_path.read_text(encoding="utf-8-sig")
    document = json.loads(source)
    if not isinstance(document, dict):
        raise ConfigurationError("The OpenAPI document root must be an object.")
    for name in ("openapi", "info", "paths"):
        if name not in document or document[name] is None:
            raise ConfigurationError(f"OpenAPI document property '{name}' is required.")
    if not isinstance(document["info"], dict) or not isinstance(document["info"].get("title"), str):
        raise ConfigurationError("OpenAPI document property 'info.title' is required.")
    if not document["info"]["title"].strip():
        raise ConfigurationError("OpenAPI document property 'info.title' is required.")

    default_destination, configured_base = configured_default(document, upstream)
    routes = build_routes(document, configured_base)
    # The default is subjected to the same operation allowlist at request time;
    # this validates its syntax before config creation without inventing routes.
    served_document = runtime_spec(document, configured_base)

    if not config_exists:
        settings["specPath"] = relative_config_spec(config_path.parent, spec_path)
        upstream.setdefault("baseUrl", None)
        upstream.setdefault("requestHeaders", {})
        write_config_atomic(config_path, settings)
        print(f"Created configuration: {config_path}")

    assets = install_swagger_ui(script_directory / ".swagger-ui")
    return (
        Runtime(
            document,
            served_document,
            routes,
            default_destination,
            configured_headers,
            assets,
        ),
        spec_path,
        str(document["openapi"]),
    )


def port_number(value: str) -> int:
    try:
        port = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("port must be an integer") from error
    if not 1 <= port <= 65525:
        raise argparse.ArgumentTypeError("port must be between 1 and 65525")
    return port


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Open a Netizen document in a local Swagger UI.")
    parser.add_argument("-c", "--config", help="Configuration file (default: adjacent config.json)")
    parser.add_argument(
        "-s", "--spec", help="OpenAPI document; takes precedence over config and discovery"
    )
    parser.add_argument("-p", "--port", type=port_number, default=8080, help="Preferred loopback port")
    parser.add_argument(
        "-k",
        "--keep-alive",
        action="store_true",
        help="Disable the 120-second post-load inactivity shutdown",
    )
    return parser.parse_args(argv)


def bind(runtime: Runtime, preferred: int) -> tuple[NetizenServer, int]:
    last_error: OSError | None = None
    for port in range(preferred, preferred + 11):
        try:
            return NetizenServer(("127.0.0.1", port), NetizenHandler, runtime), port
        except OSError as error:
            last_error = error
    raise OSError(
        f"Could not bind to any port in range {preferred}-{preferred + 10}. {last_error}"
    )


def idle_watcher(server: NetizenServer, runtime: Runtime) -> None:
    while True:
        time.sleep(1)
        with runtime.activity_lock:
            expired = runtime.loaded and time.monotonic() - runtime.last_activity >= IDLE_TIMEOUT_SECONDS
        if expired:
            print(f"No activity for {IDLE_TIMEOUT_SECONDS} seconds - shutting down.")
            server.shutdown()
            return


def open_browser(url: str) -> None:
    try:
        if not webbrowser.open(url):
            raise RuntimeError("no browser accepted the URL")
    except Exception:
        print(f"Warning: could not open the browser automatically. Open {url} manually.", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args = arguments(argv)
    if args.config is not None and not args.config.strip():
        raise ConfigurationError("--config must name a configuration file when supplied.")
    if args.spec is not None and not args.spec.strip():
        raise ConfigurationError("--spec must name an OpenAPI document when supplied.")

    script_directory = Path(__file__).resolve().parent
    config_path = (
        resolve_path(Path.cwd(), args.config)
        if args.config is not None
        else script_directory / "config.json"
    )
    runtime, spec_path, openapi_version = load_runtime(
        script_directory, config_path, args.spec
    )
    server, port = bind(runtime, args.port)
    url = f"http://127.0.0.1:{port}/"
    print(f"Serving configuration: {config_path.resolve()}")
    print(f"Serving OpenAPI document: {spec_path}")
    print(f"Default upstream: {runtime.default_destination.url}")
    print(f"Loaded OpenAPI operations: {len(runtime.routes)}")
    print(f"OpenAPI version: {openapi_version}")
    print(f"Open: {url}")
    if args.keep_alive:
        print("KeepAlive enabled - Ctrl+C to stop.")
    else:
        print(
            f"Auto-stops after {IDLE_TIMEOUT_SECONDS} seconds of inactivity following the initial page load."
        )

    threading.Timer(0.5, open_browser, args=(url,)).start()
    if not args.keep_alive:
        threading.Thread(target=idle_watcher, args=(server, runtime), daemon=True).start()
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
    try:
        raise SystemExit(main())
    except (ConfigurationError, json.JSONDecodeError, OSError, RuntimeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
