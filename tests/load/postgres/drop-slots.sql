-- Clear the pgoutput slots so the next reader bootstraps from scratch: it creates
-- its own slot and gets an exported snapshot, which is what makes an initial
-- snapshot run at all. Leaving a slot in place would also retain WAL, and the
-- reader would drain that backlog on top of the snapshot, mixing the two numbers.
--
-- The streaming publications from init.sql are deliberately kept: pgoutput
-- resolves the publication by name per change, so outboxx_benchmark_publication
-- must already exist when outboxx creates its slot.

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

-- Outboxx's in-progress-snapshot marker, named after the slot. An interrupted run
-- leaves it behind; without the slot it guards, it is just stale state.
DROP PUBLICATION IF EXISTS outboxx_benchmark_slot_snapshotting;

SELECT slot_name, plugin, active
FROM pg_replication_slots
ORDER BY slot_name;
