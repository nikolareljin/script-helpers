# ci_stack

Disposable service containers for a CI runner: start a database, wait for it to
answer, remove it with its anonymous volume afterwards.

Extracted from `ci_laravel.sh`, which had the most complete implementation. The
point is that there is one copy: `ci_laravel.sh` and `ci_wp_phpunit.sh` each
carried their own `start_database` and `cleanup`, and the two had drifted far
enough that one guarded its EXIT trap against inherited subshells and the other
did not — a bug that removes the caller's database container mid-run.

Functions
---------

- ci_stack_engine_for_image
  - Purpose: Echo `mysql` or `pgsql` for a known image name. Returns 1 for an
    image it cannot place, so a caller refuses rather than guesses; guessing is
    how a container comes up and is then talked to in the wrong dialect.

- ci_stack_default_port
  - Purpose: Echo the port an engine listens on inside its container — 3306 for
    mysql, 5432 for pgsql.

- ci_stack_start_database
  - Purpose: `docker run -d` the image, then poll until it answers. Returns 0
    when ready, 1 when it does not become ready, 2 on bad arguments.
  - Refuses first, by name, when docker is not on PATH. Without that the
    first failure is `docker network create` and the message blames the
    network, sending a reader after a problem they do not have.
  - Options: `--image` and `--name` are required. `--engine` (default `mysql`),
    `--network` or `--publish` (see below), `--db`, `--user`, `--password`,
    `--root-password`, `--wait-seconds` (default 60).

- ci_stack_command_program
  - Purpose: Echo the program a step command would run, or nothing when the
    command is a shell construct. Environment prefixes are stepped over, so
    `DJANGO_SETTINGS_MODULE=x python manage.py test` answers `python`.

- ci_stack_command_available
  - Purpose: Whether that program can be run. 0 yes, 1 no.
  - Arguments: `<workdir> <image-or-empty> <docker-user-or-empty> <program>`.
  - The probe runs **with the workdir as its current directory**. It did not,
    and a step command naming a path inside the project -- `bin/thing`,
    `.venv/bin/python`, `vendor/bin/phpunit` -- was refused before it ran, while
    the step itself would have `cd`-ed there and run it. A check that fires on
    correct input is worse than no check, because it gets switched off.

- ci_stack_remove
  - Purpose: Remove the container and, if given, the network. Never fails: it is
    called from an EXIT trap, where a non-zero return would replace the script's
    real exit status with the cleanup's.
  - Says nothing about a container that does not exist. A caller sets the
    name before starting, so on a failed start this used to announce
    removing something that was never created.
  - Options: `--container`, `--network`.

Notes
-----

- `--network` and `--publish` are alternatives, not both. A caller whose steps
  run inside a container reaches the database by container name on a shared
  network; one whose steps run on the host reaches a published port. Publishing
  when nothing will use it fails the run with "port is already allocated" for a
  port nobody wanted.

- The removal uses `docker rm -f -v`. The mysql and postgres images declare a
  `VOLUME`, so every `docker run -d` creates an anonymous volume; without `-v`
  the container goes and the volume stays. Seven runs left 1.4 GB of orphaned
  data directories on one laptop, referenced by nothing and reported by nothing.
  `-v` removes anonymous volumes and leaves a named one a caller supplied alone.

- `--wait-seconds 0` is refused. A zero wait runs the readiness loop no times
  and would return success against a container that has not started; a caller
  asking for no wait wants no database.

- An empty `--root-password` sets `MYSQL_ALLOW_EMPTY_PASSWORD=yes` rather than
  an empty `MYSQL_ROOT_PASSWORD`, which the image rejects. Without one of the
  two it exits during its entrypoint, so the symptom is the readiness poll
  timing out with nothing about a password anywhere in the output.

- Import `logging` for the progress and error lines.
