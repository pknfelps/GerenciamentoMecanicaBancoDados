-- Run after Init.sql, connected as mecanica_admin to the mecanica database.
-- AUTH_DB_PASSWORD is supplied to psql by the Job; never put it in this file.
\getenv auth_password AUTH_DB_PASSWORD
SELECT 1 / (length(:'auth_password') >= 32)::integer;

SELECT 'CREATE ROLE mecanica_auth NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mecanica_auth')
\gexec

-- RDS administrators cannot reset SUPERUSER/REPLICATION/BYPASSRLS attributes.
-- Refuse an existing privileged role rather than reuse it for authentication.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'mecanica_auth'
          AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
    ) OR EXISTS (
        SELECT 1 FROM pg_auth_members m
        JOIN pg_roles r ON r.oid = m.member
        WHERE r.rolname = 'mecanica_auth'
    ) THEN
        RAISE EXCEPTION 'Existing authentication role has administrative privileges';
    END IF;
END $$;

SELECT format(
    'ALTER ROLE mecanica_auth WITH LOGIN NOINHERIT PASSWORD %L',
    :'auth_password'
)
\gexec

SELECT format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM mecanica_auth', current_database())
\gexec
REVOKE ALL PRIVILEGES ON SCHEMA public FROM mecanica_auth;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM mecanica_auth;

SELECT format('GRANT CONNECT ON DATABASE %I TO mecanica_auth', current_database())
\gexec
GRANT USAGE ON SCHEMA public TO mecanica_auth;
GRANT SELECT (id, name, document, status) ON TABLE customers TO mecanica_auth;

-- No writes, phone/email, internal user passwords or initialization marker.
