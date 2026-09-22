-- Run after sql/Init.sql on a disposable PostgreSQL database.
-- All writes below are rolled back; ON_ERROR_STOP must be enabled by psql.
BEGIN;

DO $test$
DECLARE
    seed_vehicle vehicles%ROWTYPE;
    seed_material stock%ROWTYPE;
    seed_service catalog%ROWTYPE;
    test_order_id UUID := '11111111-1111-4111-8111-111111111111';
    orphan_order_id UUID := '22222222-2222-4222-8222-222222222222';
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM users
        WHERE name = 'Admin' AND role = 'Admin'
          AND password LIKE 'pbkdf2-sha256$%'
    ) THEN
        RAISE EXCEPTION 'Missing administrator seed with hashed password';
    END IF;

    SELECT v.* INTO STRICT seed_vehicle
    FROM vehicles v JOIN customers c ON c.document = v.customer_document
    WHERE v.license_plate = 'CVC2025';
    SELECT * INTO STRICT seed_material FROM stock
    WHERE id = 'b03ae302-a3dc-40ba-a7ce-2430a7f0ee5d';
    SELECT * INTO STRICT seed_service FROM catalog
    WHERE id = '8dcc551f-5c3a-4746-8f51-a18be6107a2f';

    IF seed_material.amount - seed_material.reserved_amount < 1 THEN
        RAISE EXCEPTION 'Seed must have available material for a demonstration order';
    END IF;

    INSERT INTO orders (
        id, customer_document, vehicle_license_plate, budget, status,
        date_created, date_finished, duration
    ) VALUES (
        test_order_id, seed_vehicle.customer_document, seed_vehicle.license_plate,
        seed_material.price + seed_service.hours * seed_service.price_per_hour,
        'Received', NOW(), NOW(), INTERVAL '0 seconds'
    );

    INSERT INTO order_materials (id, order_id, name, brand, price, amount)
    VALUES (seed_material.id, test_order_id, seed_material.name,
            seed_material.brand, seed_material.price, 1);
    INSERT INTO order_services (id, order_id, description, hours, price_per_hour, amount)
    VALUES (seed_service.id, test_order_id, seed_service.description,
            seed_service.hours, seed_service.price_per_hour, 1);

    IF NOT EXISTS (
        SELECT 1 FROM orders o
        JOIN order_materials m ON m.order_id = o.id
        JOIN order_services s ON s.order_id = o.id
        WHERE o.id = test_order_id AND m.id = seed_material.id AND s.id = seed_service.id
    ) THEN
        RAISE EXCEPTION 'Order items were not persisted with their relationships';
    END IF;

    BEGIN
        INSERT INTO order_materials (id, order_id, name, brand, price, amount)
        VALUES (seed_material.id, orphan_order_id, 'Orphan', 'Test', 1, 1);
        RAISE EXCEPTION 'Orphan order material was incorrectly accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        NULL; -- Expected: an item cannot refer to a nonexistent order.
    END;

    BEGIN
        INSERT INTO customers (id, name, document, phone, email)
        VALUES (orphan_order_id, 'Duplicate', seed_vehicle.customer_document,
                '00000000000', 'duplicate@example.invalid');
        RAISE EXCEPTION 'Duplicate customer document was incorrectly accepted';
    EXCEPTION WHEN unique_violation THEN
        NULL; -- Expected: document identifies one customer.
    END;
END
$test$;

ROLLBACK;
