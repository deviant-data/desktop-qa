# Desktop QA Suite (v4)
### Deterministic local QA pipeline — pure bash, no AI, no external services

---

## Overview

The Desktop QA Suite is a locally executed quality assurance pipeline for
arbitrary project directories. It inspects a project, sets up its runtime,
generates a QA plan, runs the discoverable test suite, and produces a
structured report. Everything runs on your machine; nothing leaves it.

The pipeline is five numbered bash scripts executed in sequence. There is no
model, no API key, and no network call beyond whatever the project under
test needs to install its own dependencies.

Languages covered: HTML, CSS, JavaScript, TypeScript, Ruby, Ubuntu/Dockerfile, Python, shell, Go, Java, Rust, PHP, JSON/YAML, and SQL
---

## Design principles

- **Deterministic** — same project + same inputs → same output. No stochastic
  components in the pipeline itself.
- **Zero external dependencies** — no cloud services, no third-party APIs.
- **Reproducible** — each run starts from the same scripted baseline. The
  sandbox image can be rebuilt from the shipped Dockerfile.
- **Transparent** — every decision is grep-able in `test_log.txt`.
- **Bounded** — failures in one stage do not cascade; every run produces a
  `qa_report.md` even when earlier stages fail.

---

## Requirements

| Requirement | Details |
|---|---|
| Bash 4+ | The stage scripts use `declare -A` and other bash 4 features. macOS system bash is 3.2 — `brew install bash` if you hit the version guard. |
| Docker (recommended) | Needed for `--docker` sandbox mode. Optional for host mode. |
| Language runtimes | Host mode: install whichever runtimes your projects use (Node, Python, Go, Java, Ruby). Sandbox mode: all of the above are baked into the runner image. |
| Disk space | ~2 GB for the sandbox image and per-project workspace. |

---

## Project structure

```
desktop-qa-v4/
├── README.md              # This file
├── Dockerfile             # Builds the qa-runner-image sandbox
├── setup.sh               # One-time host setup; builds the sandbox image
├── run.sh                 # Executes the five stages against a project dir
├── 00_ingestion.sh        # Stage 1: scan & summarise the project
├── 01_environment.sh      # Stage 2: install deps, build, probe startup
├── 02_qa_plan.sh          # Stage 3: generate rule-based QA plan
├── 03_test_execution.sh   # Stage 4: discover & run tests, log results
├── 04_report.sh           # Stage 5: render qa_report.md from artifacts
├── bash-compat.yml        # CI workflow: bash 3.2 guard + bash 4+ happy path
└── gitignore              # Ignored paths (rename to .gitignore when using git)
```

---

## Quickstart

```bash
# 1. One-time setup (checks host tools, builds the sandbox image)
bash setup.sh

# 2. Run against a project, host mode
bash run.sh /path/to/project

# 3. Or run sandboxed
bash run.sh --docker /path/to/project
```

Artifacts land in `<project>/qa/`:

- `ingestion_summary.md` — Stage 1 output
- `qa_plan.md` — Stage 3 output
- `test_log.txt` — appended by Stages 2 and 4
- `qa_report.md` — Stage 5 output (the main deliverable)

---

## How it works

### Stage 1 — Ingestion (`00_ingestion.sh`)
Walks the project directory. Classifies languages by file-count histogram,
detects frameworks from manifests (`package.json`, `requirements.txt`,
`pom.xml`, `go.mod`, `Cargo.toml`, `Gemfile`), identifies entry points,
enumerates existing tests and documentation, and flags anomalies
(hard-coded secrets, missing lockfiles, monorepo signals).

### Stage 2 — Environment (`01_environment.sh`)
Verifies the runtime is present, runs the project's installer (`npm ci`,
`pip install -r`, `go mod download`, etc.), attempts a build if one is
defined, and probes startup for projects with a recognisable dev server.
Kills the app process cleanly on exit via a session-group trap.

### Stage 3 — QA plan (`02_qa_plan.sh`)
Emits `qa_plan.md` from a rule-based catalog: per detected stack, it
selects test templates across unit / integration / edge / negative /
regression categories. Existing tests under `qa/tests/` are promoted to
first-class plan entries.

### Stage 4 — Test execution (`03_test_execution.sh`)
Discovers tests under `qa/tests/`, groups them by category, runs each
batch, and logs structured PASS/FAIL/SKIP/FLAKY markers. Flaky tests are
retried up to three times per the documented policy.

### Stage 5 — Report (`04_report.sh`)
Reads each upstream artifact once, parses the structured markers, and
writes `qa_report.md` with coverage, counts, failure details, and
recommendations.

---

## Sandbox mode

`bash run.sh --docker /path/to/project` runs the full pipeline inside a
container built from the shipped `Dockerfile`. The image (`qa-runner-image`
by default) ships with bash 5, jq, git, and runtimes for Node, Python, Go,
Java, and Ruby.

The project directory is bind-mounted at `/app`; the pipeline scripts are
mounted read-only at `/agent`. The container is torn down on exit (normal,
signal, or error) by a trap in `run.sh`.

Override the image name with `DOCKER_IMAGE=my-image bash run.sh --docker …`
if you maintain a custom runner.

---

## Output files

On a successful run, the following files exist under `<project>/qa/`:

- `qa_report.md` — final report (the headline deliverable)
- `qa_plan.md` — plan Stage 3 generated
- `ingestion_summary.md` — Stage 1 summary
- `test_log.txt` — raw log from Stages 2 and 4
- `tests/` — directory of test scripts (yours or generated by prior runs)

---

## Limitations

- GUI-driven projects cannot be fully exercised without additional tooling.
- Very large monorepos may exceed host resource limits.
- Host mode assumes the required runtimes are already installed; sandbox
  mode avoids this at the cost of a one-time image build.
- The plan generator is rule-based, not inferential — it will not discover
  novel test cases beyond its built-in catalog.
