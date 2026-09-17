CREATE TABLE users
(
    id       UUID PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    password VARCHAR(100) NOT NULL,
    role     VARCHAR(100) NOT NULL
);

INSERT INTO users(id, name, password, role)
VALUES ('de0ec153-5578-430e-b530-96e4118f1721', 'Admin', 'pbkdf2-sha256$100000$6MmTIW+OTlh8U8Vs3kdKug==$/ry4uV+eOUlJf416B28kH+V29/zePbdfKTdRYjPQXkU=', 'Admin');

CREATE TABLE customers
(
    id       UUID PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    document VARCHAR(100) NOT NULL UNIQUE,
    phone    VARCHAR(100) NOT NULL,
    email    VARCHAR(100) NOT NULL
);

INSERT INTO customers(id, name, document, phone, email)
VALUES ('445b6ba5-523b-426f-9aaa-164754c203ca', 'Fulano', '662.119.730-63', '(11) 91234-5678', 'fulano@gmail.com');

CREATE TABLE vehicles
(
    id                UUID PRIMARY KEY,
    customer_document VARCHAR(100) NOT NULL REFERENCES customers (document),
    brand             VARCHAR(100) NOT NULL,
    model             VARCHAR(100) NOT NULL,
    year              INT          NOT NULL,
    license_plate     VARCHAR(7)   NOT NULL UNIQUE
);

INSERT INTO vehicles(id, customer_document, brand, model, year, license_plate)
VALUES ('60ec3776-ac80-47b4-a3a3-dd21e3e15361', '662.119.730-63', 'Honda', 'Civic', 2025, 'CVC2025');

CREATE TABLE orders
(
    id                    UUID PRIMARY KEY,
    customer_document     VARCHAR(100) NOT NULL REFERENCES customers (document),
    vehicle_license_plate VARCHAR(100) NOT NULL REFERENCES vehicles (license_plate),
    budget                NUMERIC      NOT NULL,
    status                VARCHAR(50)  NOT NULL,
    date_created          TIMESTAMP    NOT NULL DEFAULT NOW(),
    date_finished         TIMESTAMP    NOT NULL,
    duration INTERVAL NOT NULL
);

CREATE TABLE stock
(
    id              UUID PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    brand           VARCHAR(255) NOT NULL,
    price           NUMERIC      NOT NULL,
    amount          INT          NOT NULL,
    reserved_amount INT          NOT NULL DEFAULT 0
);

INSERT INTO stock(id, name, brand, price, amount, reserved_amount)
VALUES ('b03ae302-a3dc-40ba-a7ce-2430a7f0ee5d', 'Óleo de motor', 'Lubrax', 10.99, 10, 0);

CREATE TABLE catalog
(
    id             UUID PRIMARY KEY,
    description    VARCHAR(255) NOT NULL,
    hours          FLOAT        NOT NULL,
    price_per_hour NUMERIC      NOT NULL
);

INSERT INTO catalog(id, description, hours, price_per_hour)
VALUES ('8dcc551f-5c3a-4746-8f51-a18be6107a2f', 'Troca de Óleo', 1, 20);

CREATE TABLE order_materials
(
    id       UUID         NOT NULL REFERENCES stock (id),
    order_id UUID         NOT NULL REFERENCES orders (id),
    name     VARCHAR(255) NOT NULL,
    brand    VARCHAR(255) NOT NULL,
    price    NUMERIC      NOT NULL,
    amount   INT          NOT NULL
);

CREATE TABLE order_services
(
    id             UUID         NOT NULL REFERENCES catalog (id),
    order_id       UUID         NOT NULL REFERENCES orders (id),
    description    VARCHAR(255) NOT NULL,
    hours          FLOAT        NOT NULL,
    price_per_hour NUMERIC      NOT NULL,
    amount         INT          NOT NULL
);
