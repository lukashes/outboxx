-- Ramp load scenario: Gradually increasing load
-- Starts at 100 events/sec, increases to 5000 events/sec
-- Helps identify the breaking point where lag starts growing

\echo 'Starting RAMP load: 100 -> 5000 events/sec...'
\echo 'Each step runs for 30 seconds with separate commits'
\timing on

-- Create ramp load procedure
CREATE OR REPLACE PROCEDURE load_ramp_load()
LANGUAGE plpgsql
AS $$
DECLARE
    -- Load steps: events per second
    load_steps INT[] := ARRAY[100, 200, 500, 1000, 2000, 3000, 5000, 6000, 7000, 8000, 9000, 10000];
    step_duration INT := 30; -- seconds per step
    current_step INT;
    events_per_sec INT;
    batch INT;
    total_events INT := 0;
BEGIN
    FOREACH events_per_sec IN ARRAY load_steps LOOP
        current_step := array_position(load_steps, events_per_sec);
        RAISE NOTICE '=== Step %: % events/sec for % seconds ===',
            current_step, events_per_sec, step_duration;

        -- Run this load level for step_duration seconds
        FOR batch IN 1..step_duration LOOP
            -- Insert events_per_sec events with timestamp
            INSERT INTO load_events (event_type, event_timestamp, user_id)
            SELECT
                (ARRAY['click', 'view', 'purchase', 'login', 'logout'])[floor(random() * 5 + 1)],
                NOW(),
                floor(random() * 10000)::int
            FROM generate_series(1, events_per_sec);

            total_events := total_events + events_per_sec;

            -- Commit each batch immediately
            COMMIT;

            -- Sleep 1 second between batches
            PERFORM pg_sleep(1);

            IF batch % 10 = 0 THEN
                RAISE NOTICE 'Step % progress: %/% seconds (% total events)',
                    current_step, batch, step_duration, total_events;
            END IF;
        END LOOP;

        RAISE NOTICE 'Step % completed: % events/sec for % seconds',
            current_step, events_per_sec, step_duration;
    END LOOP;

    RAISE NOTICE '=== Ramp load completed: % total events ===', total_events;
    RAISE NOTICE 'Load steps: 100 -> 200 -> 500 -> 1000 -> 2000 -> 3000 -> 5000 evt/s';
END $$;

-- Call the procedure
CALL load_ramp_load();

\timing off
\echo 'Ramp load finished. Check Grafana to find where lag started growing.'
