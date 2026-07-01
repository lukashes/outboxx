SELECT pg_create_logical_replication_slot('dbz_benchmark_slot', 'pgoutput')
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_replication_slots
    WHERE slot_name = 'dbz_benchmark_slot'
);

SELECT pg_create_logical_replication_slot('outboxx_benchmark_slot', 'pgoutput')
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_replication_slots
    WHERE slot_name = 'outboxx_benchmark_slot'
);

SELECT
    slot_name,
    plugin,
    slot_type,
    active,
    restart_lsn,
    confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name IN ('dbz_benchmark_slot', 'outboxx_benchmark_slot')
ORDER BY slot_name;
