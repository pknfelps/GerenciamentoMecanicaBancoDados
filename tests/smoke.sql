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
    rejected_order_id UUID := '33333333-3333-4333-8333-333333333333';
    history_count INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM users
        WHERE name = 'Admin' AND role = 'Admin'
          AND password LIKE 'pbkdf2-sha256$%'
    ) THEN
        RAISE EXCEPTION 'Missing administrator seed with hashed password';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM users WHERE name = 'Mechanic' AND role = 'Mechanic'
                   AND password LIKE 'pbkdf2-sha256$100000$%') THEN
        RAISE EXCEPTION 'Missing mechanic seed with hashed password';
    END IF;
    IF EXISTS (SELECT 1 FROM customers WHERE status <> 'Active') THEN
        RAISE EXCEPTION 'All demonstration customers must start Active';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
               AND table_name = 'orders' AND column_name IN ('date_created', 'date_finished', 'duration')) THEN
        RAISE EXCEPTION 'Order dates and duration must be derived from history';
    END IF;
    IF EXISTS (SELECT 1 FROM orders) OR EXISTS (SELECT 1 FROM order_status_history) THEN
        RAISE EXCEPTION 'Init must not seed demonstration orders or history';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'public' AND table_name = 'schema_initialization') THEN
        RAISE EXCEPTION 'Schema initialization marker table is missing';
    END IF;
    INSERT INTO customers (id, name, document, phone, email)
    VALUES (orphan_order_id, 'Status fixture', 'TEST-STATUS', '00000000000', 'status@example.invalid');
    IF (SELECT status FROM customers WHERE id = orphan_order_id) <> 'Active' THEN
        RAISE EXCEPTION 'New customers must default to Active';
    END IF;
    UPDATE customers SET status = 'Inactive' WHERE id = orphan_order_id;

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
        id, customer_document, vehicle_license_plate, budget, status
    ) VALUES (
        test_order_id, seed_vehicle.customer_document, seed_vehicle.license_plate,
        seed_material.price + seed_service.hours * seed_service.price_per_hour,
        'Received'
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
        VALUES (rejected_order_id, 'Duplicate', seed_vehicle.customer_document,
                '00000000000', 'duplicate@example.invalid');
        RAISE EXCEPTION 'Duplicate customer document was incorrectly accepted';
    EXCEPTION WHEN unique_violation THEN
        NULL; -- Expected: document identifies one customer.
    END;

    INSERT INTO order_status_history (id, order_id, sequence, previous_status, new_status, occurred_at, reason)
    SELECT gen_random_uuid(), test_order_id, n, previous_status, new_status,
           TIMESTAMPTZ '2026-10-06 12:00:00+00' + minutes * INTERVAL '1 minute', reason
    FROM (VALUES
        (1, NULL, 'Received', 0, NULL),
        (2, 'Received', 'InDiagnosis', 0, NULL),
        (3, 'InDiagnosis', 'WaitingForApproval', 10, NULL),
        (4, 'WaitingForApproval', 'WaitingForExecution', 20, NULL),
        (5, 'WaitingForExecution', 'InExecution', 30, NULL),
        (6, 'InExecution', 'Finished', 60, 'ServiceCompleted'),
        (7, 'Finished', 'Delivered', 90, NULL)
    ) AS events(n, previous_status, new_status, minutes, reason);
    UPDATE orders SET status = 'Delivered' WHERE id = test_order_id;

    -- Equal instants are resolved by sequence; UTC and offset inputs denote the same instant.
    IF (SELECT array_agg(sequence ORDER BY occurred_at, sequence) FROM order_status_history
        WHERE order_id = test_order_id) <> ARRAY[1,2,3,4,5,6,7] THEN
        RAISE EXCEPTION 'History order is not deterministic';
    END IF;
    IF (SELECT occurred_at FROM order_status_history WHERE order_id = test_order_id AND sequence = 1)
        <> TIMESTAMPTZ '2026-10-06 09:00:00-03' THEN
        RAISE EXCEPTION 'History must preserve the UTC instant';
    END IF;
    IF (SELECT EXTRACT(EPOCH FROM (finished.occurred_at - created.occurred_at))
        FROM order_status_history created JOIN order_status_history finished USING (order_id)
        WHERE created.order_id = test_order_id AND created.sequence = 1
          AND finished.new_status = 'Finished' AND finished.reason = 'ServiceCompleted') <> 3600 THEN
        RAISE EXCEPTION 'Total service time must be derived from completion, excluding delivery';
    END IF;

    INSERT INTO orders (id, customer_document, vehicle_license_plate, budget, status)
    VALUES (rejected_order_id, seed_vehicle.customer_document, seed_vehicle.license_plate, 0, 'Received');
    INSERT INTO order_status_history (id, order_id, sequence, previous_status, new_status, occurred_at, reason)
    SELECT gen_random_uuid(), rejected_order_id, n, previous_status, new_status,
           TIMESTAMPTZ '2026-10-06 12:00:00+00' + n * INTERVAL '1 minute', reason
    FROM (VALUES
        (1, NULL, 'Received', NULL),
        (2, 'Received', 'InDiagnosis', NULL),
        (3, 'InDiagnosis', 'WaitingForApproval', NULL),
        (4, 'WaitingForApproval', 'Finished', 'BudgetRejected'),
        (5, 'Finished', 'Delivered', NULL)
    ) AS events(n, previous_status, new_status, reason);
    UPDATE orders SET status = 'Delivered' WHERE id = rejected_order_id;
    IF (SELECT count(*) FROM order_status_history WHERE new_status = 'Finished'
        AND reason = 'ServiceCompleted') <> 1 THEN
        RAISE EXCEPTION 'Rejected budgets must not count as completed services';
    END IF;

    SELECT count(*) INTO history_count FROM order_status_history;
    DELETE FROM order_materials WHERE order_id = test_order_id;
    DELETE FROM order_services WHERE order_id = test_order_id;
    DELETE FROM orders WHERE id IN (test_order_id, rejected_order_id);
    IF (SELECT count(*) FROM order_status_history) <> history_count OR history_count <> 12 THEN
        RAISE EXCEPTION 'Deleting orders must retain their history and correlation IDs';
    END IF;
END
$test$;

ROLLBACK;
