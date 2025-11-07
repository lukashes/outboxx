-- Burst load scenario: 10,000,000 events as fast as possible
-- Tests maximum throughput and lag recovery
-- At 60k evt/s baseline, this represents ~167 seconds of sustained load

\echo 'Starting burst load: 10,000,000 events...'
\echo 'Testing peak throughput and lag recovery capabilities'
\timing on

INSERT INTO load_events (event_type, event_timestamp, user_id)
SELECT
    (ARRAY['click', 'view', 'purchase', 'login', 'logout'])[floor(random() * 5 + 1)],
    clock_timestamp(),
    floor(random() * 10000000)::int
FROM generate_series(1, 10000000);

\timing off
\echo 'Burst load finished: 10,000,000 events inserted.'
\echo 'Check Grafana for lag recovery time and peak throughput.'
