# docs_site

Build, serve, preview and verify a repository's documentation site, the same way in every repository. `make docs`, `make docs-serve`, `./dev docs` and CI all call this, so they mean the same thing everywhere.

```bash
scripts/script-helpers/scripts/docs_site.sh check      # what CI and pre-push run
scripts/script-helpers/scripts/docs_site.sh serve      # live reload while writing
scripts/script-helpers/scripts/docs_site.sh preview    # the built site over HTTP: what ships
scripts/script-helpers/scripts/docs_site.sh build
scripts/script-helpers/scripts/docs_site.sh verify --dir site
```

`--dir` names the repository (default: the git repository of the current directory). `--port N` sets the port for `serve` and `preview`.

Generators
----------

| Generator | When | Build |
|---|---|---|
| `mkdocs` | a `mkdocs.yml` at the repository root | `mkdocs build --strict` in a virtualenv outside the tree (`~/.cache/nr-docs-venv/<repo>`) |
| `command` | `DOCS_SITE_BUILD_CMD` is set | that command, from the repository root, writing to `DOCS_SITE_OUT` (default `site`) |

The MkDocs toolchain is the repository's `requirements-docs.txt` when it has one, else this library's (`requirements-docs.txt` at its root): one set of pins for every repository that does not need its own.

A repository with its own builder declares it, for example in `scripts/project.sh`:

```bash
DOCS_SITE_BUILD_CMD="python3 scripts/build_site.py --out _site"
DOCS_SITE_OUT=_site
```

What `check` proves
-------------------

1. No code fence is left open in the Markdown sources (MkDocs). An open fence renders the rest of the page as one code block, and `mkdocs build --strict` does not see it.
2. The site builds (MkDocs: strict, into a temporary directory; nothing is written in the repository).
3. There is a search index when the site has search, and no file was published by accident (MkDocs copies everything under `docs_dir`).
4. Over HTTP, on a port the operating system picks: `/` and every page reachable from it answer 200, and so does every internal link, image, script and stylesheet; every `#fragment` exists on its page. Each failure is named with the page that links to it. External links are not fetched.

Ports
-----

`serve` and `preview` use `--port`, `DOCS_SITE_PORT` or 8000. A taken port is never swapped silently (`port_choose` in [ports](ports.md)): on a terminal the owner and a free port are shown and you type one (Enter takes the suggestion); without a terminal it is an error that names the owner and says to use `--port N` or `DOCS_SITE_PORT=N`.

`serve` prints the address under `site_url`'s path (`http://127.0.0.1:8000/name/`), which is where `mkdocs serve` answers.

Functions
---------

- docs_site_check repo -- the checks above. Returns 0 clean, 1 a problem (listed), 2 no site or bad settings, 3 no python3.
- docs_site_build repo [out] -- build the site; MkDocs into `out` (default its `site_dir`).
- docs_site_serve repo [port] -- live reload (MkDocs); `preview` for a command generator.
- docs_site_preview repo [port] -- build, then serve the output through `serve_static_site`.
- docs_site_verify dir -- crawl an already built site over HTTP (`scripts/site_verify.py`).
- docs_site_generator repo -- prints `mkdocs` or `command`; 2 when the repository has no site.
- docs_site_out repo -- prints the output directory.
- docs_site_toolchain repo -- creates or refreshes the MkDocs virtualenv and prints its `mkdocs`.

Settings
--------

| Variable | Default | Meaning |
|---|---|---|
| `DOCS_SITE_GENERATOR` | detected | `mkdocs` or `command` |
| `DOCS_SITE_BUILD_CMD` | none | the command generator's build |
| `DOCS_SITE_OUT` | `site` | the command generator's output directory |
| `DOCS_SITE_REQUIREMENTS` | the repository's `requirements-docs.txt`, else this library's | MkDocs toolchain pins |
| `DOCS_SITE_PORT` | 8000 | `serve` and `preview` |
| `DOCS_VENV` | `~/.cache/nr-docs-venv/<repo>` | MkDocs virtualenv |

Dependencies
------------

- `python3` 3.9 or newer (the verifier is standard library only; MkDocs is installed in the virtualenv).
- Modules: `logging`, `python`, `ports`, `serve`.
