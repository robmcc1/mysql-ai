-- =============================================================================
-- setup.sql — Install the ollama_embed() UDF and create example objects
--
-- Prerequisites:
--   1. ollama_embed.so has been copied to the MySQL plugin directory.
--      (Run: sudo cp build/ollama_embed.so $(mysql_config --plugindir))
--   2. The Ollama service is running locally on port 11434 with the
--      qwen3-embedding:0.6b model pulled.
--   3. MySQL 8.0.45 Commercial (Enterprise Edition).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Register the UDF with MySQL
-- ---------------------------------------------------------------------------
CREATE FUNCTION IF NOT EXISTS ollama_embed
    RETURNS STRING
    SONAME 'ollama_embed.so';

-- ---------------------------------------------------------------------------
-- 2. Example schema
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ai_demo;
USE ai_demo;

CREATE TABLE IF NOT EXISTS documents (
    id        INT          AUTO_INCREMENT PRIMARY KEY,
    content   TEXT         NOT NULL,
    embedding VECTOR(896)          -- qwen3-embedding:0.6b outputs 896 dimensions
);

-- ---------------------------------------------------------------------------
-- 3. Example inserts
--    The UDF calls Ollama and stores the resulting 896-dim embedding as a
--    native MySQL VECTOR value.
-- ---------------------------------------------------------------------------
INSERT INTO documents (content, embedding)
VALUES
    ('Hello world',                ollama_embed('Hello world')),
    ('The quick brown fox',        ollama_embed('The quick brown fox')),
    ('MySQL vector search is fast', ollama_embed('MySQL vector search is fast'));

-- ---------------------------------------------------------------------------
-- 4. Example similarity search
--    VECTOR_COSINE_DISTANCE returns a value in [0, 2]; lower = more similar.
-- ---------------------------------------------------------------------------
SELECT
    content,
    VECTOR_COSINE_DISTANCE(embedding, ollama_embed('my search query')) AS score
FROM   documents
ORDER  BY score ASC
LIMIT  5;

-- ---------------------------------------------------------------------------
-- 5. Optional: drop the UDF
-- ---------------------------------------------------------------------------
-- DROP FUNCTION IF EXISTS ollama_embed;
