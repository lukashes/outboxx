-- Steady load scenario: 1000 events/sec for 60 seconds
-- Total: 60,000 events
-- Uses PROCEDURE to COMMIT each batch separately (realistic CDC)

\echo 'Starting steady load: 1000 events/sec for 60 seconds...'
\echo 'Each batch committed separately for realistic CDC behavior'
\timing on

-- Create procedure if not exists
CREATE OR REPLACE PROCEDURE load_steady_load(
    batch_size INT DEFAULT 1000,
    num_batches INT DEFAULT 60,
    sleep_seconds NUMERIC DEFAULT 1.0
)
LANGUAGE plpgsql
AS $$
DECLARE
    batch INT;
BEGIN
    FOR batch IN 1..num_batches LOOP
        -- Insert events with current timestamp for lag measurement
        INSERT INTO load_events (event_type, event_timestamp, user_id)
        SELECT
            (ARRAY['click', 'view', 'purchase', 'login', 'logout'])[floor(random() * 5 + 1)],
            NOW(),
            floor(random() * 10000)::int
        FROM generate_series(1, batch_size);

        -- COMMIT this batch immediately (only works in PROCEDURE!)
        COMMIT;

        -- Sleep between batches
        PERFORM pg_sleep(sleep_seconds);

        IF batch % 10 = 0 THEN
            RAISE NOTICE 'Batch % completed (% events total)', batch, batch * batch_size;
        END IF;
    END LOOP;

    RAISE NOTICE 'Steady load completed: % events inserted', num_batches * batch_size;
END $$;

-- Call the procedure
CALL load_steady_load(1000, 60, 1.0);

\timing off
\echo 'Steady load finished.'
