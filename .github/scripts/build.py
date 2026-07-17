#!/usr/bin/env python3
"""Validate Netizen sources and build the published catalog, specs, and ZIPs."""

from __future__ import annotations

import argparse
import copy
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SPEC_NAME = re.compile(
    r"^(?P<vendor>[a-z0-9]+(?:-[a-z0-9]+)*)_openapi_v"
    r"(?P<dialect>\d+\.\d+\.\d+)\.json$"
)
HTTP_METHODS = {"get", "post", "put", "patch", "delete", "head", "options", "trace"}
CATALOG_FIELDS = ("name", "description", "tags", "site", "upstream")
SITE_FILES = (
    "index.html",
    "favicon.svg",
    "social-preview.png",
    "LICENSE",
    "LICENSE-CONTENT",
)


class BuildError(RuntimeError):
    """Repository sources cannot produce a valid Netizen publication."""


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages-dir", type=Path, required=True)
    parser.add_argument("--dist-dir", type=Path, required=True)
    return parser.parse_args()


def reset_directory(path: Path) -> Path:
    resolved = path.resolve()
    if resolved == ROOT or ROOT not in resolved.parents:
        raise BuildError(f"Build output must be inside the repository: {resolved}")
    if resolved.exists():
        shutil.rmtree(resolved)
    resolved.mkdir(parents=True)
    return resolved


def read_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        raise BuildError(f"{path.relative_to(ROOT)} is not readable JSON: {error}") from error
    if not isinstance(value, dict):
        raise BuildError(f"{path.relative_to(ROOT)} must contain a JSON object.")
    return value


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise BuildError(f"{label} must be an object.")
    return value


def require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BuildError(f"{label} must be a non-empty string.")
    return value


def netizen_version(relative_path: Path) -> int:
    result = subprocess.run(
        ["git", "log", "--follow", "--format=%H", "--", relative_path.as_posix()],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    commits = {line for line in result.stdout.splitlines() if line}
    if not commits:
        print(
            f"WARNING: {relative_path.as_posix()} has no committed history; "
            "using Netizen revision 1 for this local build.",
            file=sys.stderr,
        )
        return 1
    return len(commits)


def operation_count(paths: dict[str, Any]) -> int:
    count = 0
    for template, path_item in paths.items():
        if not isinstance(path_item, dict):
            raise BuildError(f"OpenAPI path {template!r} must be an object.")
        count += sum(1 for method in HTTP_METHODS if method in path_item)
    return count


def catalog_metadata(spec: dict[str, Any], relative_path: Path) -> dict[str, Any]:
    extension = require_object(spec.get("x-netizen"), f"{relative_path}: x-netizen")
    unexpected = sorted(set(extension) - {"catalog"})
    if unexpected:
        raise BuildError(
            f"{relative_path}: source x-netizen contains derived fields: {', '.join(unexpected)}"
        )
    catalog = require_object(extension.get("catalog"), f"{relative_path}: x-netizen.catalog")
    for field in CATALOG_FIELDS:
        if field == "upstream" and catalog.get(field) is None:
            continue
        if field == "tags":
            tags = catalog.get(field)
            if (
                not isinstance(tags, list)
                or not tags
                or any(not isinstance(tag, str) or not tag.strip() for tag in tags)
            ):
                raise BuildError(f"{relative_path}: x-netizen.catalog.tags must be string[].")
            continue
        require_text(catalog.get(field), f"{relative_path}: x-netizen.catalog.{field}")
    unexpected_catalog = sorted(set(catalog) - set(CATALOG_FIELDS))
    if unexpected_catalog:
        raise BuildError(
            f"{relative_path}: unexpected x-netizen.catalog fields: "
            f"{', '.join(unexpected_catalog)}"
        )
    return copy.deepcopy(catalog)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def guide_archive_source(path: Path) -> Path:
    if path.is_symlink():
        return path
    return (path.parent / path.read_text(encoding="utf-8").strip()).resolve()


def create_zip(path: Path, spec_path: Path, spec_name: str, guide_path: Path) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.write(spec_path, spec_name)
        archive.write(ROOT / "serve.ps1", "serve.ps1")
        archive.write(ROOT / "serve.py", "serve.py")
        archive.write(guide_archive_source(guide_path), "AGENTS.md")


def is_root_guide_link(path: Path) -> bool:
    if path.is_symlink():
        return path.resolve() == (ROOT / "AGENTS.md").resolve()
    if not path.is_file() or path.read_text(encoding="utf-8") != "../AGENTS.md":
        return False
    result = subprocess.run(
        ["git", "ls-files", "-s", "--", path.relative_to(ROOT).as_posix()],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.startswith("120000 ")


def discover_sources() -> dict[str, list[Path]]:
    vendors: dict[str, list[Path]] = {}
    for directory in sorted(ROOT.iterdir()):
        if not directory.is_dir() or directory.name.startswith(".") or directory.name.endswith(".local"):
            continue
        specs = sorted(directory.glob("*_openapi_v*.json"))
        if not specs:
            continue
        guide = directory / "AGENTS.md"
        allowed_entries = set(specs)
        if not (guide.exists() or guide.is_symlink()) or not is_root_guide_link(guide):
            raise BuildError(
                f"{directory.name}/AGENTS.md must be a symlink to ../AGENTS.md."
            )
        allowed_entries.add(guide)
        other_entries = sorted(entry.name for entry in directory.iterdir() if entry not in allowed_entries)
        if other_entries:
            raise BuildError(
                f"{directory.name}/ must contain only OpenAPI specs; found: "
                f"{', '.join(other_entries)}"
            )
        vendors[directory.name] = specs
    if not vendors:
        raise BuildError("No vendor OpenAPI specs were discovered.")
    return vendors


def build(pages_dir: Path, dist_dir: Path) -> None:
    for package_source in ("serve.ps1", "serve.py", "AGENTS.md"):
        if not (ROOT / package_source).is_file():
            raise BuildError(f"Required package source is missing: {package_source}")

    pages_dir = reset_directory(pages_dir)
    dist_dir = reset_directory(dist_dir)
    for name in SITE_FILES:
        source = ROOT / name
        if not source.is_file():
            raise BuildError(f"Required Pages source is missing: {name}")
        shutil.copy2(source, pages_dir / name)

    catalog: dict[str, Any] = {}
    spec_total = 0
    for vendor, source_specs in discover_sources().items():
        vendor_catalog: dict[str, Any] | None = None
        editions: list[dict[str, Any]] = []

        for source_path in source_specs:
            match = SPEC_NAME.fullmatch(source_path.name)
            if match is None:
                raise BuildError(f"Invalid spec filename: {source_path.relative_to(ROOT)}")
            if match.group("vendor") != vendor:
                raise BuildError(
                    f"{source_path.relative_to(ROOT)} must use vendor prefix {vendor!r}."
                )

            relative_path = source_path.relative_to(ROOT)
            spec = read_object(source_path)
            openapi_version = require_text(spec.get("openapi"), f"{relative_path}: openapi")
            if openapi_version != match.group("dialect"):
                raise BuildError(
                    f"{relative_path}: filename dialect {match.group('dialect')} "
                    f"does not match openapi {openapi_version}."
                )
            info = require_object(spec.get("info"), f"{relative_path}: info")
            vendor_version = require_text(info.get("version"), f"{relative_path}: info.version")
            require_text(info.get("title"), f"{relative_path}: info.title")
            paths = require_object(spec.get("paths"), f"{relative_path}: paths")
            curated = catalog_metadata(spec, relative_path)
            if vendor_catalog is None:
                vendor_catalog = curated
            elif vendor_catalog != curated:
                raise BuildError(
                    f"{vendor}/ specs must carry identical x-netizen.catalog metadata."
                )

            revision = netizen_version(relative_path)
            published_spec = copy.deepcopy(spec)
            published_spec["x-netizen"]["version"] = revision
            published_spec_path = pages_dir / vendor / source_path.name
            write_json(published_spec_path, published_spec)

            artifact_name = f"{source_path.stem}.zip"
            create_zip(
                dist_dir / artifact_name,
                published_spec_path,
                source_path.name,
                source_path.parent / "AGENTS.md",
            )
            editions.append(
                {
                    "specFile": source_path.name,
                    "artifactFile": artifact_name,
                    "vendorVersion": vendor_version,
                    "netizenVersion": revision,
                    "openapiVersion": openapi_version,
                    "paths": len(paths),
                    "operations": operation_count(paths),
                }
            )
            spec_total += 1

        assert vendor_catalog is not None
        vendor_catalog["specs"] = editions
        catalog[vendor] = vendor_catalog

    write_json(pages_dir / "catalog.json", catalog)
    print(
        f"Built {len(catalog)} vendors, {spec_total} specs, "
        f"{len(list(dist_dir.glob('*.zip')))} ZIPs."
    )


def main() -> int:
    args = parse_arguments()
    try:
        build(args.pages_dir, args.dist_dir)
    except (BuildError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
