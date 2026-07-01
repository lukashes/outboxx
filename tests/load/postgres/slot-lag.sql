SELECT
    slot_name,
    plugin,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS unflushed_wal
FROM pg_replication_slots
WHERE slot_name IN ('dbz_benchmark_slot', 'outboxx_benchmark_slot')
ORDER BY slot_name;
