# netizen

*For the Community, by the Community.*

High-quality API specs and interactive Swagger UIs for tools that deserve better documentation.

**https://kludgarr.github.io/netizen/**

## Specs

| Tool | Version | Endpoints |
|------|---------|-----------|
| [Technitium DNS Server](https://kludgarr.github.io/netizen/technitium-dns/) | 14.3 | 129 |
| [TVmaze API](https://kludgarr.github.io/netizen/tvmaze/) | unversioned | 31 |
| [OMDb](https://kludgarr.github.io/netizen/omdb/) | 1.0 | 1 |
| [Schedules Direct](https://kludgarr.github.io/netizen/schedulesdirect/) | 20141201 | 25 |

## Local Usage

Each spec folder includes `serve.py` and `serve.ps1` for running the Swagger UI locally with full "Try it out" support.

```bash
# Python
python serve.py

# PowerShell 7+
pwsh serve.ps1
```

On first run, the scripts download the Swagger UI assets (`swagger-ui.css`, `swagger-ui-bundle.js`, `swagger-ui-standalone-preset.js`) into the spec folder. Subsequent runs are fully offline.

The scripts auto-open a browser, proxy API calls to avoid CORS restrictions, and shut down after 120 seconds of inactivity. Use `-k` / `-KeepAlive` to run indefinitely, or `-p` / `-Port` to change the default port (8080).

## License

No-attribution model:

- Code (site, scripts, workflows): [0BSD](LICENSE)
- API specs and non-code content: [CC0 1.0](LICENSE-CONTENT)

Use, copy, modify, and redistribute freely.
