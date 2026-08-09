-- Pre-seed benchmark_records for the initial-snapshot scenario. Row shape mirrors
-- the workload generator's insert_batch, so a seeded row weighs the same as a
-- streamed one.
--
--   psql -v rows=10000000 -v row_bytes=128 -f /sql/seed.sql

\set ON_ERROR_STOP on

-- Ids start at 1 again, which is what check-gaps.sh compares the topic against.
TRUNCATE TABLE public.benchmark_records RESTART IDENTITY;

WITH payload AS (
    SELECT repeat('x', greatest(:row_bytes - 160, 0)) AS padding
)
INSERT INTO public.benchmark_records (account_id, numeric_field, status, payload)
SELECT
    (random() * 10000000)::BIGINT,
    (random() * 1000000)::NUMERIC(20, 6),
    (ARRAY['new', 'active', 'paused', 'closed'])[1 + floor(random() * 4)::INT],
    jsonb_build_object(
        'source', 'cdc-benchmark',
        'batch_item', gs,
        'created_at', clock_timestamp(),
        'padding', payload.padding
    )
FROM generate_series(1, :rows) AS gs
CROSS JOIN payload;

SELECT count(*) AS seeded_rows, pg_size_pretty(pg_total_relation_size('public.benchmark_records')) AS table_size
FROM public.benchmark_records;
