# mysql-ai — `ollama_embed()` MySQL UDF

A MySQL C/C++ User-Defined Function (UDF) that generates text embeddings
by calling an [Ollama](https://ollama.ai) instance and returns the result
as a MySQL native **`VECTOR`** binary value, ready for use with MySQL 8.0.45
Commercial (Enterprise Edition) vector distance functions.

The system is modelled on ChromaDB's concepts:
- **Connection profiles** — named configurations (endpoint, model, auth, TLS) stored in `ollama_profiles`
- **Collections** — named document stores scoped to a profile, each backed by its own `VECTOR(n)` table
- **Session-local active profile** — `@ollama_active_profile` is per-connection, so concurrent sessions can use different models independently

No DDL, no recompile, no hardcoded dimension constants.

---

## Overview

```sql
-- 1. Create a connection profile (probes model, stores dims automatically)
CALL ollama_profile_create(
    'local-qwen3',
    'qwen3-embedding:0.6b',
    'http://localhost:11434/api/embeddings',
    NULL, NULL, 1  -- api_key, ssl_cert_path, ssl_verify_off=1 (skip TLS for local Ollama)
);

-- 2. Create named collections under that profile
CALL ollama_collection_create('github.my-repo');
CALL ollama_collection_create('confluence.team-wiki');

-- 3. Insert documents
CALL embed_insert('github.my-repo', 'Fix null pointer in auth middleware');

-- 4. Search by semantic similarity (returns score and similarity_pct)
CALL embed_search('github.my-repo', 'crash on login', 5);

-- See all profiles and their collections
SELECT * FROM v_collections;
```

The active profile is stored in the session variable `@ollama_active_profile`.
Each connection manages its own active profile independently.

---

## Repository Structure

```
mysql-ai/
├── README.md
├── CMakeLists.txt
├── src/
│   └── ollama_embed.cc   # UDF implementation (C++17)
├── include/
│   ├── cJSON.h           # Bundled cJSON header (v1.7.x)
│   └── cJSON.c           # Bundled cJSON implementation
└── sql/
    └── setup.sql         # Schema bootstrap: profiles, collections, procedures
```

---

## Prerequisites

| Requirement | Version / Notes |
|---|---|
| MySQL | **8.0.45 Commercial (Enterprise Edition)** with native `VECTOR` type |
| Ollama | Running locally on `http://localhost:11434` |
| Ollama model | `qwen3-embedding:0.6b` pulled (`ollama pull qwen3-embedding:0.6b`) |
| libcurl | Development headers + shared library (`libcurl-dev` / `libcurl-devel`) |
| CMake | 3.14 or newer |
| C++ compiler | GCC ≥ 7 or Clang ≥ 5 with C++17 support |
| MySQL dev headers | `libmysqlclient-dev` or the MySQL Connector/C package |

---

## Build Instructions

```bash
# 1. Clone this repository
git clone https://github.com/robmcc1/mysql-ai.git
cd mysql-ai

# 2. Create a build directory
mkdir build && cd build

# 3. Configure — tell CMake where your MySQL headers live
cmake .. -DMYSQL_INCLUDE_DIR=/usr/include/mysql

# 4. Build the shared library
make -j$(nproc)
# → produces  build/ollama_embed.so
```

> **Tip:** If `mysql.h` is in a non-standard location (e.g. a tarball install),
> pass the full path:
> ```bash
> cmake .. -DMYSQL_INCLUDE_DIR=/usr/local/mysql/include
> ```

---

## Installation

### Step 1 — Copy the shared library to MySQL's plugin directory

```bash
# Find the plugin directory
mysql_plugin_dir=$(mysql -u root -p -se "SHOW VARIABLES LIKE 'plugin_dir'" | awk '{print $2}')

sudo cp build/ollama_embed.so "$mysql_plugin_dir"
```

Or use the CMake install target by configuring `MYSQL_PLUGIN_DIR` explicitly:

```bash
cmake -S . -B build -DMYSQL_PLUGIN_DIR="$mysql_plugin_dir"
sudo cmake --install build
```

### Step 2 — Bootstrap the schema

```bash
mysql -u root -p < sql/setup.sql
```

`setup.sql` registers the UDF, creates the `ollama_profiles`, `ollama_collections`,
and `v_collections` tables/view, and defines all stored procedures and functions.
No data is pre-populated — use `ollama_profile_create()` to configure your first
profile after the schema is installed.

> **Note:** `setup.sql` does **not** set `SET GLOBAL log_bin_trust_function_creators`.
> The stored functions use `READS SQL DATA` / `NOT DETERMINISTIC` declarations which
> satisfy MySQL's binary-log safety requirements.  If you encounter a binary-log error
> on a stricter server configuration, add `log_bin_trust_function_creators = 1` to
> your `my.cnf` instead.

To register only the UDF manually:

```sql
CREATE FUNCTION ollama_embed RETURNS STRING SONAME 'ollama_embed.so';
```

---

## Profiles

A **profile** bundles everything needed to reach a specific model: endpoint URL,
model name, optional API key, and TLS settings.  Profiles are stored in
`ollama_profiles` and never change how existing collections work — switching
profiles only affects what the current session sees.

### Creating a profile

```sql
CALL ollama_profile_create(
    'local-qwen3',                                  -- profile name (unique)
    'qwen3-embedding:0.6b',                         -- Ollama model name
    'http://localhost:11434/api/embeddings',         -- API endpoint
    NULL,                                           -- api_key:  NULL = no auth
    NULL,                                           -- ssl_cert_path: NULL = system CA
    1                                               -- ssl_verify_off: 1 = skip TLS (local Ollama)
);
-- Creates profile, probes model to determine dims, activates it for this session.

-- Remote endpoint with auth and TLS enforcement
CALL ollama_profile_create(
    'remote-nomic',
    'nomic-embed-text',
    'https://my-ollama-host:11434/api/embeddings',
    'sk-my-api-key',
    '/etc/ssl/certs/my-ca.crt',
    0                                               -- ssl_verify_off: 0 = enforce TLS (default, secure)
);
```

### Switching profiles

```sql
CALL ollama_profile_use('remote-nomic');
```

All subsequent `embed_insert()` and `embed_search()` calls in this connection
use the `remote-nomic` profile until changed.  Other connections are unaffected.

### Listing profiles

```sql
SELECT id, name, model, dims, api_url, created_date FROM ollama_profiles;
```

### Per-call overrides (advanced)

The raw UDF accepts all settings as optional arguments.  Useful for
one-off calls without changing the active profile:

```sql
ollama_embed(text [, model [, api_url [, api_key [, ssl_cert_path [, ssl_verify_off]]]]])
```

---

## Collections

A **collection** is a named document store scoped to a profile.  Each collection
gets its own physical `VECTOR(dims)` table created automatically with the
dimension count from the profile.

### Creating and managing collections

```sql
-- Create collections (active profile must be set)
CALL ollama_collection_create('github.my-repo');
CALL ollama_collection_create('confluence.team-wiki');
CALL ollama_collection_create('journalctl.httpd.2026-04-28.ERROR');

-- List all collections across all profiles
SELECT * FROM v_collections;

-- Drop a collection and its backing table
CALL ollama_collection_drop('github.my-repo');
```

Collection names can be any string — dots, dashes, slashes, and mixed case
are all allowed.  The physical table name is derived automatically
(e.g., `coll_1_github_my_repo`) and stored in `ollama_collections`.

### Inserting documents

```sql
CALL embed_insert('github.my-repo', 'Fix null pointer in auth middleware');
CALL embed_insert('github.my-repo', 'Add retry logic to webhook handler');
CALL embed_insert('confluence.team-wiki', 'On-call runbook for database alerts');
```

### Semantic similarity search

```sql
-- Returns top 5 by cosine similarity
-- Columns: id, content, created_date, updated_date, score (lower = more similar, [0,2]),
--          similarity_pct (higher = more similar, 0–100)
CALL embed_search('github.my-repo', 'crash on login', 5);
```

For custom distance metrics or WHERE filters, query the collection table
directly using the `embed()` helper (reads active profile automatically):

```sql
-- L2 distance with a tag filter (replace dims with your profile's dims)
SELECT id, content,
       VECTOR_L2_DISTANCE(embedding, CAST(embed('search text') AS VECTOR(896))) AS score
FROM   coll_1_github_my_repo
ORDER  BY score ASC
LIMIT  5;
```

---

## Notes

### TLS verification default
TLS peer and host verification is **enabled by default** (`ssl_verify_off = 0`).
Pass `ssl_verify_off = 1` explicitly when connecting to a local Ollama instance
over plain HTTP or a self-signed certificate.  Always use `ssl_verify_off = 0`
for remote or production Ollama endpoints.

### Vector index
Each collection table is created with a `VECTOR INDEX` on the `embedding` column,
enabling MySQL 8.0.45 Enterprise's Approximate Nearest Neighbor (ANN) search.
This avoids full table scans during `embed_search` calls.

### Embedding dimensions
The UDF accepts whatever dimension count the model returns — there is no
hardcoded limit.  `ollama_profile_create()` probes the model on creation
and stores the actual dimension count in `ollama_profiles.dims`.
Collections always inherit the correct VECTOR size from their profile.

### Multiple profiles, one database
Profiles and collections coexist in the same `ai_demo` database.  Each
collection table is prefixed with the profile ID (`coll_<id>_<name>`) so
there is no name collision across profiles.  You can query `v_collections`
at any time to see the full picture.

### Binary VECTOR format
MySQL's `VECTOR` type stores embeddings as a packed binary sequence of
little-endian IEEE 754 single-precision (32-bit) floats.  `embed()`
produces exactly this format, so the result can be inserted directly into a
`VECTOR(896)` column or passed to any of the built-in distance functions.

### MySQL VECTOR type availability
The native `VECTOR` column type and the `VECTOR_COSINE_DISTANCE`,
`VECTOR_L2_DISTANCE`, and `VECTOR_INNER_PRODUCT` functions require
**MySQL 8.0.45 Commercial (Enterprise Edition)**.  They are not available in
MySQL Community Edition or earlier versions.

### Error handling
All procedures fail with a descriptive `SIGNAL SQLSTATE '45000'` error if
Ollama is unreachable, no active profile is set, or a collection is not
found.  The raw UDF returns `NULL` on failure and logs to the MySQL error
log (stderr).  Check `SHOW WARNINGS` or the server error log for details.

---

## Uninstalling

Drop collection tables first (they are not cascade-dropped):

```sql
-- Generate DROP statements for all collection tables
SELECT CONCAT('DROP TABLE IF EXISTS `', table_name, '`;')
FROM   ollama_collections;

-- Then drop procedures, functions, and schema tables
DROP PROCEDURE IF EXISTS embed_search;
DROP PROCEDURE IF EXISTS embed_insert;
DROP PROCEDURE IF EXISTS ollama_collection_drop;
DROP PROCEDURE IF EXISTS ollama_collection_create;
DROP PROCEDURE IF EXISTS ollama_profile_use;
DROP PROCEDURE IF EXISTS ollama_profile_create;
DROP FUNCTION  IF EXISTS embed;
DROP VIEW      IF EXISTS v_collections;
DROP TABLE     IF EXISTS ollama_collections;
DROP TABLE     IF EXISTS ollama_profiles;
DROP FUNCTION  IF EXISTS ollama_embed;
```

Then remove `ollama_embed.so` from the plugin directory.

---

## License

This project is released under the MIT License.
cJSON is © Dave Gamble and contributors, also released under the MIT License.