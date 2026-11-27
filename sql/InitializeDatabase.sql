-- The Job supplies schema_file, schema_version and sql_sha256 via psql.
-- Keep the empty/compatible check, schema, seeds and marker in one transaction.
BEGIN;
SET LOCAL search_path = public;

-- Concurrent runs for the same database wait before inspecting its schema.
SELECT pg_advisory_xact_lock(7401, 1);

SELECT to_regclass('public.schema_initialization') IS NOT NULL AS has_marker
\gset
\if :has_marker
    SELECT count(*) = 1
       AND min(version) = :'schema_version'
       AND min(sha256) = :'sql_sha256' AS compatible
    FROM schema_initialization
    \gset
    \if :compatible
        \echo Matching schema already initialized in :DBNAME
    \else
        DO $$ BEGIN
            RAISE EXCEPTION 'Existing schema has a different initialization version or SQL hash';
        END $$;
    \endif
\else
    SELECT NOT EXISTS (
        SELECT 1
        FROM pg_class
        JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_namespace.nspname = 'public'
          AND pg_class.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
    ) AS empty_schema
    \gset
    \if :empty_schema
        \echo Initializing empty schema in :DBNAME
        \ir :schema_file
        INSERT INTO schema_initialization(version, sha256) VALUES (:'schema_version', :'sql_sha256');
    \else
        DO $$ BEGIN
            RAISE EXCEPTION 'Database contains objects without a matching initialization marker';
        END $$;
    \endif
\endif

COMMIT;
