CREATE TABLE IF NOT EXISTS public.benchmark_records (
    id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL,
    numeric_field NUMERIC(20, 6) NOT NULL,
    status TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.benchmark_records REPLICA IDENTITY FULL;

DROP PUBLICATION IF EXISTS dbz_benchmark_publication;
CREATE PUBLICATION dbz_benchmark_publication FOR TABLE public.benchmark_records;

DROP PUBLICATION IF EXISTS outboxx_benchmark_publication;
CREATE PUBLICATION outboxx_benchmark_publication FOR TABLE public.benchmark_records;

CREATE INDEX IF NOT EXISTS benchmark_records_account_id_idx ON public.benchmark_records (account_id);
CREATE INDEX IF NOT EXISTS benchmark_records_updated_at_idx ON public.benchmark_records (updated_at);
