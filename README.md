# netizen

*For the Community, by the Community.*

High-quality API specs and interactive Swagger UIs for tools that deserve better documentation.

**https://kludgarr.github.io/netizen/**

The published catalog is generated from the OpenAPI documents and available at:

**https://kludgarr.github.io/netizen/catalog.json**

## Local Usage

Download and extract a spec ZIP from the site or the
[`spec-bundles-latest`](https://github.com/kludgarr/netizen/releases/tag/spec-bundles-latest)
release. Each package contains one OpenAPI spec, `serve.py`, `serve.ps1`, and
assistant guidance in `AGENTS.md`. The launchers run a generated Swagger UI
locally with full "Try it out" support.

```bash
# Python
python serve.py

# PowerShell 7+
pwsh serve.ps1
```

On first run, the launcher discovers the packaged spec, creates
`netizen.config.json`, and downloads Swagger UI assets into `.swagger-ui/`.
Subsequent runs can use the cached assets.

The scripts auto-open a browser, proxy API calls to avoid CORS restrictions, and shut down after 120 seconds of inactivity. Use `-k` / `-KeepAlive` to run indefinitely, or `-p` / `-Port` to change the default port (8080).

## License

No-attribution model:

- Code (site, launchers, workflows): [0BSD](LICENSE)
- API specs and non-code content: [CC0 1.0](LICENSE-CONTENT)

Use, copy, modify, and redistribute freely.
