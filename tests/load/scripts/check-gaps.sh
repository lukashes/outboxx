#!/usr/bin/env bash
# Verify the outboxx topic lost no message: every id the source assigned must
# appear at least once. Ids come from a BIGSERIAL (benchmark_records.id), so the
# assigned space is 1..last_value; a missing id inside it is a dropped message.
#
# Source of truth is the sequence last_value, not max(id) in the table: deletes
# remove rows but the id was still emitted, so the sequence is the only count
# that survives deletes. Reads the topic from the beginning in a throwaway group,
# so it is safe to run while outboxx keeps producing.
#
# The read is bounded by the topic's current end offsets, not by an idle timeout:
# while outboxx keeps producing, a message always arrives before any idle window
# elapses, so a timeout-based consumer would never stop. Snapshot the high
# watermark and read exactly that many messages instead.
#
# Exit non-zero if a gap is found. Override with TOPIC=... IDLE_MS=... .
set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"
TOPIC="${TOPIC:-outboxx.public.benchmark_records}"
IDLE_MS="${IDLE_MS:-10000}" # fallback stop if fewer messages are readable than the snapshot

# COMPOSE may start with env-var assignments (VAR=val ... docker compose -p ...).
# After expansion the shell would treat the leading VAR=val as the command, so
# run it through env, which consumes the assignments before the real command.
compose() { env $COMPOSE "$@"; }

# Highest id the source ever assigned. NULL (never called) -> 0.
last_value="$(
  compose exec -T postgres psql -U postgres -d bench -tAc \
    "SELECT COALESCE(last_value, 0) FROM pg_sequences
      WHERE schemaname = 'public' AND sequencename = 'benchmark_records_id_seq'"
)"
last_value="${last_value:-0}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Snapshot the current end offset (sum over partitions) as the message count to
# read. Bounds the consumer so it stops even while the topic keeps growing.
end_total="$(
  compose exec -T kafka /kafka/bin/kafka-get-offsets.sh \
    --bootstrap-server kafka:9092 --topic "$TOPIC" \
    | awk -F: '{ sum += $3 } END { print sum + 0 }'
)"

if [ "$end_total" -eq 0 ]; then
  echo "Topic $TOPIC is empty: no messages to check."
  [ "$last_value" -gt 0 ] && exit 1 || exit 0
fi

echo "Consuming $end_total message(s) from $TOPIC (snapshot end offset)..."
# --max-messages stops at the snapshot; --timeout-ms is only a fallback if fewer
# are actually readable (e.g. retention trimmed the head). Tolerate its non-zero
# exit and work off what it printed.
compose exec -T kafka /kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 --topic "$TOPIC" \
  --from-beginning --max-messages "$end_total" --timeout-ms "$IDLE_MS" >"$tmp" 2>/dev/null || true

# Sorted ids (duplicates kept), one pass for range, distinct/dup counts, gaps.
jq -r '.data.id // empty' "$tmp" | sort -n | awk -v last="$last_value" '
  NR == 1 { min = $1; max = $1; distinct = 1; prev = $1; next }
  $1 != prev {
    if ($1 > prev + 1) {
      holes += $1 - prev - 1
      if (shown < 10) { printf "  missing id range %d..%d\n", prev + 1, $1 - 1; shown++ }
    }
    distinct++; max = $1; prev = $1
  }
  END {
    if (NR == 0) { print "Topic is empty: no messages to check."; exit (last > 0 ? 1 : 0) }

    duplicates = NR - distinct
    printf "messages: %d   distinct ids: %d   duplicates: %d\n", NR, distinct, duplicates
    printf "range: %d..%d   sequence last_value: %d\n", min, max, last

    fail = 0
    if (holes > 0)   { printf "GAP: %d id(s) missing inside %d..%d\n", holes, min, max; fail = 1 }
    if (max < last)  { printf "GAP: topic ends at %d but source reached %d (%d tail id(s) missing)\n", max, last, last - max; fail = 1 }
    if (min > 1)     { printf "NOTE: first id is %d, not 1 (topic retention or a trimmed run?)\n", min }

    if (fail == 0) printf "OK: no gaps, every assigned id present (%d duplicate re-deliveries).\n", duplicates
    exit fail
  }'
