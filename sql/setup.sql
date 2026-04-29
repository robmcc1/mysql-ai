-- =============================================================================
-- setup.sql — Schema bootstrap for the ollama_embed UDF
--
-- Idempotent: safe to re-run.  Does NOT drop existing profiles or collections.
--
-- Prerequisites:
--   1. ollama_embed.so copied to the MySQL plugin directory.
--      (Run: sudo cp build/ollama_embed.so $(mysql_config --plugindir))
--   2. MySQL 8.0.45 Commercial (Enterprise Edition).
--   3. Ollama running and reachable before calling ollama_profile_create().
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Allow stored functions/procedures to invoke UDFs and read tables
--    when binary logging is enabled (default on most servers).
--    For a permanent fix add this to my.cnf:
--        log_bin_trust_function_creators = 1
-- ---------------------------------------------------------------------------
SET GLOBAL log_bin_trust_function_creators = 1;

-- ---------------------------------------------------------------------------
-- 1. Register the UDF
-- ---------------------------------------------------------------------------
CREATE FUNCTION IF NOT EXISTS ollama_embed
    RETURNS STRING
    SONAME 'ollama_embed.so';

-- ---------------------------------------------------------------------------
-- 2. Schema
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ai_demo;
USE ai_demo;

-- Connection profiles — one row per (Ollama endpoint + model) combination.
-- ollama_profile_create() probes the model on creation and stores dims.
CREATE TABLE IF NOT EXISTS ollama_profiles (
    id             INT           AUTO_INCREMENT PRIMARY KEY,
    name           VARCHAR(128)  NOT NULL UNIQUE,
    model          VARCHAR(255)  NOT NULL,
    api_url        VARCHAR(1024) NOT NULL DEFAULT 'http://localhost:11434/api/embeddings',
    api_key        VARCHAR(1024) DEFAULT NULL,        -- NULL = no auth header
    ssl_cert_path  VARCHAR(1024) DEFAULT NULL,        -- NULL = system CA bundle
    ssl_verify_off TINYINT(1)    NOT NULL DEFAULT 1,  -- 1 = skip TLS verify; 0 = enforce
    dims           INT           NOT NULL,            -- actual dims; set by probe at creation
    created_date   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Named document collections.  Each collection belongs to one profile and
-- is backed by a dedicated physical table created by ollama_collection_create().
CREATE TABLE IF NOT EXISTS ollama_collections (
    id              INT          AUTO_INCREMENT PRIMARY KEY,
    profile_id      INT          NOT NULL,
    collection_name VARCHAR(255) NOT NULL,
    table_name      VARCHAR(64)  NOT NULL,
    created_date    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE  KEY uq_profile_collection (profile_id, collection_name),
    CONSTRAINT fk_coll_profile FOREIGN KEY (profile_id)
        REFERENCES ollama_profiles (id) ON DELETE CASCADE
);

-- Convenience view — all collections annotated with their profile details.
CREATE OR REPLACE VIEW v_collections AS
SELECT
    p.name           AS profile_name,
    p.model,
    p.dims,
    c.collection_name,
    c.table_name,
    c.created_date
FROM  ollama_collections c
JOIN  ollama_profiles    p ON p.id = c.profile_id
ORDER BY p.name, c.collection_name;

-- ---------------------------------------------------------------------------
-- 3. embed(text)  — low-level, profile-aware helper
--    Returns the raw VECTOR binary blob for p_text using the active profile
--    (@ollama_active_profile).  Most callers should use embed_insert() /
--    embed_search() instead; embed() is for custom distance queries.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS embed;

DELIMITER $$
CREATE FUNCTION embed(p_text TEXT)
RETURNS MEDIUMBLOB
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_model    VARCHAR(255);
    DECLARE v_url      VARCHAR(1024);
    DECLARE v_api_key  VARCHAR(1024);
    DECLARE v_ssl_cert VARCHAR(1024);
    DECLARE v_ssl_off  TINYINT(1);

    SELECT model, api_url, api_key, ssl_cert_path, ssl_verify_off
    INTO   v_model, v_url, v_api_key, v_ssl_cert, v_ssl_off
    FROM   ollama_profiles
    WHERE  name = @ollama_active_profile
    LIMIT  1;

    IF v_model IS NULL THEN
        RETURN NULL;  -- no active profile; caller must CALL ollama_profile_use()
    END IF;

    RETURN ollama_embed(
        p_text,
        v_model,
        v_url,
        v_api_key,
        v_ssl_cert,
        IF(v_ssl_off, '1', '0')
    );
END $$
DELIMITER ;

-- ---------------------------------------------------------------------------
-- 4. ollama_profile_create(name, model, api_url, api_key, ssl_cert_path, ssl_verify_off)
--
--    Creates a new connection profile.  Probes the model to verify
--    connectivity and record the exact embedding dimension count.
--    Activates the new profile for the current session.
--
--    api_key       NULL or '' = no auth header
--    ssl_cert_path NULL or '' = system CA bundle
--    ssl_verify_off 1 = skip TLS verification (local default)
--                   0 = enforce (use for remote/production endpoints)
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS ollama_profile_create;

DELIMITER $$
CREATE PROCEDURE ollama_profile_create(
    IN p_name     VARCHAR(128),
    IN p_model    VARCHAR(255),
    IN p_api_url  VARCHAR(1024),
    IN p_api_key  VARCHAR(1024),
    IN p_ssl_cert VARCHAR(1024),
    IN p_ssl_off  TINYINT(1))
BEGIN
    DECLARE v_dims INT;

    SET @__probe = ollama_embed(
        'probe',
        p_model,
        p_api_url,
        NULLIF(p_api_key,  ''),
        NULLIF(p_ssl_cert, ''),
        IF(p_ssl_off, '1', '0')
    );

    IF @__probe IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'ollama_profile_create: model probe returned NULL — '
                'verify api_url, model name, api_key, and Ollama status';
    END IF;

    SET v_dims = LENGTH(@__probe) / 4;

    INSERT INTO ollama_profiles
        (name, model, api_url, api_key, ssl_cert_path, ssl_verify_off, dims)
    VALUES
        (p_name, p_model, p_api_url,
         NULLIF(p_api_key, ''), NULLIF(p_ssl_cert, ''),
         p_ssl_off, v_dims);

    SET @ollama_active_profile = p_name;

    SELECT CONCAT(
        'Profile "', p_name, '" created and activated  |  ',
        'model: ', p_model, '  |  dims: ', v_dims
    ) AS status;
END $$
DELIMITER ;

-- ---------------------------------------------------------------------------
-- 5. ollama_profile_use(name)
--    Switches the active profile for this session.
--    @ollama_active_profile is connection-scoped: each connection tracks
--    its own active profile independently.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS ollama_profile_use;

DELIMITER $$
CREATE PROCEDURE ollama_profile_use(IN p_name VARCHAR(128))
BEGIN
    DECLARE v_id INT;

    SELECT id INTO v_id
    FROM   ollama_profiles
    WHERE  name = p_name
    LIMIT  1;

    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ollama_profile_use: profile not found';
    END IF;

    SET @ollama_active_profile = p_name;

    SELECT CONCAT('Active profile → "', p_name, '"') AS status;
END $$
DELIMITER ;

-- ---------------------------------------------------------------------------
-- 6. ollama_collection_create(collection_name)
--    Creates a named collection under the active profile.
--    collection_name can be any string — dots, dashes, mixed case are fine
--    (e.g., 'github.my-org/repo', 'journalctl.httpd.2026-04-28.ERROR').
--    The physical table name is derived and stored automatically.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS ollama_collection_create;

DELIMITER $$
CREATE PROCEDURE ollama_collection_create(IN p_collection VARCHAR(255))
BEGIN
    DECLARE v_profile_id INT;
    DECLARE v_dims       INT;
    DECLARE v_table      VARCHAR(64);
    DECLARE v_safe       VARCHAR(50);

    SELECT id, dims
    INTO   v_profile_id, v_dims
    FROM   ollama_profiles
    WHERE  name = @ollama_active_profile
    LIMIT  1;

    IF v_profile_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'ollama_collection_create: no active profile — '
                'call ollama_profile_use() or ollama_profile_create() first';
    END IF;

    -- Derive a safe physical table name: coll_<profile_id>_<sanitized_name>
    SET v_safe  = LEFT(REGEXP_REPLACE(LOWER(p_collection), '[^a-z0-9]+', '_'), 50);
    SET v_table = CONCAT('coll_', v_profile_id, '_', v_safe);

    SET @__ddl = CONCAT(
        'CREATE TABLE IF NOT EXISTS `', v_table, '` (',
            '`id`           INT      AUTO_INCREMENT PRIMARY KEY,',
            '`content`      TEXT     NOT NULL,',
            '`embedding`    VECTOR(', v_dims, '),',
            '`created_date` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,',
            '`updated_date` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        ')'
    );
    PREPARE __stmt FROM @__ddl;
    EXECUTE __stmt;
    DEALLOCATE PREPARE __stmt;

    INSERT INTO ollama_collections (profile_id, collection_name, table_name)
        VALUES (v_profile_id, p_collection, v_table)
        ON DUPLICATE KEY UPDATE table_name = VALUES(table_name);

    SELECT CONCAT(
        'Collection "', p_collection, '" ready  |  ',
        'table: `', v_table, '`  |  dims: ', v_dims
    ) AS status;
END $$
DELIMITER ;

-- ---------------------------------------------------------------------------
-- 7. ollama_collection_drop(collection_name)
--    Drops a named collection and its backing table under the active profile.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS ollama_collection_drop;

DELIMITER $$
CREATE PROCEDURE ollama_collection_drop(IN p_collection VARCHAR(255))
BEGIN
    DECLARE v_profile_id INT;
    DECLARE v_table      VARCHAR(64);

    SELECT id INTO v_profile_id
    FROM   ollama_profiles
    WHERE  name = @ollama_active_profile
    LIMIT  1;

    IF v_profile_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'ollama_collection_drop: no active profile — call ollama_profile_use() first';
    END IF;

    SELECT table_name INTO v_table
    FROM   ollama_collections
    WHERE  profile_id = v_profile_id AND collection_name = p_collection
    LIMIT  1;

    IF v_table IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ollama_collection_drop: collection not found';
    END IF;

    SET @__ddl = CONCAT('DROP TABLE IF EXISTS `', v_table, '`');
    PREPARE __stmt FROM @__ddl;
    EXECUTE __stmt;
    DEALLOCATE PREPARE __stmt;

    DELETE FROM ollama_collections
    WHERE  profile_id = v_profile_id AND collection_name = p_collection;

    SELECT CONCAT(
        'Collection "', p_collection, '" and table `', v_table, '` dropped'
    ) AS status;
END $$
DELIMITER ;

-- ---------------------------------------------------------------------------
-- 8. embed_insert(collection_name, content)
--    Embeds p_content and appends it to the named collection under the
--    active profile.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS embed_insert;

DELIMITER $$
CREATE PROCEDURE embed_insert(IN p_collection VARCHAR(255), IN p_content TEXT)
BEGIN
    DECLARE v_profile_id INT;
    DECLARE v_dims       INT;
    DECLARE v_model      VARCHAR(255);
    DECLARE v_url        VARCHAR(1024);
    DECLARE v_api_key    VARCHAR(1024);
    DECLARE v_ssl_cert   VARCHAR(1024);
    DECLARE v_ssl_off    TINYINT(1);
    DECLARE v_table      VARCHAR(64);

    SELECT p.id, p.dims, p.model, p.api_url, p.api_key, p.ssl_cert_path, p.ssl_verify_off
    INTO   v_profile_id, v_dims, v_model, v_url, v_api_key, v_ssl_cert, v_ssl_off
    FROM   ollama_profiles p
    WHERE  p.name = @ollama_active_profile
    LIMIT  1;

    IF v_profile_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'embed_insert: no active profile — call ollama_profile_use() first';
    END IF;

    SELECT table_name INTO v_table
    FROM   ollama_collections
    WHERE  profile_id = v_profile_id AND collection_name = p_collection
    LIMIT  1;

    IF v_table IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'embed_insert: collection not found — call ollama_collection_create() first';
    END IF;

    SET @__raw = ollama_embed(
        p_content, v_model, v_url, v_api_key, v_ssl_cert,
        IF(v_ssl_off, '1', '0')
    );

    IF @__raw IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'embed_insert: embedding returned NULL — check Ollama status and active profile';
    END IF;

    SET @__content = p_content;
    SET @__sql = CONCAT(
        'INSERT INTO `', v_table, '` (content, embedding) ',
        'VALUES (?, CAST(? AS VECTOR(', v_dims, ')))'
    );
    PREPARE __stmt FROM @__sql;
    EXECUTE __stmt USING @__content, @__raw;
    DEALLOCATE PREPARE __stmt;
END $$
DELIMITER ;

-- ---------------------------------------------------------------------------
-- 9. embed_search(collection_name, query, limit)
--    Returns top p_limit rows from the named collection ranked by cosine
--    similarity to p_query (lower score = more similar, range [0, 2]).
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS embed_search;

DELIMITER $$
CREATE PROCEDURE embed_search(
    IN p_collection VARCHAR(255),
    IN p_query      TEXT,
    IN p_limit      INT)
BEGIN
    DECLARE v_profile_id INT;
    DECLARE v_dims       INT;
    DECLARE v_model      VARCHAR(255);
    DECLARE v_url        VARCHAR(1024);
    DECLARE v_api_key    VARCHAR(1024);
    DECLARE v_ssl_cert   VARCHAR(1024);
    DECLARE v_ssl_off    TINYINT(1);
    DECLARE v_table      VARCHAR(64);

    SELECT p.id, p.dims, p.model, p.api_url, p.api_key, p.ssl_cert_path, p.ssl_verify_off
    INTO   v_profile_id, v_dims, v_model, v_url, v_api_key, v_ssl_cert, v_ssl_off
    FROM   ollama_profiles p
    WHERE  p.name = @ollama_active_profile
    LIMIT  1;

    IF v_profile_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'embed_search: no active profile — call ollama_profile_use() first';
    END IF;

    SELECT table_name INTO v_table
    FROM   ollama_collections
    WHERE  profile_id = v_profile_id AND collection_name = p_collection
    LIMIT  1;

    IF v_table IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'embed_search: collection not found — call ollama_collection_create() first';
    END IF;

    SET @__raw = ollama_embed(
        p_query, v_model, v_url, v_api_key, v_ssl_cert,
        IF(v_ssl_off, '1', '0')
    );

    IF @__raw IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'embed_search: embedding returned NULL — check Ollama status and active profile';
    END IF;

    SET @__limit = p_limit;
    SET @__sql = CONCAT(
        'SELECT id, content, created_date, updated_date, ',
        'VECTOR_COSINE_DISTANCE(embedding, CAST(? AS VECTOR(', v_dims, '))) AS score ',
        'FROM `', v_table, '` ',
        'ORDER BY score ASC ',
        'LIMIT ?'
    );
    PREPARE __stmt FROM @__sql;
    EXECUTE __stmt USING @__raw, @__limit;
    DEALLOCATE PREPARE __stmt;
END $$
DELIMITER ;

-- =============================================================================
-- Quick-start (uncomment to run)
-- =============================================================================
--
-- CALL ollama_profile_create(
--     'local-qwen3',                                   -- profile name
--     'qwen3-embedding:0.6b',                          -- model
--     'http://localhost:11434/api/embeddings',          -- api_url
--     NULL,                                            -- api_key: NULL = no auth
--     NULL,                                            -- ssl_cert_path: NULL = system CA
--     1                                                -- ssl_verify_off: 1 = skip (local)
-- );
--
-- CALL ollama_collection_create('github.my-repo');
-- CALL ollama_collection_create('confluence.team-wiki');
-- CALL ollama_collection_create('journalctl.httpd.2026-04-28.ERROR');
--
-- CALL embed_insert('github.my-repo', 'Fix null pointer in auth middleware');
-- CALL embed_insert('github.my-repo', 'Add retry logic to webhook handler');
--
-- CALL embed_search('github.my-repo', 'crash on login', 5);
--
-- SELECT * FROM v_collections;

-- =============================================================================
-- Uninstall
--   Physical collection tables (coll_*) are not dropped automatically.
--   Identify and drop them first:
--     SELECT CONCAT('DROP TABLE `', table_name, '`;') FROM ollama_collections;
-- =============================================================================
-- DROP PROCEDURE IF EXISTS embed_search;
-- DROP PROCEDURE IF EXISTS embed_insert;
-- DROP PROCEDURE IF EXISTS ollama_collection_drop;
-- DROP PROCEDURE IF EXISTS ollama_collection_create;
-- DROP PROCEDURE IF EXISTS ollama_profile_use;
-- DROP PROCEDURE IF EXISTS ollama_profile_create;
-- DROP FUNCTION  IF EXISTS embed;
-- DROP VIEW      IF EXISTS v_collections;
-- DROP TABLE     IF EXISTS ollama_collections;   -- cascades profile FK rows
-- DROP TABLE     IF EXISTS ollama_profiles;
-- DROP FUNCTION  IF EXISTS ollama_embed;
