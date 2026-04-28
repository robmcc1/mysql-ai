# mysql-ai — `ollama_embed()` MySQL UDF

A MySQL C/C++ User-Defined Function (UDF) that generates text embeddings
by calling a local [Ollama](https://ollama.ai) instance and returns the result
as a MySQL native **`VECTOR`** binary value, ready for use with MySQL 8.0.45
Commercial (Enterprise Edition) vector distance functions.

---

## Overview

```sql
-- Store a document with its embedding
INSERT INTO documents (content, embedding)
VALUES ('Hello world', ollama_embed('Hello world'));

-- Find the 5 most similar documents to a query
SELECT content,
       VECTOR_COSINE_DISTANCE(embedding, ollama_embed('my search query')) AS score
FROM   documents
ORDER  BY score ASC
LIMIT  5;
```

`ollama_embed(text)` accepts a plain-text string, POSTs it to the local Ollama
REST API (`http://localhost:11434/api/embeddings`) using the
`qwen3-embedding:0.6b` model, and returns the 896-dimensional embedding
packed as a binary blob of IEEE 754 little-endian 32-bit floats — the exact
binary format expected by MySQL's `VECTOR` column type.

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
    └── setup.sql         # UDF registration + example table, insert, search
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

Or use the CMake install target (override `MYSQL_PLUGIN_DIR` if needed):

```bash
sudo cmake --install build --prefix /usr/lib/mysql/plugin
```

### Step 2 — Register the UDF with MySQL

```bash
mysql -u root -p < sql/setup.sql
```

Or manually in a MySQL session:

```sql
CREATE FUNCTION ollama_embed RETURNS STRING SONAME 'ollama_embed.so';
```

---

## Usage

### Create a table with a `VECTOR` column

```sql
CREATE TABLE documents (
    id        INT   AUTO_INCREMENT PRIMARY KEY,
    content   TEXT  NOT NULL,
    embedding VECTOR(896)   -- qwen3-embedding:0.6b outputs 896 dimensions
);
```

### Insert rows with automatic embedding

```sql
INSERT INTO documents (content, embedding)
VALUES ('Hello world', ollama_embed('Hello world'));
```

### Semantic similarity search

```sql
-- Cosine distance: lower score = more similar (range [0, 2])
SELECT content,
       VECTOR_COSINE_DISTANCE(embedding, ollama_embed('my search query')) AS score
FROM   documents
ORDER  BY score ASC
LIMIT  5;

-- L2 (Euclidean) distance
SELECT content,
       VECTOR_L2_DISTANCE(embedding, ollama_embed('my search query')) AS score
FROM   documents
ORDER  BY score ASC
LIMIT  5;

-- Inner product (higher = more similar for normalized vectors)
SELECT content,
       VECTOR_INNER_PRODUCT(embedding, ollama_embed('my search query')) AS score
FROM   documents
ORDER  BY score DESC
LIMIT  5;
```

---

## Notes

### Embedding dimensions
`qwen3-embedding:0.6b` produces **896-dimensional** embeddings.  The
`VECTOR(896)` column type and all distance function calls must use this size.
If you switch to a different Ollama model, update both the `VECTOR(n)` column
definition and the constant `EXPECTED_DIMS` in `src/ollama_embed.cc`.

### Binary VECTOR format
MySQL's `VECTOR` type stores embeddings as a packed binary sequence of
little-endian IEEE 754 single-precision (32-bit) floats.  `ollama_embed()`
produces exactly this format, so the result can be inserted directly into a
`VECTOR(896)` column or passed to any of the built-in distance functions.

### MySQL VECTOR type availability
The native `VECTOR` column type and the `VECTOR_COSINE_DISTANCE`,
`VECTOR_L2_DISTANCE`, and `VECTOR_INNER_PRODUCT` functions require
**MySQL 8.0.45 Commercial (Enterprise Edition)**.  They are not available in
MySQL Community Edition or earlier versions.

### Error handling
If Ollama is not running, the model is not loaded, or the HTTP request fails
for any other reason, `ollama_embed()` returns `NULL` and logs an error
message to the MySQL error log (stderr).  Check `SHOW WARNINGS` or the server
error log for details.

---

## Uninstalling

```sql
DROP FUNCTION IF EXISTS ollama_embed;
```

Then remove `ollama_embed.so` from the plugin directory.

---

## License

MIT — see [LICENSE](LICENSE) for details.
cJSON is © Dave Gamble and contributors, also released under the MIT License.