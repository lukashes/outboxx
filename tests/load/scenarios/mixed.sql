-- Mixed operations scenario: INSERT, UPDATE, DELETE shuffled together
-- 60% INSERT, 30% UPDATE, 10% DELETE
-- Total: 1,000,000 operations in 1,000 batches of 1,000 ops each
-- Operations are shuffled within each batch for realistic workload

\echo 'Starting mixed load: 1,000,000 operations with shuffled INSERT/UPDATE/DELETE...'
\echo 'Distribution: 60% INSERT, 30% UPDATE, 10% DELETE'
\echo 'Batch size: 1,000 operations per commit (realistic for production)'
\timing on

CREATE OR REPLACE PROCEDURE load_mixed_operations()
LANGUAGE plpgsql
AS $$
DECLARE
    num_batches INT := 1000;
    batch_size INT := 1000;
    batch INT;
    op_type VARCHAR(10);
    rand FLOAT;
    insert_count INT := 0;
    update_count INT := 0;
    delete_count INT := 0;
    target_inserts INT := 600000;
    target_updates INT := 300000;
    target_deletes INT := 100000;
    total_ops INT := 0;
    min_id INT;
    max_id INT;
    random_id INT;
BEGIN
    -- Initial seed data for UPDATE/DELETE operations
    RAISE NOTICE 'Creating initial seed data (100k records)...';
    INSERT INTO load_events (event_type, event_timestamp, user_id)
    SELECT
        (ARRAY['click', 'view', 'purchase'])[floor(random() * 3 + 1)],
        clock_timestamp(),
        floor(random() * 10000)::int
    FROM generate_series(1, 100000);
    COMMIT;

    RAISE NOTICE 'Starting shuffled operations (% batches × % ops)...', num_batches, batch_size;

    -- 1000 batches of 1000 operations each
    FOR batch IN 1..num_batches LOOP
        -- Execute 1000 shuffled operations in this batch
        FOR i IN 1..batch_size LOOP
            -- Randomly choose operation type based on remaining quotas
            rand := random();

            -- Adjust probabilities based on remaining operations
            IF insert_count < target_inserts AND
               (rand < 0.6 OR (update_count >= target_updates AND delete_count >= target_deletes)) THEN
                -- INSERT
                INSERT INTO load_events (event_type, event_timestamp, user_id)
                VALUES (
                    (ARRAY['click', 'view', 'purchase', 'login', 'logout'])[floor(random() * 5 + 1)],
                    clock_timestamp(),
                    floor(random() * 100000)::int
                );
                insert_count := insert_count + 1;

            ELSIF update_count < target_updates AND
                  (rand < 0.9 OR delete_count >= target_deletes) THEN
                -- UPDATE random existing record
                SELECT MIN(id), MAX(id) INTO min_id, max_id FROM load_events;
                IF max_id IS NOT NULL AND max_id > min_id THEN
                    random_id := min_id + floor(random() * (max_id - min_id + 1));
                    UPDATE load_events
                    SET
                        event_type = 'updated',
                        event_timestamp = clock_timestamp()
                    WHERE id = (
                        SELECT id FROM load_events
                        WHERE id >= random_id
                        LIMIT 1
                    );
                    update_count := update_count + 1;
                END IF;

            ELSIF delete_count < target_deletes THEN
                -- DELETE random existing record
                SELECT MIN(id), MAX(id) INTO min_id, max_id FROM load_events;
                IF max_id IS NOT NULL AND max_id > min_id THEN
                    random_id := min_id + floor(random() * (max_id - min_id + 1));
                    DELETE FROM load_events
                    WHERE id = (
                        SELECT id FROM load_events
                        WHERE id >= random_id
                        LIMIT 1
                    );
                    delete_count := delete_count + 1;
                END IF;
            END IF;

            total_ops := total_ops + 1;
        END LOOP;

        -- Commit each batch
        COMMIT;

        IF batch % 100 = 0 THEN
            RAISE NOTICE 'Batch % completed: % INS, % UPD, % DEL (% total)',
                batch, insert_count, update_count, delete_count, total_ops;
        END IF;
    END LOOP;

    RAISE NOTICE '=== Mixed load completed ===';
    RAISE NOTICE 'Total operations: %', total_ops;
    RAISE NOTICE 'INSERT: % (%.1f%%)', insert_count, (insert_count::float / total_ops * 100);
    RAISE NOTICE 'UPDATE: % (%.1f%%)', update_count, (update_count::float / total_ops * 100);
    RAISE NOTICE 'DELETE: % (%.1f%%)', delete_count, (delete_count::float / total_ops * 100);
END $$;

CALL load_mixed_operations();

\timing off
\echo 'Mixed load finished: 1,000,000 operations in 1,000 transactions (1k ops each).'
