# Contributing to CcinnClickHouse

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- Docker, if you want to run the integration tests against real ClickHouse servers.

```bash
git clone https://github.com/whiteCcinn/ccinnclickhouse.git
cd ccinnclickhouse
swift build
swift test --skip IntegrationTests
scripts/build-app.sh --open
```

### Integration tests

Test containers are named `ccinnch-it-*`, listen on `127.0.0.1` only and are memory-capped (768 MB) with a low-memory server configuration (`scripts/docker/`).

```bash
scripts/ch-up.sh 24.8 18101 && scripts/seed-demo.sh 18101      # one server + the demo `shop` database
CCINNCH_IT_URL=http://127.0.0.1:18101 swift test --filter IntegrationTests
scripts/it-matrix.sh 22.8 23.8 24.8 25.8 26.8                  # the same suite on every version, one container at a time

scripts/ch-cluster-up.sh 24.8                                   # two replicas + embedded Keeper + chproxy
CCINNCH_IT_CLUSTER=1 CCINNCH_IT_URL=http://127.0.0.1:18111 swift test --filter ClusterIntegrationTests
scripts/ch-down.sh                                              # removes every ccinnch-it-* container
```

Users: `ccinn` / `ccinn-pass` (full access) and `reader` / `reader-pass` (server profile `readonly=1`, used to test settings-locked users). HTTPS tests take `CCINNCH_IT_TLS_URL` and `CCINNCH_IT_TLS_CA` (a server certificate for `clickhouse.test`, `localhost` and `127.0.0.1` signed by that CA).

`scripts/seed-demo.sql` creates the `shop` database used by the tests and screenshots: MergeTree tables of every variant (Replacing, Summing, Aggregating, Collapsing, VersionedCollapsing) with partitions, TTLs, a codec, skipping indexes and a projection, a materialized view, a view, a dictionary, Memory/TinyLog/Null/URL tables and a table with too many parts.

### Running the app against a server directly

```bash
CCINNCLICKHOUSE_PASSWORD=ccinn-pass dist/CcinnClickHouse.app/Contents/MacOS/CcinnClickHouse \
  --connect 127.0.0.1:18101 --user ccinn --database shop --object shop.events --section parts
```

Passwords never go on the command line. Other launch arguments: `--https`, `--cluster <name>`, `--read-only`, `--sql "…" --auto-run [--view chart|plan]`, `--operations running|merges|mutations|replication|querylog|storage|dictionaries|cluster`, `--profile <saved name>`, `--duplicate-window` (once connected, opens a second window with the same connection, as ⇧⌘N does) and `--snapshot <file.png> --snapshot-delay <seconds> --quit-after-snapshot [--appearance light|dark]`, which renders the front window into a PNG without showing it, without a Dock icon and without taking focus.

## Project layout

| Module | Responsibility |
|---|---|
| `ClickHouseWire` | ClickHouse HTTP protocol pieces: type grammar, streaming `TabSeparatedWithNamesAndTypes` parser, exceptions (including mid-stream framings), progress headers, quoting, gzip (no I/O) |
| `ClickHouseKit` | Transport protocol + URLSession transport, client, sessions, cancellation by query id, SSH tunnels, version-adaptive metadata, insights and operations |
| `CcinnClickHouseKit` | UI-independent app logic: profiles, SQL lexer/splitter/auto-limit/read-only guard/redactor, completion, charts, export, history, MCP server and tools |
| `CcinnClickHouse` | SwiftUI/AppKit application and the `mcp` subcommand |

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Add or update tests with every behaviour change. Protocol logic is covered with the local fake HTTP server in `Tests/ClickHouseKitTests/FakeClickHouseServer.swift`; ClickHouse behaviour with the integration suites.
- **Read server output by column name** and build `system.*` queries with `SystemSchema.selectList`, so a column a version lacks becomes `NULL` instead of an error.
- **Never crash on input.** No force unwraps/casts, unchecked indexing or trapping integer conversions on data that comes from a server, a file or the user. Parsers are fuzzed; keep it that way.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; never block the main actor with I/O, sorting or chart preparation; use generation tokens wherever a late result could overwrite a newer one.
- **Secrets** must never appear in logs, errors, URLs or files.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test --skip IntegrationTests` pass (and the integration suites, if you touched ClickHouseKit).
3. Describe what changed and how you tested it (including ClickHouse versions, if relevant).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
