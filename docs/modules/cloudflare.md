# cloudflare

Deploy to Cloudflare with wrangler: resolve credentials, derive the deploy config and the version string, confirm a destructive environment, run wrangler, and prove afterwards that what answers is what was just deployed.

This module is one half of a pair. The other half is a reusable GitHub Actions workflow that supplies credentials, the environment gate and the kill switch. Both call the same deploy sequence, so a deploy from a laptop and a deploy from CI are not two implementations that drift apart.

The mechanism is a contract of `CF_DEPLOY_*` environment variables. When CI has already resolved a value it exports it, and the function here returns it verbatim instead of computing its own. A single run therefore never has two live definitions of the version string or the base URL.

Return codes
------------

Every function in this module uses the same set:

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | the operation failed, or a required value could not be resolved |
| `2` | bad arguments, or a value outside its allowed set |
| `3` | a required tool is missing |
| `4` | no usable Cloudflare credentials |
| `5` | refused — a protected environment was not confirmed |

No function here calls `exit`. These are library functions, and a sourced function that exits takes the caller's shell with it.

Functions
---------

- cloudflare_wrangler args...
  - Purpose: Run wrangler through whichever runner the project implies.
  - Behavior: Uses `CLOUDFLARE_WRANGLER_CMD` when set; otherwise prefers the project's own lockfile (`pnpm exec wrangler`, `yarn wrangler`, `npm exec -- wrangler`), then a `wrangler` on `PATH`, then `npx --yes wrangler@$CLOUDFLARE_WRANGLER_VERSION`. Prefers the lockfile because that is the version the project was tested against; the `npx` fallback is convenience, not supply-chain hygiene. The API token is passed through the environment and never in argv, where any other user on the machine could read it with `ps`.
  - Returns: wrangler's own exit status; `2` with no arguments; `3` when no runner is available.

- cloudflare_credentials_ok
  - Purpose: Establish that a deploy can authenticate before doing any work.
  - Behavior: Succeeds when `CLOUDFLARE_API_TOKEN` is set, or when `wrangler whoami` reports an authenticated interactive session.
  - Returns: `0` usable credentials; `4` none (the message names both `CLOUDFLARE_API_TOKEN` and `wrangler login`); `3` when wrangler cannot run.

- cloudflare_account_id [env_file]
  - Purpose: Print the Cloudflare account id a deploy should target.
  - Behavior: Reads `CLOUDFLARE_ACCOUNT_ID` from the environment, then from `env_file` (default `.env`) via `resolve_env_value`. This check exists because an empty account id is **not** an error to wrangler: it falls back to resolving the account from the token, which is correct for a token scoped to one account and a coin toss otherwise. A deploy that lands on the wrong account looks exactly like a deploy that worked.
  - Returns: `0` and prints the id; `1` when neither source has one.

- cloudflare_version_string [version_file]
  - Purpose: Print the version string a deploy should advertise.
  - Behavior: Returns `CF_DEPLOY_VERSION` verbatim when exported, so in CI the workflow's definition is the only live one and this is a pure fallback. Otherwise reads `version_file` (default `VERSION`), strips whitespace, and appends `-<7-char commit sha>`. Outside a git checkout it appends `-unknown` and warns, because a version that cannot identify a commit should say so rather than look precise.
  - Returns: `0`; `1` when the file is unreadable or empty; `2` when it does not exist.

- cloudflare_deploy_config wrangler-config dist-dir
  - Purpose: Print the path of the deploy config a bundler-generated build emits.
  - Behavior: Reads the top-level `name` out of the authored wrangler config and prints `<dist-dir>/<name with hyphens as underscores>/wrangler.json`. Derived rather than hardcoded, so the two stay in step when the worker is renamed. `CLOUDFLARE_DEPLOY_CONFIG` overrides the derivation entirely.
  - Returns: `0`; `1` when the config is unreadable or has no top-level `name`; `2` when an argument is missing.

- cloudflare_base_url environment [env_file]
  - Purpose: Print the base URL to smoke-test after a deploy.
  - Behavior: Resolution order is `CF_DEPLOY_BASE_URL` (CI has already decided), then `<ENVIRONMENT>_BASE_URL`, then `BASE_URL`, the latter two read from `env_file` (default `.env`). The per-environment name is what lets one `.env` describe a laptop's view of several environments. Uppercasing is done with `tr`, not `${x^^}`, which is bash 4.
  - Returns: `0` and prints the URL; `1` when nothing is found (the message names the exact variable it wanted); `2` when `environment` is empty.

- cloudflare_confirm_environment environment [--yes]
  - Purpose: Require a deliberate confirmation before deploying to a protected environment.
  - Behavior: Only environments listed in `CLOUDFLARE_PROTECTED_ENVS` (default `production`, space separated) prompt at all. `--yes`, or `CLOUDFLARE_DEPLOY_YES=1`, confirms without a prompt. On a terminal the operator must type the environment name exactly. With **no terminal on stdin** it returns `5` immediately rather than blocking on a read nobody can answer — an unattended run that hangs to its timeout is worse than one that says what it needed.
  - Returns: `0` confirmed; `2` empty environment; `5` declined, or unattended without `--yes`.

- cloudflare_smoke_test base-url expected-version [status-path] [field]
  - Purpose: Prove that the deploy took effect, not merely that something answers.
  - Behavior: Two separate assertions. First `curl` the health path (`CLOUDFLARE_HEALTH_PATH`, default `/health`) with retries, since a deploy that has just landed may take a moment to be reachable everywhere. Then, when `status-path` is given, fetch it and compare its `field` (default `version`) against `expected-version`. Without the second assertion a smoke test passes against the previous release, which is the failure it exists to catch — so reachability-only runs log a warning saying so. JSON is read with `jq`, else `python3`, else a `grep`/`sed` fallback.
  - Returns: `0` pass; `1` unreachable, no such field, or the wrong version is live; `2` bad arguments; `3` no `curl`.

- cloudflare_deploy [options] [-- extra wrangler args...]
  - Purpose: The single deploy sequence, shared by `./dev deploy cloudflare` and by CI.
  - Options: `--env NAME` (required), `--config PATH`, `--dist DIR`, `--source CONFIG`, `--build-command CMD`, `--command KIND`, `--version-file FILE`, `--status-path PATH`, `--yes`, `--dry-run`, `--no-smoke`. Anything after `--` is passed to wrangler untouched.
  - Behavior: Validates `--command` against the allowlist `deploy` / `versions upload` / `pages deploy` before anything else, because that value becomes argv. Then confirms the environment, checks credentials, resolves and exports the account id, runs the build command with `CLOUDFLARE_ENV` exported, resolves the version, derives the deploy config when `--dist` was given, asserts the config exists, runs wrangler, and smoke-tests. `--dry-run` stops before any credential check or wrangler call.
  - Returns: `0`; `1` a step failed, or the account id could not be resolved; `2` a bad option, a missing option value, or an unknown command; `3` wrangler could not be run; `4` no usable credentials; `5` a protected environment was not confirmed.
  - Every value-taking option is checked for its value before it is consumed. `--env` with nothing after it returns `2` with a message; it does not consume the next option, and it does not hang.

Environment
-----------

| Variable | Effect |
|---|---|
| `CLOUDFLARE_API_TOKEN` | The API token. Read by wrangler from the environment; never placed in argv. |
| `CLOUDFLARE_ACCOUNT_ID` | The account to deploy to. Checked explicitly, because wrangler treats an empty value as "resolve from the token". |
| `CLOUDFLARE_WRANGLER_CMD` | Overrides how wrangler is invoked, e.g. `pnpm exec wrangler`. |
| `CLOUDFLARE_WRANGLER_VERSION` | Version used by the `npx` fallback. Defaults to `CI_DEFAULT_WRANGLER_VERSION`, which this module sources from `ci_defaults` so the pin has one home. |
| `CLOUDFLARE_PROTECTED_ENVS` | Space-separated environments needing a typed confirmation. Default `production`. Matched literally — globbing is disabled while the list is read, so the value cannot be altered by files in the working directory. |
| `CLOUDFLARE_DEPLOY_YES` | Set to `1` to confirm a protected environment without a prompt. |
| `CLOUDFLARE_HEALTH_PATH` | Reachability path for the smoke test. Default `/health`. |
| `CLOUDFLARE_DEPLOY_CONFIG` | Names the generated deploy config directly, skipping derivation. |
| `CF_DEPLOY_VERSION` | Set by CI. Taken verbatim by `cloudflare_version_string`. |
| `CF_DEPLOY_BASE_URL` | Set by CI. Taken verbatim by `cloudflare_base_url`. |

Example
-------

```bash
source helpers.sh
shlib_import cloudflare

# A laptop deploy to a non-protected environment.
cloudflare_deploy \
  --env staging \
  --build-command "npm run build" \
  --source wrangler.toml \
  --dist dist \
  --status-path /api/status

# Production asks for the environment name to be typed, unless --yes is given.
cloudflare_deploy --env production --config wrangler.toml --yes

# Cloudflare Pages: no --env, and the target comes after --.
cloudflare_deploy --env staging --command "pages deploy" -- \
  dist --project-name example-site
```

Dependencies
------------

- `curl` — the smoke test.
- wrangler, through a package manager, a `PATH` binary, or `npx`.
- `jq` or `python3` for JSON; a `grep`/`sed` fallback is used when neither is present.
- `lib/logging.sh`, and `lib/env.sh` for `resolve_env_value`.

Pushing KV entries or seed data
-------------------------------

**This module deliberately does not do it, and will not gain a function for it.**
If a deploy also has to write KV entries, seed a namespace, or upload data, put
that in your own script — alongside `cloudflare_deploy`, not inside it.

Why it stays out:

- **It needs a wider token.** Deploying needs *Workers Scripts → Edit*; writing
  KV needs *Workers KV Storage → Edit* as well. Binding a namespace does not.
  A helper that writes data would push every caller toward the broader token
  whether or not they need it.
- **It is the one step that cannot be undone by the next deploy.** A Worker is
  replaced by the deploy after it. Overwritten data is gone.
- **"Push the data" is not one operation.** Replacing a namespace, upserting a
  few keys, uploading a file and applying a migration are different jobs with
  different failure modes. A single function covering all of them would be a
  shell command with extra steps.

If you write one, four things to get right:

1. **Guard it with a string comparison, never a bare truthiness test.** In a CI
   job, an output crossing a job boundary is a *string*, so a guard like
   `if: needs.x.outputs.push_data` is true even when the value is the literal
   `"false"` — every non-empty string is truthy. The same shape in bash is
   `[[ -n "$PUSH_DATA" ]]`, which is true for `"false"` too. Compare against the
   value you mean: `[[ "$PUSH_DATA" = "true" ]]`.
2. **Make it idempotent, or make it refuse.** Deploys get re-run — a retried
   job, a re-pushed tag, a person clicking the button again. A push that
   overwrites unconditionally gives a different result each time. If it cannot
   be idempotent, detect existing data and stop rather than clobber it.
3. **It is not atomic with the deploy.** wrangler deploying and your data
   landing are two operations with no shared transaction. Decide which order
   fails better for your service and write that reasoning down next to the code.
4. **Run it under the same confirmation.** `cloudflare_confirm_environment` is
   what stops an unattended production deploy; a data push that runs before or
   outside it has no such gate. Call it first, or call `cloudflare_deploy` and
   do the data push only after it returns `0`.

```bash
source helpers.sh
shlib_import cloudflare

cloudflare_confirm_environment production "$@" || exit $?
cloudflare_deploy --env production --config wrangler.toml --yes || exit 1

# Only after the Worker is live and the smoke test passed.
if [[ "${PUSH_DATA:-false}" = "true" ]]; then
  ./scripts/seed-kv.sh            # yours, idempotent, and it may refuse
fi
```

Notes
-----

- Cloudflare Pages is supported as an input combination (`--command "pages deploy"`), not as a separate code path. The Workers path is the one exercised end to end.
- `--dry-run` validates and builds but never calls the Cloudflare API, so it proves the config and the bundle, not bindings, routes, or account access.
- `--config` and `--dist` are not passed to `pages deploy`, which does not take them in this module's invocation. Supplying one logs a warning rather than dropping it silently.
- The smoke test uses `curl --retry-all-errors` where available. That option needs curl 7.71 (2020); on an older curl the flag is omitted rather than failing, because an unknown option would otherwise read as "the service did not answer" and fail a deploy that worked.
- `cloudflare_deploy` exports `CLOUDFLARE_ACCOUNT_ID` into the calling shell once resolved, so a later wrangler call in the same script sees it.
