# Development Proposal: Immutable Sandbox Runner

## Goal

Replace Docker-specific sandbox mode with a smaller, safer runner model that
tests a target project in isolation without mutating the target directory.

The sandbox must contain both:

- immutable project input
- writable test workspace

The project under test is read-only inside the sandbox. All installs, builds,
generated files, and test side effects happen against a disposable copy inside
the same sandbox.

## Current State

`run.sh --docker` starts one container from `qa-runner-image`.

Current mounts:

- host project -> `/app`, read-write
- QA suite -> `/agent`, read-only

Problem: `/app` is the real target project. Stage 2 can run package installers,
builds, startup probes, and tests that write files. That means sandbox mode
isolates processes but not project contents.

## Recommendation

Use Podman as the primary sandbox engine and keep a Docker-compatible fallback
during migration.

Use an Ubuntu LTS runner image built from `Containerfile`. Start with
`ubuntu:24.04` for stability, then evaluate `ubuntu:26.04` after the runner's
toolchain smoke tests pass. Ubuntu 26.04 LTS was released in April 2026, so it
should not become the default immediately without validation.

Podman is a better fit than Docker Desktop for this project because it supports
rootless operation, does not require a long-running Docker daemon, and keeps the
same OCI image/container model. On macOS, Podman still uses a Linux VM because
Linux containers require a Linux kernel, but that VM is managed by Podman.

## Proposed Sandbox Layout

Inside one sandbox:

```text
/target        read-only mount of the real project
/agent         read-only mount of this QA suite
/work/project  writable disposable copy of /target
/out           writable artifact export directory
```

The pipeline runs against `/work/project`, never `/target`.

Host writes are limited to `/out`. By default, `/out` should be outside the
target project, for example:

```text
~/.desktop-qa/runs/<timestamp>-<project-name>/
```

Writing reports back into `<project>/qa/` should become an explicit opt-in
compatibility mode, not the sandbox default.

## Execution Flow

1. Resolve target path on the host.
2. Create a host output directory outside the target.
3. Start the sandbox with:
   - `/target:ro`
   - `/agent:ro`
   - `/out:rw`
   - writable internal `/work`
4. Inside the sandbox, verify `/target` is not writable.
5. Copy `/target` to `/work/project`.
6. Run stages `00` through `04` against `/work/project`.
7. Copy `/work/project/qa/` to `/out/qa/`.
8. Delete the sandbox.

## Engine Command Shape

Primary:

```bash
podman run --rm -i \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  -v "$PROJECT_DIR:/target:ro" \
  -v "$AGENT_DIR:/agent:ro" \
  -v "$OUTPUT_DIR:/out:rw" \
  qa-runner-image \
  bash -lc '/agent/internal/run_in_sandbox.sh'
```

Fallback:

```bash
SANDBOX_ENGINE=docker bash run.sh --sandbox /path/to/project
```

## CLI Changes

Replace Docker wording with sandbox wording:

```bash
bash run.sh /path/to/project
bash run.sh --sandbox /path/to/project
```

Environment variables:

```text
SANDBOX_ENGINE=podman|docker
SANDBOX_IMAGE=qa-runner-image
QA_OUTPUT_DIR=/path/to/output
QA_WRITE_BACK=0|1
```

Defaults:

```text
SANDBOX_ENGINE=podman
SANDBOX_IMAGE=qa-runner-image
QA_WRITE_BACK=0
```

## Implementation Plan

1. Add `internal/run_in_sandbox.sh`.
   - validates `/target` read-only
   - copies `/target` into `/work/project`
   - runs all stages against `/work/project`
   - exports only `/work/project/qa`

2. Update `run.sh`.
   - add `--sandbox`
   - keep `--docker` as deprecated alias
   - select engine through `SANDBOX_ENGINE`
   - mount target read-only
   - write artifacts outside the project by default

3. Rename image documentation.
   - keep `Dockerfile` initially for compatibility
   - optionally add `Containerfile` as the canonical name
   - replace "Docker mode" docs with "sandbox mode"

4. Update `setup.sh`.
   - prefer `podman build`
   - fall back to `docker build`
   - do not pull remote images automatically

5. Add tests.
   - sandbox command mounts target read-only
   - target write attempt fails
   - generated artifacts appear in output directory
   - original project tree remains unchanged after sandbox run
   - `--docker` still works as alias during migration

## Non-Goals

- Do not build a full VM manager into this project.
- Do not mutate the target project in sandbox mode.
- Do not mount host credentials or container sockets.
- Do not auto-install host-level dependencies.

## Alternative: Lima Ubuntu VM

Lima can run an Ubuntu VM with container engines inside it. This is useful if
the project wants an explicit VM boundary instead of a Podman-managed VM.

Tradeoff: stronger mental model, more setup and lifecycle code. For this suite,
Podman gives the same practical container workflow with a smaller project
footprint.

## Acceptance Criteria

- `bash run.sh --sandbox /target/project` never writes inside `/target/project`.
- The target is mounted read-only inside the sandbox.
- All side effects happen in `/work/project`.
- Reports are exported to a separate output directory.
- The runner works without Docker Desktop when Podman is available.
- Docker remains temporarily available as a compatibility engine.

## References

- Podman `run` supports read-only root filesystems, read-only bind mounts, and
  volume mount options: https://docs.podman.io/en/latest/markdown/podman-run.1.html
- Podman on macOS uses `podman machine` because Linux containers require a
  Linux VM: https://docs.podman.io/en/latest/markdown/podman-machine.1.html
- Lima supports container engines inside Linux VMs:
  https://lima-vm.io/docs/examples/containers/
- Ubuntu release lifecycle:
  https://ubuntu.com/about/release-cycle
