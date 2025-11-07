-- Ramp load scenario: Gradually increasing load 10k -> 200k evt/s
-- Each step runs for 30 seconds
-- Transaction size: 1,000 events (realistic for production)
-- Transactions/sec increases from 10 to 200

\echo 'Starting RAMP load: 10k -> 200k events/sec...'
\echo 'Each step runs for 30 seconds with 1k events per transaction'
\timing on

CREATE OR REPLACE PROCEDURE load_ramp_load()
LANGUAGE plpgsql
AS $$
DECLARE
    load_steps INT[] := ARRAY[10000, 20000, 40000, 60000, 80000, 100000, 120000, 140000, 160000, 180000, 200000];
    step_duration INT := 30;
    batch_size INT := 1000;
    current_step INT;
    events_per_sec INT;
    batches_per_sec INT;
    batch INT;
    total_batches INT;
    sleep_ms NUMERIC;
    total_events INT := 0;
BEGIN
    FOREACH events_per_sec IN ARRAY load_steps LOOP
        current_step := array_position(load_steps, events_per_sec);
        batches_per_sec := events_per_sec / batch_size;
        total_batches := batches_per_sec * step_duration;
        sleep_ms := 1.0 / batches_per_sec;

        RAISE NOTICE '=== Step %: % events/sec (% transactions/sec) for % seconds ===',
            current_step, events_per_sec, batches_per_sec, step_duration;

        FOR batch IN 1..total_batches LOOP
            INSERT INTO load_events (event_type, event_timestamp, user_id)
            SELECT
                (ARRAY['click', 'view', 'purchase', 'login', 'logout'])[floor(random() * 5 + 1)],
                clock_timestamp(),
                floor(random() * 10000)::int
            FROM generate_series(1, batch_size);

            total_events := total_events + batch_size;
            COMMIT;
            PERFORM pg_sleep(sleep_ms);

            IF batch % 50 = 0 THEN
                RAISE NOTICE 'Step % progress: %/% batches (% total events)',
                    current_step, batch, total_batches, total_events;
            END IF;
        END LOOP;

        RAISE NOTICE 'Step % completed: % events/sec for % seconds',
            current_step, events_per_sec, step_duration;
    END LOOP;

    RAISE NOTICE '=== Ramp load completed: % total events ===', total_events;
    RAISE NOTICE 'Load steps: 10k -> 20k -> 40k -> 60k -> 80k -> 100k -> 120k -> 140k -> 160k -> 180k -> 200k evt/s';
END $$;

CALL load_ramp_load();

\timing off
\echo 'Ramp load finished. Check Grafana to find where lag started growing.'
\echo 'Expected baseline: ~60k evt/s should have minimal lag.'
