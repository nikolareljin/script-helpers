# ports

Port utilities to inspect listeners and detect conflicts for commonly used env-driven ports.

Environment
-----------

- `PORT_DETECTION_ALLOW_SUDO` — when `true`, attempts certain checks with sudo if the non-sudo command returns nothing. Default: `false`.

Functions
---------

- list_port_usage_details port
  - Purpose: Print human-friendly details like `process (PID 1234, user bob)` for listeners on a TCP port.
  - Behavior: Tries `lsof`, then `ss`, then `netstat`. With sudo (if allowed) as a fallback. BusyBox `lsof` ignores its options and lists every open file; its output (no `COMMAND` header) is not read, and a PID is only ever a bare number.
  - Returns: 0 and prints lines if any found; 1 if nothing could be determined, or when `port` is not a single port 1-65535 (an empty string or a range such as `1-65535` would otherwise match every listener).

- list_port_listener_pids port
  - Purpose: Print the PIDs that are listening on a TCP port.
  - Behavior: Similar detection strategy as above, plus `fuser`; prints unique PIDs found, one per line (every PID of a socket shared by several processes).
  - Returns: 1 with no output when `port` is not a single port 1-65535 -- an empty string or a range would otherwise list every listener on the machine; otherwise 0.

- port_in_use_by port
  - Purpose: Print process details for listeners on a TCP port, or nothing if unused.
  - Behavior: Wraps `list_port_usage_details` and prints detail lines when found.
  - Returns: 0 and prints details if any found; non-zero with no output if unused.

- port_is_free port
  - Purpose: True when nothing listens on `port`.
  - Behavior: Asks the listener list first (`list_port_usage_details`: lsof, ss or netstat). A connect test alone calls a port free when its server is hung or its accept queue is full, because the connection is refused. Without those tools, a connect to `127.0.0.1` through bash's `/dev/tcp` decides.
  - Returns: 0 free; 1 taken; 2 not a port 1-65535.

- port_next_free port [tries=20]
  - Purpose: Print the first free port after `port`.
  - Returns: 0 with the port; 1 when none of the next `tries` is free; 2 not a port.

- port_choose port [how to set it]
  - Purpose: Print the port to use, never swapping a taken one silently.
  - Behavior: A free `port` is printed as it is. A taken one: on a terminal (stdin and stderr), the owner and a free port are shown and the person types a port, Enter taking the suggestion, asked again until it is free. Without a terminal it fails, naming the owner and `how to set it` (for example `--port N, or DOCS_SITE_PORT=N`). Messages go to stderr, so `p="$(port_choose 8000 "--port N")"` works.
  - Returns: 0 with the port on stdout; 1 taken with nobody to ask, or no answer; 2 not a port.

- check_required_ports_available [env_file=.env]
  - Purpose: Check a common set of env vars → ports for conflicts on the local machine.
  - Uses `REQUIRED_PORT_DEFAULTS` to know which variables to examine (with defaults):
    - `TRAEFIK_HTTP_PORT:80`, `TRAEFIK_DASHBOARD_PORT:8081`, `ELASTICSEARCH_PORT:9200`,
      `ELASTICSEARCH_TRANSPORT_PORT:9300`, `REDIS_PORT:6379`, `POSTGRES_PORT:5432`,
      `OLLAMA_PORT:11434`, `BACKEND_PORT:8000`, `FRONTEND_PORT:3000`, `API_PORT:8080`.
  - Side effects: Populates globals for callers to inspect and render:
    - `REQUIRED_PORT_CONFLICT_MESSAGES` — array of detailed messages.
    - `REQUIRED_PORT_CONFLICT_SUMMARIES` — array of short summaries.
    - `REQUIRED_PORT_CONFLICTS_JSON` — JSON array with `{port, variables[], details[]}`.
  - Returns: 0 if no conflicts detected; non-zero otherwise.

Dependencies
------------

- `lsof`/`ss`/`netstat`/`fuser` (any subset available), optional `sudo` when allowed. BusyBox `lsof` (Alpine) ignores its options and lists every open file, so it is skipped and `ss`/`netstat`/`fuser` answer instead.
- Any POSIX awk: gawk, mawk (Debian/Ubuntu default) and BSD awk (macOS) all parse the `ss`/`netstat` output.
