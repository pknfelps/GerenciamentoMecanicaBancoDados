-- Run after InitIdentity.sql, connected as mecanica_admin to mecanica_identity.
-- The Job supplies operational_database and feeds the password to psql over stdin.

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

ALTER ROLE mecanica_auth WITH LOGIN NOINHERIT;
SET LOCAL password_encryption = 'scram-sha-256';
\password mecanica_auth

SELECT format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM mecanica_auth', current_database())
\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', current_database())
\gexec
REVOKE ALL PRIVILEGES ON DATABASE :"operational_database" FROM mecanica_auth;
REVOKE ALL PRIVILEGES ON SCHEMA public FROM mecanica_auth;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM mecanica_auth;

SELECT format('GRANT CONNECT ON DATABASE %I TO mecanica_auth', current_database())
\gexec
GRANT USAGE ON SCHEMA public TO mecanica_auth;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
    users, customer_access, customer_auth_challenges, customer_auth_request_limits
TO mecanica_auth;

-- No grants on the operational database, initialization marker or DDL.
