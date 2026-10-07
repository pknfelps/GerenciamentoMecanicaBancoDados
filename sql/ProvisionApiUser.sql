-- Run after Init.sql, connected as mecanica_admin to the mecanica database.
-- API_DB_PASSWORD is supplied to psql by the Job; never put it in this file.
\getenv api_password API_DB_PASSWORD
SELECT 1 / (length(:'api_password') >= 32)::integer;

SELECT 'CREATE ROLE mecanica_api NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mecanica_api')
\gexec

SELECT format(
    'ALTER ROLE mecanica_api WITH LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
    :'api_password'
)
\gexec

SELECT format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM mecanica_api', current_database())
\gexec
REVOKE ALL PRIVILEGES ON SCHEMA public FROM mecanica_api;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM mecanica_api;

SELECT format('GRANT CONNECT ON DATABASE %I TO mecanica_api', current_database())
\gexec
GRANT USAGE ON SCHEMA public TO mecanica_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
    users, customers, vehicles, orders, order_status_history,
    stock, catalog, order_materials, order_services
TO mecanica_api;

-- schema_initialization belongs to the initialization Job, not the API.
