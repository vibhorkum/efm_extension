-- Test basic extension functionality
-- Assumes extension is created as part of setup

-- Test 1: Verify schema exists
SELECT COUNT(*) AS schema_count 
FROM pg_namespace 
WHERE nspname = 'efm_extension';

-- Test 2: List all functions in the extension
SELECT proname AS function_name
FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'efm_extension'
  AND proname LIKE 'efm_%'
ORDER BY proname;

-- Test 3: List all views in the extension  
SELECT viewname AS view_name
FROM pg_views
WHERE schemaname = 'efm_extension'
ORDER BY viewname;

-- Test 4: Verify GUC parameters are registered
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE 'efm.%'
ORDER BY name;

-- Test 5: Check extension metadata
SELECT extname, extversion, extrelocatable
FROM pg_extension
WHERE extname = 'efm_extension';

-- Test 6: Verify types exist
SELECT typname AS type_name
FROM pg_type t
  JOIN pg_namespace n ON t.typnamespace = n.oid
WHERE n.nspname = 'efm_extension'
ORDER BY typname;
