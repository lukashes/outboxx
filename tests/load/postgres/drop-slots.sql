-- Clear the pgoutput slots so the next reader creates its own and gets an exported
-- snapshot, which is what makes an initial snapshot run. A leftover slot would also
-- retain WAL, and the reader would drain that backlog on top of the snapshot.
--
-- The streaming publications from init.sql stay: pgoutput resolves a publication by
-- name per change, so it must exist before the slot.

SELECT pg_drop_replication_slot('dbz_benchmark_slot')
WHERE EXISTS (
    SELECT 1
    FROM pg_replication_slots
    WHERE slot_name = 'dbz_benchmark_slot'
);

SELECT pg_drop_replication_slot('outboxx_benchmark_slot')
WHERE EXISTS (
    SELECT 1
    FROM pg_replication_slots
    WHERE slot_name = 'outboxx_benchmark_slot'
);

-- Outboxx's in-progress-snapshot marker, left behind by an interrupted run.
DROP PUBLICATION IF EXISTS outboxx_benchmark_slot_snapshotting;

SELECT slot_name, plugin, active
FROM pg_replication_slots
ORDER BY slot_name;
