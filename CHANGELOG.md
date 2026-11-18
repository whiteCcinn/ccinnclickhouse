# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.3.0] - 2026-11-18

### Added

- **Precise SQL error markers.**
  - The token ClickHouse rejected is underlined (UTF-8 byte positions mapped to the text, including after multi-byte characters): the last token for `end of query`, the opening quote of an unterminated string, the `/*` of an unterminated comment.
  - Errors without a position are located by name: unknown columns (`Unknown expression identifier`, `Missing columns`, qualified names), tables, databases, functions, table functions and settings, on the new and the old analyzer, with `'…'` and `` `…` `` quoting.
  - A short message is shown after the line and in a bar under the editor (line, column, previous / next): `Syntax error near 't'. Expected one of: …` with a shortened list, without the echoed query, keeping `Maybe you meant: [...]`. The result shows the error kind (`Unknown identifier at line 4, column 3`), the full message and **Show in Editor**.
  - `EXPLAIN …` runs and auto-`LIMIT`ed statements map back to the editor.
- **Checks while typing.** Unterminated strings, quoted identifiers, `/* */` comments (nested) and `$$` heredocs, and unclosed or unmatched `(`, `[`, `{` are flagged without contacting the server.
- **Format SQL** (⌥⌘L, the toolbar's **Format** button, or Edit ▸ Format SQL) formats the selection, or the whole script, as one undoable edit.
  - Layout: main clauses on their own lines, including `PREWHERE`, `ARRAY JOIN`, `SAMPLE`, `FINAL`, `LIMIT … BY`, `WITH TOTALS`, `SETTINGS`, `FORMAT` and `INTO OUTFILE`. One item per line in multi-item lists (brackets, tuples and calls keep their commas). `AND`/`OR` conditions on their own lines, indented subqueries and CTEs, split multi-branch `CASE`, and `CREATE TABLE` columns one per line.
  - Keyword case stays as written by default: ClickHouse names and functions are case-sensitive, and almost every keyword is also a valid name. With UPPER or lower (**Settings → General**), only words that can be nothing but a keyword where they stand change case. A word next to `.` (`end.a`) is always a name.
  - Only whitespace changes otherwise. Names, functions, strings, heredocs, `{name:Type}` parameters, comments and `INSERT … FORMAT` data keep their bytes, tokens that touch keep touching (`quantile(0.5)(x)`, `'1'::UInt8`), and CRLF stays CRLF.
  - The result is checked against the original before it replaces anything. When equivalence cannot be proven, the text is left alone and the status line under the editor says why. This happens, for example, with text that ClickHouse versions read differently, such as `1_000` (a name on 22.8), while an input method is composing, or when the text changed meanwhile.
  - `--format` formats the `--sql` launch text.

### Fixed

- Error markers in the SQL editor no longer stay at a stale position after editing: they move with edits made before the failing statement and disappear when that statement is edited or the text is replaced, including edits made while it was still running. Composing text with an input method is never interrupted.
- The SQL lexer reads what ClickHouse reads:
  - `0x1g` and `1e2x` are one name, `.5x` is `.5` then `x`, and `1.2.3` and `x .5` are tuple access;
  - `//` starts a line comment;
  - U+00A0, U+FEFF and the other Unicode spaces ClickHouse skips separate words.
  - Highlighting, statement splitting, the automatic `LIMIT` (which used to land inside a trailing `//` comment) and the read-only guard see what the server sees.
- Typing in a script with many `$` that never close a heredoc (`$0 + $1 + …`) no longer freezes the editor: closing tags are found in one pass. Before, every `$` rescanned the rest of the text, and 350 KB took 9 s to highlight.
- Starting a connect in a window (a double-click, or Connect again) cancels a connect still in flight there. Before, the first one could finish later and leave a live client and SSH tunnel behind, or overwrite the new connect's status and errors.
- SSH tunnels never use or become a shared `ControlMaster` connection from `~/.ssh/config` (`-o ControlMaster=no -o ControlPath=none`).
  - As the master, a tunnel carried your other ssh sessions and cut them when its window closed.
  - As a client of your master, the tunnel left the forwarded port open after disconnecting, bypassing the connection's SSH authentication.

### Security

- **Read-only guard.** The guard behind MCP `run_query` and read-only editor batches could miss what the server reads:
  - Unicode whitespace that ClickHouse skips (U+00A0, U+FEFF, U+200B, …) stuck to the next word, so `SELECT 1,<U+FEFF>file('…')` passed.
  - `//` is a line comment in ClickHouse, but the lexer read two `/` operators. A `'` after `//` then opened a string that hid the following lines from the guard.
  - ClickHouse decodes `\xHH` and `\N` in quoted names, which the guard compared as written: in 1.2.0, `` SELECT 1, `\x66ile`('x') `` passed the guard and opened the file, even with `readonly=1`.
  - `APPLY` names a function without `name(`, so the guard never saw it. In 1.2.0, `SELECT * APPLY(file) FROM (SELECT 'nonexistent.txt' AS p)` passed and opened the file under `readonly=1` on 22.8, 24.8 and 26.8, and on 22.8 and 24.8 for a user with no grants. So did `APPLY file`, ``APPLY(`file`)``, `COLUMNS('p') APPLY(file)`, `t.* APPLY(file)`, `* EXCEPT (q) APPLY(file)` and chained transformers. On 26.8, higher-order functions take a bare function name too (`arrayMap(file, ['x'])`).
  - **Impact:** an AI (MCP) client could make the server read files through `file()`, which `readonly=1` does not stop. Where `readonly=1` is not enforced, it could also call `url()` / `remote()` or change settings.
  - **Fix:** the lexer now reads `//` and that whitespace exactly as every supported server does. The guard refuses any invisible character (Unicode spaces, separators, format and control characters) outside strings, quoted names and comments. It also refuses any number a server may read with different bounds (malformed exponents such as `1e-x`, `1_000.5` on 22.8), any quoted name containing a backslash, and any name with one of the 19 letters whose case mapping holds an ASCII letter (`ſ`, `ı`, `İ`, `K`, `ß`, `ﬁ` …), which ClickHouse does not fold but the guard's comparisons would. It checks every function a statement names: calls anywhere, `APPLY` transformers, bare higher-order arguments and string-named aggregates. It refuses a construct whose function it cannot read.
- **Text changed after the check.** The read-only guard checked a statement before the automatic `LIMIT` was added, then sent the text with the `LIMIT`:
  - Placed after a bare `#`, the inserted ` LIMIT n` turned it into a `# ` comment, which hid the `/*` the guard had trusted.
  - Placed after a lone `$`, it opened a heredoc (22.8, 24.8) that ended inside what the guard took for a comment.
  - In both cases the hidden `file()` call ran, even with `readonly=1`.
  - **Fix:** the guard now checks exactly the text sent, in `run_query`, `explain_query` and read-only editor batches. It refuses a bare `#` and a lone `$`, and the automatic `LIMIT` goes on a line of its own.
- **Privileged users.** Read-only AI access was allowed for any ClickHouse user, including one with `SOURCES` (`file()`, `url()`, `remote()` …), `SYSTEM`, access management or `ALL` grants, none of which `readonly=1` stops.
  - Before every call, read-only AI tools now check the user's grants and the effective `readonly` level. They refuse such a user unless the connection explicitly allows it, and refuse when either cannot be read.
  - AI access reads `system` only through an allow-list of schema and diagnostic tables, and table functions only through an allow-list of generators. Before, it could read other sessions' SQL text and credentials, for example `system.query_log`, `system.processes`, `system.mutations` (UPDATE text with its literals), `system.users`, and `loop('system', 'query_log')`. On 22.8 even a `SELECT`-only user can read `system.query_log`.
  - The tools that show other sessions' SQL (running queries, query log, mutations, the distributed DDL queue and their error texts) now return digests: every string and numeric literal, double-quoted name and unterminated string, quoted name or heredoc becomes `?`, and error texts also lose their quoted names, their statement echoes and every value of their own statement that they repeat unquoted (`Cannot parse uuid …`, throwIf messages). Bare words stay. Before, they masked only credentials, and mutation commands and query-log pattern samples were not masked at all.
  - AI access never receives object definitions, on any version. 22.8 prints credentials in them (MySQL engines, dictionary sources), 24.8 still prints the ones in URLs (`url('http://user:password@…')` in a view), 22.8 and 24.8 inline view queries into `EXPLAIN SYNTAX`, and 26.8 prints view literals in plans. AI access now refuses:
    - the definition columns (`create_table_query`, `engine_full`, `as_select`, `create_query`, `view_definition`, and `query` of `system.projections`) however they are qualified or quoted;
    - `SHOW CREATE`, `SHOW TABLE` / `SHOW VIEW` and `SHOW FUNCTIONS` (SHOW is an allow-list of listing forms);
    - `EXPLAIN SYNTAX`, and EXPLAIN inside another query;
    - `*` other than `count(*)` over `system.tables`, `system.databases`, `system.functions` and `information_schema`;
    - `FORMAT` clauses.
  - `describe_table` returns columns, keys and the engine name, without DDL, engine arguments, settings or view queries. Plans come back with quoted strings shown as `'?'`. Credentials are masked in every result and error the tools return: URL passwords, values of credential-named keys (`password=…`, `PASSWORD '…'`, never a bare `KEY`) and, in DDL text, the credential arguments of table functions and engines. A result with masked values says how many (`"masked": N`); other data is never altered.
  - Views or dictionaries an administrator builds over system tables are invisible to the guard.
  - AI access calls only reviewed functions: the union of what 22.8, 24.8 and 26.8 ship, minus those that reach outside ClickHouse, read objects by name or change state. Before, a deny-list missed 26.8's `ai*` LLM functions, `catboostEvaluate`, and the `filesystem`, `bigquery`, `paimon*Cluster`, `icebergLocalCluster` and `eval` table functions. It also missed name-reading local ones (`timeSeriesSamples`, `mergeTreeTextIndex`, `mergeTreeCodecBlockCounts`, `mergeTreeAnalyzeIndexes`). A newer server's new functions are now refused until an update reviews them. `dictGet` stays allowed by design.
  - A table function after a comma that follows `USING (…)`, `ON …`, `FINAL` or `SAMPLE n` was not recognised (`… JOIN b USING (n), filesystem() AS f` ran for a `readonly=2` user on 26.8). For AI access every call is now checked against the allow-list, and the editor's guard keeps the FROM list across those clauses.
  - A settings profile could change how the server parses statements (26.8, confirmed through `run_query` for a `SELECT`-only user).
    - `dialect = 'polyglot'` with `polyglot_dialect = 'postgresql'` reads `'\'` as a whole string, so `SELECT '\', (SELECT query FROM system.query_log …) --'` returned other sessions' SQL.
    - `implicit_table_at_top_level = 'system.query_log'` answered `SELECT query WHERE …`.
    - Read-only requests now send the safe values of the parser settings, and every read-only path (connect, each AI tool call including the metadata tools, each editor batch) verifies them, together with `readonly`, failing closed.
    - App-built string literals double `'` instead of writing `\'`.
  - The privilege check follows `system.privileges`' hierarchy, so individual grants such as `GRANT aiGenerate ON *.*` count as risky like their group. A privilege the hierarchy does not know is risky.
  - MCP tool arguments other than `sql` (connection, database, table, filters) are refused when they hold a control character (NUL, C0, DEL, C1), before anything is sent. Identifier quoting now escapes control characters (`\xHH`) instead of dropping NUL, so a name reaches the server exactly as it was checked.
  - Scalar `file()` needs no grant on 22.8 and 24.8. There the guard, which refuses it, is the only barrier.
- **Per-query `SETTINGS`.** The guard could miss a `SETTINGS` clause, which it is meant to refuse:
  - after a number starting with `.` (`SELECT 1, .5settings max_threads = 1`), which every server reads as `.5` followed by the clause;
  - behind a heredoc whose tag has characters other than letters, digits and `_` (`$a b$ … $a b$`), which 22.8 and 24.8 read as one string but 26.8 reads as names, running the clause.
  - The guard now sees the first. It refuses the second, along with unterminated strings, quoted names and comments.
  - Servers that apply `readonly=1` refused these settings anyway. Profiles with `readonly=2`, and proxies that drop `readonly=1`, did not.

## [1.2.0] - 2026-11-17

### Added

- **Multiple windows made easy.** File ▸ **New Window with This Connection** (⇧⌘N) and the toolbar's **New Window** button open the current connection in another window, with the password already in use, so unsaved connections and passwords not in the Keychain work too. Saved connections have **Open in New Window**, and the connection screen has a **New Window** button. Every window keeps its own connection (its own HTTP sessions and SSH tunnel); closing one disconnects only that window. A window that macOS restores after a relaunch shows the connection screen instead of connecting by itself.

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

[Unreleased]: https://github.com/whiteCcinn/ccinnclickhouse/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/whiteCcinn/ccinnclickhouse/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/whiteCcinn/ccinnclickhouse/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnclickhouse/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/whiteCcinn/ccinnclickhouse/releases/tag/v1.0.0
