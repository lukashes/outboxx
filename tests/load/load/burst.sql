-- Burst load scenario: 10,000,000 events as fast as possible
-- Tests maximum throughput and lag handling

\echo 'Starting burst load: 10,000,000 events...'
\timing on

INSERT INTO load_events (event_type, event_timestamp, user_id)
SELECT
    (ARRAY['click', 'view', 'purchase', 'login', 'logout'])[floor(random() * 5 + 1)],
    NOW(),
    floor(random() * 10000000)::int
FROM generate_series(1, 10000000);

\timing off
\echo 'Burst load finished: 10,000,000 events inserted.'
