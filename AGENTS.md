# Netizen Assistant Guide

This guidance applies in two related contexts:

- the Netizen source repository, where vendor directories contain maintained
  OpenAPI documents; and
- an extracted Netizen ZIP, where one OpenAPI document is packaged with the
  local launchers.

Determine which context you are in from the files present before making changes.

## OpenAPI document

The `*_openapi_v*.json` file is the maintained API contract. Keep these version
dimensions distinct:

- `info.version` is the vendor or source API version;
- `openapi` is the OpenAPI dialect;
- published `x-netizen.version` is the Git-derived Netizen revision.

In repository source, `x-netizen` contains curated `catalog` metadata only.
Publication adds `x-netizen.version` to a generated copy. Do not manually add or
increment that derived field.

## Local launchers

`serve.ps1` and `serve.py` are equivalent local launchers. They generate the
Swagger UI at runtime, proxy declared OpenAPI operations, and open a loopback
browser URL.

Spec selection precedence is:

1. explicit `-Spec` or `--spec`;
2. `specPath` in the configuration file;
3. exactly one adjacent versioned OpenAPI JSON file;
4. failure.

An extracted ZIP normally contains exactly one spec, so either launcher can be
run without arguments:

```powershell
pwsh ./serve.ps1
```

```shell
python ./serve.py
```

## `netizen.config.json`

Unless `-Config` or `--config` names another path, the launcher uses
`netizen.config.json` beside itself. If the file is absent, it is created only
after the spec has been resolved and validated unambiguously.

The generated shape is:

```json
{
  "specPath": "./vendor_openapi_v3.0.3.json",
  "upstream": {
    "baseUrl": null,
    "requestHeaders": {}
  }
}
```

- `specPath` selects the spec relative to the config file.
- A null, blank, or absent `upstream.baseUrl` derives the default upstream from
  the first root OpenAPI Server Object.
- A populated `upstream.baseUrl` overrides that default in the runtime copy; it
  does not modify the source spec.
- `upstream.requestHeaders` adds or replaces outbound request headers. It is the
  local place for API keys or other required headers.

Treat `netizen.config.json` as local state. It may contain credentials; do not
publish, commit, or copy it into the OpenAPI document. `.swagger-ui/` is also
generated local state containing cached UI assets.

## Repository context

Vendor directories contain specs and an `AGENTS.md` symlink to this file. Root
`serve.ps1`, `serve.py`, and `AGENTS.md` are copied into every generated ZIP.
`.github/scripts/build.py` validates sources and generates the public catalog,
stamped specs, and one standalone ZIP per spec.

Do not hand-edit generated build output or restore vendor-local launchers and
HTML pages.
