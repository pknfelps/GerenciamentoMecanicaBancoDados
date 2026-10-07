-- Read-only evidence for the release; no credentials or customer data.
-- psql -q -X -A -t -v ON_ERROR_STOP=1 -f /sql/ReadInitialization.sql
SELECT COALESCE(json_agg(json_build_object(
    'version', version,
    'sha256', sha256,
    'initialized_at', to_char(initialized_at AT TIME ZONE 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
)), '[]'::json)
FROM public.schema_initialization;
