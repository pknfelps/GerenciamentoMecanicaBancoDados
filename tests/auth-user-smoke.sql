-- Run with PGUSER=mecanica_auth after ProvisionAuthUser.sql.
DO $$
DECLARE
    column_name text;
    table_name text;
    qualified_name text;
BEGIN
    IF current_user <> 'mecanica_auth' THEN
        RAISE EXCEPTION 'Expected authentication database role';
    END IF;

    FOREACH column_name IN ARRAY ARRAY['id', 'name', 'document', 'status'] LOOP
        IF NOT has_column_privilege(current_user, 'public.customers', column_name, 'SELECT') OR
           has_column_privilege(current_user, 'public.customers', column_name, 'SELECT WITH GRANT OPTION')
        THEN
            RAISE EXCEPTION 'Unexpected authentication privilege on customers.%', column_name;
        END IF;
    END LOOP;

    IF has_column_privilege(current_user, 'public.customers', 'phone', 'SELECT') OR
       has_column_privilege(current_user, 'public.customers', 'email', 'SELECT') OR
       has_schema_privilege(current_user, 'public', 'CREATE') OR
       has_database_privilege(current_user, current_database(), 'CREATE') OR
       EXISTS (SELECT 1 FROM pg_auth_members WHERE member =
           (SELECT oid FROM pg_roles WHERE rolname = current_user)) OR
       (SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
          FROM pg_roles WHERE rolname = current_user)
    THEN
        RAISE EXCEPTION 'Authentication role has excessive privileges';
    END IF;

    FOREACH table_name IN ARRAY ARRAY[
        'users', 'customers', 'vehicles', 'orders', 'order_status_history',
        'stock', 'catalog', 'order_materials', 'order_services', 'schema_initialization'
    ] LOOP
        qualified_name := format('public.%I', table_name);
        IF has_table_privilege(current_user, qualified_name,
               'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') OR
           has_any_column_privilege(current_user, qualified_name, 'INSERT, UPDATE, REFERENCES') OR
           (table_name <> 'customers' AND
               has_any_column_privilege(current_user, qualified_name, 'SELECT'))
        THEN
            RAISE EXCEPTION 'Authentication role has excessive access to %', qualified_name;
        END IF;
    END LOOP;

    -- Exercise the intended query without printing customer data.
    PERFORM id, name, status FROM public.customers WHERE document = '662.119.730-63';

    BEGIN
        PERFORM phone, email FROM public.customers;
        RAISE EXCEPTION 'Authentication role unexpectedly read phone/email';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM password FROM public.users;
        RAISE EXCEPTION 'Authentication role unexpectedly read internal users';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        UPDATE public.customers SET status = 'Inactive' WHERE false;
        RAISE EXCEPTION 'Authentication role unexpectedly updated customers';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        CREATE TABLE public.auth_ddl_probe (id integer);
        RAISE EXCEPTION 'Authentication role unexpectedly created a table';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END $$;

SELECT count(id) FROM customers
WHERE document IS NOT NULL AND name IS NOT NULL AND status IN ('Active', 'Inactive');
