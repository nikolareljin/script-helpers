# service

Start, stop, restart, status, logs and readiness for a repository's own services, through
docker compose or as native processes. A repository sets plain variables (normally in
`scripts/project.sh`) and calls the `svc_*` functions from its `./dev` verbs.

```bash
source scripts/script-helpers/helpers.sh
shlib_import logging service

SVC_BACKEND=proc
SVC_PROCS=("api:python3 -m http.server 8000" "worker:./bin/worker --queue default")
SVC_PORTS=(8000)
SVC_HEALTH_URL="http://127.0.0.1:8000/"
SVC_URLS=("API http://localhost:8000/")

svc_start      # or svc_stop, svc_restart, svc_status, svc_logs api
```

Configuration
-------------

| Variable | Backend | Meaning |
|---|---|---|
| `SVC_BACKEND` | both | `compose` or `proc`. Unset or anything else: exit 2. |
| `SVC_COMPOSE_FILES` | compose | Array of compose files, passed as `-f` each. |
| `SVC_COMPOSE_PROJECT` | compose | Project name, passed as `-p`. Optional. |
| `SVC_PROCS` | proc | Array of `name:command`. Names: letters, digits, `_ . -`, no leading dot, unique. The command runs under `bash -c`, so quotes, `&&` and `&` work. |
| `SVC_PORTS` | both | TCP ports the services listen on, each `8000` or `NAME:8000`, where `NAME` is the setting that holds it (`BACKEND_PORT:8000`) and the commands read it (`--port "$BACKEND_PORT"`). A taken port: on a terminal, a `NAME:port` entry is asked about (`port_choose`, Enter takes a free port); the answer is exported as `NAME` for this start, `SVC_HEALTH_URL` and `SVC_URLS` follow it, and you are asked whether to save it in the repository's `.env` (Enter saves, through `env_set_value`), so the next `status`, `stop` and `start` use it too. Without a terminal, or for a bare port, the start is refused with the owner, a free port and what to change. `NAME` may not be a variable the shell or loader reads (`PATH`, `HOME`, `LD_*`, `SVC_*` ...). |
| `SVC_HEALTH_URL` | both | URL that answers with a status below 400 once ready (`curl -f`). Unset: no readiness wait. |
| `SVC_URLS` | both | Array of `"Label url"`, printed as `Label: url` after a start. |
| `SVC_STOP_MODE` | compose | `stop` keeps containers (`compose stop`). Default: `compose down`. |
| `SVC_STOP_TIMEOUT` | both | Seconds between TERM and KILL. Default 10. |
| `SVC_READY_TIMEOUT` | both | Seconds `svc_wait_ready` waits. Default 180. |
| `SVC_ROOT` | both | Repository root. Default: `git rev-parse --show-toplevel`, else `$PWD`. |
| `SVC_LOGS_FOLLOW` | both | `0` makes `svc_logs` print the last 100 lines instead of following. |

Run directory: `.run/` at the repository root holds `<name>.pid`, `<name>.started` (a
start-time fingerprint of the pid) and `<name>.log`. Add `.run/` to `.gitignore`.

Exit codes: 0 ok or nothing to do, 1 failure (not ready, port taken, docker missing, a
process that would not stop), 2 usage (bad `SVC_*` configuration or argument).

Functions
---------

- svc_start [--build]
  - Purpose: start the services, wait for `SVC_HEALTH_URL`, print `SVC_URLS`.
  - compose: `check_docker`, then `compose up -d [--build]` from `SVC_ROOT`. Ports are checked only when the stack is down (`compose ps -q` is empty).
  - proc: each process not already running is detached into its own session and process group, stdout and stderr appended to `.run/<name>.log`. One already running is reported and left alone; all running exits 0. Ports are checked only when none of the processes is running. Without a health URL, a process that exits within a second fails the start with its log tail.
  - Returns: 0 started or already running; 1 port taken (the message names the owner and the setting to change), docker unavailable, `curl` missing with `SVC_HEALTH_URL` set (checked before anything starts), not ready; 2 usage.

- svc_stop
  - Purpose: stop the services.
  - compose: `compose down --timeout SVC_STOP_TIMEOUT`, or `compose stop --timeout ...` with `SVC_STOP_MODE=stop`.
  - proc: TERM to the whole process group (children included), wait `SVC_STOP_TIMEOUT`, then KILL; remove the pidfile.
  - Returns: 0 stopped or nothing running; 1 a group survived KILL; 2 usage.

- svc_restart [--build]
  - Purpose: `svc_stop`, then `svc_start` with the same arguments.

- svc_status
  - Purpose: what runs, which ports listen (and who owns them), whether health answers.
  - compose: `compose ps`. proc: one line per process, `name: running (pid N)` or `name: stopped`.
  - Returns: 0 when everything is up and healthy; 1 otherwise; 2 usage.

- svc_logs [name]
  - Purpose: follow the logs of one service, or of all.
  - compose: `compose logs -f [name]`. proc: `tail -f` on `.run/<name>.log` (all logs without a name).
  - Returns: 2 for a name not in `SVC_PROCS` (proc backend).

- svc_wait_ready
  - Purpose: poll `SVC_HEALTH_URL` once a second until it answers or `SVC_READY_TIMEOUT` runs out.
  - proc: stops early, with the same log tail, when every process has exited.
  - Returns: 0 ready, or no health URL set; 1 on timeout, after printing the last 40 log lines (`compose logs --tail 40`, or the tail of each `.run/*.log`).

Pidfiles
--------

A pidfile is trusted only while its process group is alive and, when the leader is alive,
its start time matches `<name>.started`. Anything else is a stale pidfile: it is removed,
reported, and nothing is signalled. So a pid reused by an unrelated process after a reboot
is never killed. Where neither `/proc` nor `ps -o lstart` works the fingerprint is empty and
only the liveness check applies.

Detaching (macOS and Linux)
---------------------------

macOS has no `setsid` binary. Processes are detached with `perl -MPOSIX` (`POSIX::setsid`),
which stock macOS ships; perl is preferred on Linux too, because it also restores SIGINT and
SIGQUIT, which bash leaves ignored in a background job. Without perl, `setsid` (util-linux
or BusyBox) is used. With neither, start fails with exit 1. The leader writes its own pid,
so this works whether or not the caller has job control.

Dependencies
------------

- Modules: `logging`, `docker` (`get_docker_compose_cmd`, `check_docker`), `ports` (`port_in_use_by`).
- `perl` or `setsid` (proc), `curl` (health checks), `docker compose` or `docker-compose` (compose).
