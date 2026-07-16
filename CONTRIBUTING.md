# Contributing to netizen

Thanks for helping improve netizen.

## What This Repo Is

netizen hosts community OpenAPI specs and produces standalone local Swagger packages for useful services.

Goals:

- Keep specs easy to consume.
- Keep maintenance low.
- Keep outputs publicly reusable.

## Before You Open a PR

1. Make sure your change is service-focused and useful to end users.
2. Keep changes small and scoped.
3. Prefer updating existing patterns over inventing new structure.

## Spec Folder Conventions

Each vendor folder contains one or more OpenAPI documents and an `AGENTS.md`
symlink to the repository-root guide:

`<vendor>_openapi_v<openapi-version>.json`

Examples:

- `technitium-dns/technitium-dns_openapi_v3.0.3.json`

## Netizen Metadata

Each spec must carry the same vendor-level `x-netizen.catalog` object:

Required fields:

- `name`
- `description`
- `tags`
- `site`
- `upstream` (may be `null`)

The workflow derives filenames, vendor and OpenAPI versions, Netizen revision,
and path/operation counts. Do not maintain those values in `x-netizen`.

## Workflow Behavior

On build runs, CI will:

1. Enumerate and validate every vendor spec.
2. Generate the public `catalog.json`.
3. Stamp published spec copies with their Git-derived Netizen revision.
4. Generate one standalone ZIP per spec.
5. Publish/update release ZIP assets and GitHub Pages on `main`.

If CI fails, check workflow output in `.github/workflows/publish.yml`.

## Adding a New Service

1. Create the vendor folder and its OpenAPI JSON.
2. Add the vendor's curated `x-netizen.catalog` metadata.
3. Keep copy focused on the service value, not spec construction details.
4. Open a PR.

## License

Contributing means your code/content is accepted under this repo's license model:

- Code: `0BSD` (`LICENSE`)
- Non-code/spec content: `CC0 1.0` (`LICENSE-CONTENT`)
