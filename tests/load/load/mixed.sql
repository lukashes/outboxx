-- Mixed operations scenario: INSERT, UPDATE, DELETE
-- 60% INSERT, 30% UPDATE, 10% DELETE
-- Total: 10,000 operations

\echo 'Starting mixed load: 60% INSERT, 30% UPDATE, 10% DELETE...'
\timing on

DO $$
DECLARE
    num_inserts INT := 6000;
    num_updates INT := 3000;
    num_deletes INT := 1000;
    min_id INT;
    max_id INT;
BEGIN
    -- Phase 1: INSERT (60%)
    RAISE NOTICE 'Phase 1: Inserting % events...', num_inserts;
    INSERT INTO load_events (event_type, event_timestamp, user_id)
    SELECT
        (ARRAY['click', 'view', 'purchase'])[floor(random() * 3 + 1)],
        NOW(),
        floor(random() * 10000)::int
    FROM generate_series(1, num_inserts);

    -- Get ID range for updates and deletes
    SELECT MIN(id), MAX(id) INTO min_id, max_id FROM load_events;
    RAISE NOTICE 'ID range: % to %', min_id, max_id;

    -- Phase 2: UPDATE (30%)
    RAISE NOTICE 'Phase 2: Updating % events...', num_updates;
    UPDATE load_events
    SET
        event_type = 'updated',
        event_timestamp = NOW()
    WHERE id IN (
        SELECT id FROM load_events
        WHERE id BETWEEN min_id AND max_id
        ORDER BY random()
        LIMIT num_updates
    );

    -- Phase 3: DELETE (10%)
    RAISE NOTICE 'Phase 3: Deleting % events...', num_deletes;
    DELETE FROM load_events
    WHERE id IN (
        SELECT id FROM load_events
        WHERE id BETWEEN min_id AND max_id
        ORDER BY random()
        LIMIT num_deletes
    );

    RAISE NOTICE 'Mixed load completed: % inserts, % updates, % deletes',
        num_inserts, num_updates, num_deletes;
END $$;

\timing off
\echo 'Mixed load finished.'
