# Additional Project-Agnostic Language Tests

This folder contains runner-compatible shell tests for common languages and
platform surfaces. Each test:

- sources the zipped `_lib.sh` helper,
- emits `PASS:`, `FAIL:`, and `SKIP:` lines,
- ends with the standard batch summary,
- skips cleanly when the target project does not contain that language.

Included coverage:

- HTML
- CSS
- JavaScript
- TypeScript
- Ruby
- Ubuntu / apt-oriented setup
- Python
- Shell
- Go
- Java
- Rust
- PHP
- JSON/YAML
- Dockerfile
- SQL

Copy these files into a project's `qa/tests` directory, or run one directly:

```bash
PROJECT_DIR=/path/to/project bash html_language_test.sh
```
