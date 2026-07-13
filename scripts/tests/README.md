# Data-pipeline tests

Fixture-driven pytest suite for the HTML/text parsing logic in
`fetch_codeword_data.py`, `build_dyk.py`, and `check_codewords.py`. No
network access, no manifest/repo file writes — everything runs against
in-memory HTML strings or `tmp_path` fixtures.

Run from `scripts/`:

```sh
cd scripts
uv run pytest
```

`uv` creates a local `.venv` on first run (gitignored). Not wired into
`scripts/build.sh` — run manually or in CI.
