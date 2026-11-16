# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-11-16

### Added

- **Check for Updates…** in the app menu. When a newer release exists, CcinnClickHouse shows its version and release notes. **Download & Open** downloads the disk image, verifies its size and SHA-256 against the release's `SHA256SUMS.txt`, saves it to Downloads without overwriting anything, and opens it. **Release Page**, **Skip This Version** and **Later** are also available.
- A quiet automatic check at most once a day (retried after an hour when offline), on by default, switchable in **Settings → General → Updates**.
- Project links: the Help menu now has **CcinnClickHouse on GitHub**, **Release Notes** and **Report an Issue…**; the About window shows the GitHub link; Settings → General shows the version and project links.

## [1.0.0] - 2026-11-15

First public release.

### Added

- ClickHouse HTTP(S) client over URLSession behind a transport protocol: typed streaming results (`TabSeparatedWithNamesAndTypes`), byte and row limits, exceptions before and in the middle of a result (all framings from 22.x to 26.x), `query_id` on every query, cancellation that aborts the request and kills the query on the node that runs it (retries behind load balancers, `ON CLUSTER` fallback, `log_comment` marker for proxies that rewrite query ids), progress headers and live progress, `session_id` sessions whose database and `SET`s survive expiry, response compression and gzip request bodies, server-enforced `readonly=1` for read-only connections, and graceful degradation for users whose server profile is read-only. Tested against ClickHouse 22.8, 23.8, 24.8, 25.8 and 26.8, a two-replica cluster with embedded Keeper, chproxy and HTTPS with a private CA.
- Connection manager with favourites, recents, colour tags, connection testing, HTTPS (custom CA, skip-verify), path prefixes for reverse proxies, SSH tunnels, read-only connections and Keychain-backed secrets.
- Schema browser: databases with their engines, tables grouped by engine family (MergeTree, Replicated, Distributed, materialized views, views, dictionaries, streaming, integrations, data lakes, Log, Memory & special) with icons and MergeTree-variant badges.
- Table insights: engine and keys, table and column TTLs, settings, compression per column, partitions and parts with part-count warnings against `parts_to_delay_insert` / `parts_to_throw_insert`, skipping indexes, projections, mutations (with kill) and merges, replication status and queue, Distributed targets and pending inserts, materialized-view targets, dictionary status (with reload), DDL and a data preview.
- Operations: running queries across the cluster with kill, merges, mutations, replication health and queue, query-log analysis (slowest, memory, failed, query patterns, per user), disks and storage policies, dictionaries, cluster topology with Keeper, macros and the distributed DDL queue.
- SQL workbench: ClickHouse highlighting (nested comments, heredocs, query parameters), completion from the server (functions with aggregate combinators, settings, formats, engines, table functions, data types, clusters) plus tables, columns, aliases and CTEs, automatic LIMIT that understands `LIMIT … BY`, `SETTINGS` and `FORMAT`, EXPLAIN plan / indexes / actions / pipeline / estimate / AST / syntax, live progress, error positions, history, CSV/TSV/INSERT export (binary values keep their bytes).
- Charts from any result: automatic suggestion, bar / line / area / scatter / pie with series and aggregation, reduced to at most 2,000 points.
- MCP server (`CcinnClickHouse mcp`) so AI clients such as Claude Code, Codex and Claude Desktop can explore databases, tables, parts, merges and mutations, replication, running queries, the query log, storage, dictionaries and the cluster, and run read-only queries on connections the user opted in; read & write access is opt-in per connection, read-only is enforced by ClickHouse (`readonly=1`), and every call is audited.

### Security

- Read-only connections verify on the real request path that ClickHouse applies `readonly` and refuse to open otherwise: chproxy (1.30) drops `readonly=1`, which would let `url()` and friends reach the network. Users whose profile is `readonly=2` are supported.
- The read-only guard (MCP `run_query`, read-only editor batches) refuses functions that reach outside ClickHouse, table functions outside an allow-list, per-query `SETTINGS`, `SYSTEM`, `KILL`, `OPTIMIZE`, `INTO OUTFILE` and `EXPLAIN` of writes, with a lexer that splits statements exactly like ClickHouse.
- History and the MCP audit log redact passwords, keys and tokens in statements and in server error text, and are written with mode 0600 from creation.
- A running MCP server re-reads AI access on every call, so revoking access in Settings takes effect immediately.

[Unreleased]: https://github.com/whiteCcinn/ccinnclickhouse/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/whiteCcinn/ccinnclickhouse/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/whiteCcinn/ccinnclickhouse/releases/tag/v1.0.0
