import argparse
import os
import time

import psycopg


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def connect() -> psycopg.Connection:
    return psycopg.connect(
        host=env("PGHOST", "localhost"),
        port=int(env("PGPORT", "5432")),
        dbname=env("PGDATABASE", "bench"),
        user=env("PGUSER", "postgres"),
        password=env("PGPASSWORD", "postgres"),
        autocommit=False,
    )


def ensure_table(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS public.benchmark_records (
                id BIGSERIAL PRIMARY KEY,
                account_id BIGINT NOT NULL,
                numeric_field NUMERIC(20, 6) NOT NULL,
                status TEXT NOT NULL,
                payload JSONB NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        cur.execute("ALTER TABLE public.benchmark_records REPLICA IDENTITY FULL")
        conn.commit()


def payload_padding_size(row_bytes: int) -> int:
    return max(0, row_bytes - 160)


def insert_batch(conn: psycopg.Connection, batch_size: int, row_bytes: int) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH payload AS (
                SELECT repeat('x', %s) AS padding
            ),
            inserted AS (
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
                FROM generate_series(1, %s) AS gs
                CROSS JOIN payload
                RETURNING 1
            )
            SELECT count(*) FROM inserted
            """,
            (payload_padding_size(row_bytes), batch_size),
        )
        return int(cur.fetchone()[0])


def update_batch(conn: psycopg.Connection, count: int, row_bytes: int) -> int:
    if count <= 0:
        return 0
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH bounds AS (
                SELECT COALESCE(max(id), 0) AS max_id
                FROM public.benchmark_records
            ),
            picked AS (
                SELECT id
                FROM public.benchmark_records, bounds
                WHERE id > GREATEST(bounds.max_id - %s, 0)
                LIMIT %s
            ),
            payload AS (
                SELECT repeat('u', %s) AS padding
            ),
            updated AS (
                UPDATE public.benchmark_records AS target
                SET numeric_field = (random() * 1000000)::NUMERIC(20, 6),
                    status = (ARRAY['new', 'active', 'paused', 'closed'])[1 + floor(random() * 4)::INT],
                    payload = jsonb_build_object(
                        'source', 'cdc-benchmark',
                        'updated_at', clock_timestamp(),
                        'padding', payload.padding
                    ),
                    updated_at = now()
                FROM picked
                CROSS JOIN payload
                WHERE target.id = picked.id
                RETURNING 1
            )
            SELECT count(*) FROM updated
            """,
            (max(count * 8, count), count, payload_padding_size(row_bytes)),
        )
        return int(cur.fetchone()[0])


def delete_batch(conn: psycopg.Connection, count: int) -> int:
    if count <= 0:
        return 0
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH picked AS (
                SELECT id
                FROM public.benchmark_records
                LIMIT %s
            ),
            deleted AS (
                DELETE FROM public.benchmark_records AS target
                USING picked
                WHERE target.id = picked.id
                RETURNING 1
            )
            SELECT count(*) FROM deleted
            """,
            (count,),
        )
        return int(cur.fetchone()[0])


def live_row_count(conn: psycopg.Connection) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT COALESCE(n_live_tup, 0)::BIGINT
            FROM pg_stat_user_tables
            WHERE schemaname = 'public' AND relname = 'benchmark_records'
            """
        )
        row = cur.fetchone()
        if row is None:
            return 0
        return int(row[0])


def run(args: argparse.Namespace) -> None:
    conn = connect()
    ensure_table(conn)

    if args.truncate:
        with conn.cursor() as cur:
            cur.execute("TRUNCATE TABLE public.benchmark_records RESTART IDENTITY")
        conn.commit()

    start = time.monotonic()
    next_report = start + args.report_interval
    totals = {"insert": 0, "update": 0, "delete": 0}

    if args.mode == "ramp":
        print(
            "Starting ramp workload: "
            f"steps={args.ramp_steps} step_seconds={args.ramp_step_seconds}s "
            f"initial_batch_size={args.batch_size} interval={args.interval}s "
            f"row_bytes={args.row_bytes} update_ratio={args.update_ratio} delete_ratio={args.delete_ratio}"
        )
    else:
        print(
            "Starting steady workload: "
            f"duration={args.duration}s batch_size={args.batch_size} interval={args.interval}s "
            f"row_bytes={args.row_bytes} update_ratio={args.update_ratio} delete_ratio={args.delete_ratio}"
        )

    try:
        while True:
            iteration_start = time.monotonic()
            if args.mode == "ramp":
                step_index = int((iteration_start - start) // args.ramp_step_seconds)
                if step_index >= args.ramp_steps:
                    break
                current_batch_size = args.batch_size * (2 ** step_index)
            else:
                if iteration_start - start >= args.duration:
                    break
                step_index = 0
                current_batch_size = args.batch_size

            if step_index != getattr(args, "_last_step_index", None):
                setattr(args, "_last_step_index", step_index)
                target = (current_batch_size * (1 + args.update_ratio + args.delete_ratio)) / max(args.interval, 0.001)
                print(
                    f"step={step_index + 1}/{args.ramp_steps if args.mode == 'ramp' else 1} "
                    f"batch_size={current_batch_size} target_if_sleep_bound~={target:.1f}/s"
                )

            inserted = insert_batch(conn, current_batch_size, args.row_bytes)
            totals["insert"] += inserted

            update_count = int(current_batch_size * args.update_ratio)
            updated = update_batch(conn, update_count, args.row_bytes)
            totals["update"] += updated

            delete_count = int(current_batch_size * args.delete_ratio)
            deleted = delete_batch(conn, delete_count)
            totals["delete"] += deleted

            conn.commit()

            now = time.monotonic()
            if now >= next_report:
                elapsed = now - start
                operations = sum(totals.values())
                rate = operations / elapsed if elapsed > 0 else 0
                print(
                    f"elapsed={elapsed:.1f}s ops={operations} rate={rate:.1f}/s "
                    f"insert={totals['insert']} update={totals['update']} delete={totals['delete']} "
                    f"live_rows_est={live_row_count(conn)}"
                )
                next_report = now + args.report_interval

            elapsed_iteration = time.monotonic() - iteration_start
            sleep_for = args.interval - elapsed_iteration
            if sleep_for > 0:
                time.sleep(sleep_for)
    except KeyboardInterrupt:
        print("\nStopping workload generator...")
    finally:
        conn.close()

    elapsed = time.monotonic() - start
    operations = sum(totals.values())
    rate = operations / elapsed if elapsed > 0 else 0
    print(
        f"Finished: elapsed={elapsed:.1f}s ops={operations} rate={rate:.1f}/s "
        f"insert={totals['insert']} update={totals['update']} delete={totals['delete']}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate PostgreSQL write load for Debezium benchmarks.")
    parser.add_argument("--mode", choices=("steady", "ramp"), default="steady")
    parser.add_argument("--duration", type=int, default=300)
    parser.add_argument("--batch-size", type=int, default=500)
    parser.add_argument("--ramp-steps", type=int, default=8)
    parser.add_argument("--ramp-step-seconds", type=int, default=30)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--row-bytes", type=int, default=1024)
    parser.add_argument("--update-ratio", type=float, default=0.25)
    parser.add_argument("--delete-ratio", type=float, default=0.02)
    parser.add_argument("--report-interval", type=float, default=5.0)
    parser.add_argument("--truncate", action="store_true", help="Truncate benchmark_records before running.")
    return parser.parse_args()


if __name__ == "__main__":
    run(parse_args())
