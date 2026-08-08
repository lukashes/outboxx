-- Pre-seed benchmark_records for the initial-snapshot scenario: existing rows a
-- reader has to bootstrap, as opposed to the WAL backlog the workload generator
-- produces.
--
-- Deliberately SQL rather than a mode in the workload generator: the insert is
-- already set-based and server-side, so running it through psql in this container
-- keeps the seed free of the generator's python image.
--
--   psql -v rows=2000000 -v row_bytes=128 -f /sql/seed.sql
--
-- Row shape mirrors the generator's insert_batch, padding included, so a seeded
-- row and a streamed one weigh the same.

\set ON_ERROR_STOP on

-- Ids start at 1 again, which is what check-gaps.sh assumes when it compares the
-- topic against the sequence.
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
