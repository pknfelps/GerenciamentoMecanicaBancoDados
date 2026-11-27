-- Identity schema 1.0.0: initialize an empty database in one transaction.
-- Internal account seeds retain their original IDs and PBKDF2 hashes.

CREATE TABLE users
(
    id       UUID PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    password VARCHAR(100) NOT NULL,
    role     VARCHAR(100) NOT NULL
);

INSERT INTO users(id, name, password, role)
VALUES ('de0ec153-5578-430e-b530-96e4118f1721', 'Admin', 'pbkdf2-sha256$100000$6MmTIW+OTlh8U8Vs3kdKug==$/ry4uV+eOUlJf416B28kH+V29/zePbdfKTdRYjPQXkU=', 'Admin');

INSERT INTO users(id, name, password, role)
VALUES ('8f7bfb74-e252-40b6-936f-bf25222b48c5', 'Mechanic', 'pbkdf2-sha256$100000$SYrp1IzHCtHauMfGXP2Lyg==$FWdnyfDAtunNqdvynLHNvGVhpZREfrBRcrkdMWkHZwE=', 'Mechanic');

-- The UUID comes from the operational customer. A revoked record keeps
-- only the UUID, the last applied revision and its status.
CREATE TABLE customer_access
(
    customer_id UUID PRIMARY KEY,
    name        VARCHAR(100),
    document    VARCHAR(100) UNIQUE,
    email       VARCHAR(100),
    status      VARCHAR(8) NOT NULL,
    revision    BIGINT     NOT NULL CHECK (revision >= 0),
    CHECK (
        (status = 'Revoked' AND name IS NULL AND document IS NULL AND email IS NULL)
        OR
        (status IN ('Active', 'Inactive') AND name IS NOT NULL AND document IS NOT NULL AND email IS NOT NULL)
    )
);

-- Mirrors the educational customer in Init.sql. Revision zero is the seed.
INSERT INTO customer_access(customer_id, name, document, email, status, revision)
VALUES ('445b6ba5-523b-426f-9aaa-164754c203ca', 'Fulano', '662.119.730-63', 'fulano@gmail.com', 'Active', 0);

-- AE.3: business validation and lifecycle are implemented by AuthFunction in C#.
-- No business CHECKs, conditional uniqueness, FK or automatic deletion.
CREATE TABLE customer_auth_challenges
(
    id              UUID PRIMARY KEY,
    customer_id     UUID NOT NULL,
    code_salt       BYTEA NOT NULL,
    code_verifier   BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at      TIMESTAMPTZ NOT NULL,
    state           VARCHAR(50) NOT NULL DEFAULT 'Pending',
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    consumed_at     TIMESTAMPTZ,
    invalidated_at  TIMESTAMPTZ
);

CREATE INDEX customer_auth_challenges_customer_created
    ON customer_auth_challenges (customer_id, created_at);

CREATE INDEX customer_auth_challenges_expiration
    ON customer_auth_challenges (expires_at, id);

-- Request-code must find the customer before writing a challenge or limit.
CREATE TABLE customer_auth_request_limits
(
    customer_id       UUID PRIMARY KEY,
    window_started_at TIMESTAMPTZ NOT NULL,
    window_expires_at TIMESTAMPTZ NOT NULL,
    request_count     INTEGER NOT NULL,
    last_requested_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX customer_auth_request_limits_expiration
    ON customer_auth_request_limits (window_expires_at, customer_id);

CREATE TABLE schema_initialization
(
    version        VARCHAR(20) NOT NULL,
    sha256         CHAR(64) NOT NULL,
    initialized_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
