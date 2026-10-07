-- Run with PGUSER=mecanica_api after ProvisionApiUser.sql.
DO $$
DECLARE
    table_name text;
    qualified_name text;
BEGIN
    IF current_user <> 'mecanica_api' THEN
        RAISE EXCEPTION 'Expected API database role';
    END IF;

    FOREACH table_name IN ARRAY ARRAY[
        'users', 'customers', 'vehicles', 'orders', 'order_status_history',
        'stock', 'catalog', 'order_materials', 'order_services'
    ] LOOP
        qualified_name := format('public.%I', table_name);
        IF NOT (
            has_table_privilege(current_user, qualified_name, 'SELECT') AND
            has_table_privilege(current_user, qualified_name, 'INSERT') AND
            has_table_privilege(current_user, qualified_name, 'UPDATE') AND
            has_table_privilege(current_user, qualified_name, 'DELETE')
        ) THEN
            RAISE EXCEPTION 'Missing API privilege on %', qualified_name;
        END IF;
    END LOOP;

    IF has_table_privilege(current_user, 'public.schema_initialization', 'SELECT') OR
       has_table_privilege(current_user, 'public.schema_initialization', 'INSERT') OR
       has_schema_privilege(current_user, 'public', 'CREATE') OR
       has_database_privilege(current_user, current_database(), 'CREATE') OR
       EXISTS (SELECT 1 FROM pg_auth_members WHERE member =
           (SELECT oid FROM pg_roles WHERE rolname = current_user)) OR
       (SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
          FROM pg_roles WHERE rolname = current_user)
    THEN
        RAISE EXCEPTION 'API role has an administrative privilege';
    END IF;
END $$;

SELECT count(*) FROM users;
SELECT count(*) FROM customers;
