-- Steady load scenario: 30,000 events/sec for 120 seconds
-- Total: 3,600,000 events (50% of max capacity ~60k evt/s)
-- Batch size: 1,000 events per transaction (realistic for production)
-- Commits: 30 transactions per second

\echo 'Starting steady load: 30,000 events/sec for 120 seconds...'
\echo 'Transaction size: 1,000 events (30 transactions/sec)'
\timing on

CREATE OR REPLACE PROCEDURE load_steady_load(
    batch_size INT DEFAULT 1000,
    batches_per_sec INT DEFAULT 30,
    duration_sec INT DEFAULT 120
)
LANGUAGE plpgsql
AS $$
DECLARE
    total_batches INT;
    batch INT;
    sleep_ms NUMERIC;
BEGIN
    total_batches := batches_per_sec * duration_sec;
    sleep_ms := 1.0 / batches_per_sec;

    RAISE NOTICE 'Configuration: % batches × % events = % total events',
        total_batches, batch_size, total_batches * batch_size;
    RAISE NOTICE 'Sleep between batches: % seconds', sleep_ms;

    FOR batch IN 1..total_batches LOOP
        INSERT INTO load_events (event_type, event_timestamp, user_id)
        SELECT
            (ARRAY['click', 'view', 'purchase', 'login', 'logout'])[floor(random() * 5 + 1)],
            clock_timestamp(),
            floor(random() * 10000)::int
        FROM generate_series(1, batch_size);

        COMMIT;
        PERFORM pg_sleep(sleep_ms);

        IF batch % 100 = 0 THEN
            RAISE NOTICE 'Batch % completed (% events total)', batch, batch * batch_size;
        END IF;
    END LOOP;

    RAISE NOTICE 'Steady load completed: % events inserted', total_batches * batch_size;
END $$;

CALL load_steady_load(1000, 30, 120);

\timing off
\echo 'Steady load finished: 3,600,000 events in 3,600 transactions (1k events each).'
