-- Run while connected to the operational database as the RDS administrator.
-- CREATE DATABASE must run outside a transaction. The session lock serializes
-- the existence check and creation if initialization runs more than once.
SELECT pg_advisory_lock(7401, 2);

SELECT NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = :'identity_database'
) AS create_identity_database
\gset
\if :create_identity_database
    CREATE DATABASE :"identity_database" TEMPLATE template0;
    REVOKE CONNECT ON DATABASE :"identity_database" FROM PUBLIC;
\endif
