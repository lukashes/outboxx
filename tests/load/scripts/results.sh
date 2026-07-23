#!/usr/bin/env bash
# Headline benchmark numbers from Prometheus: total events, drain time,
# effective throughput (events / active window), and peak memory/CPU per tool.
# Effective throughput is robust to a short drain burst that a 1m rate misses.
#
# Run right after a drain (ideally after `make reset` so each topic starts at 0).
# Override the lookback with `make results MINUTES=30`.
set -euo pipefail

PROM="${PROM_URL:-http://localhost:9090}"
MINUTES="${MINUTES:-60}"
now="$(date +%s)"
start="$((now - MINUTES * 60))"
win="${MINUTES}m"

if ! curl -fsS --max-time 5 "$PROM/-/ready" >/dev/null 2>&1; then
  echo "Prometheus is not reachable at $PROM (start the stand first)." >&2
  exit 1
fi

instant() { # promql -> scalar, 0 if absent
  curl -s --max-time 10 "$PROM/api/v1/query" \
    --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "0"'
}

drain() { # topic -> "events drain_seconds throughput_per_sec"
  curl -s --max-time 15 "$PROM/api/v1/query_range" \
    --data-urlencode "query=sum(kafka_topic_partition_current_offset{topic=\"$1\"})" \
    --data-urlencode "start=$start" --data-urlencode "end=$now" --data-urlencode "step=5" \
    | jq -r '
        (.data.result[0].values // []) as $v
        | if ($v | length) < 2 then "0 0 0"
          else
            ($v[0][1]  | tonumber) as $min
            | ($v[-1][1] | tonumber) as $max
            # bracket the growth window: last sample still at the floor -> first at the ceiling
            | ([$v[] | select((.[1] | tonumber) <= $min)] | last  | .[0]) as $t0
            | ([$v[] | select((.[1] | tonumber) >= $max)] | first | .[0]) as $t1
            | ($max - $min) as $ev
            | (if $t1 > $t0 then ($t1 - $t0) else 0 end) as $s
            | "\($ev) \($s) \(if $s > 0 then ($ev / $s) else 0 end)"
          end'
}

hb() { # bytes -> human readable
  awk -v b="${1%.*}" 'BEGIN{
    if (b < 1024) printf "%d B", b;
    else if (b < 1048576) printf "%.1f KB", b / 1024;
    else if (b < 1073741824) printf "%.1f MB", b / 1048576;
    else printf "%.2f GB", b / 1073741824;
  }'
}

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b > 0) printf "%.1fx", a / b; else printf "n/a"; }'; }

echo "Window: last ${MINUTES}m"
printf "%-9s %13s %10s %15s %11s %9s\n" tool events "drain(s)" "evt/s(eff)" "mem_peak" "cpu_peak"

# Plain per-tool vars (macOS ships bash 3.2 without associative arrays).
for tool in debezium outboxx pgstream; do
  read -r ev s thr < <(drain "${tool}.public.benchmark_records")
  mem="$(instant "max_over_time(container_memory_working_set_bytes{container_label_com_docker_compose_service=\"$tool\"}[$win])")"
  cpu="$(instant "max_over_time(sum(rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_service=\"$tool\"}[1m]))[$win:15s])")"
  printf -v "THR_${tool}" '%s' "$thr"
  printf -v "MEM_${tool}" '%s' "$mem"
  printf -v "CPU_${tool}" '%s' "$cpu"
  printf "%-9s %13.0f %10.0f %15.0f %11s %9.2f\n" "$tool" "$ev" "$s" "$thr" "$(hb "$mem")" "$cpu"
done

echo
echo "outboxx vs debezium:"
echo "  throughput:  $(ratio "$THR_outboxx" "$THR_debezium") (outboxx / debezium)"
echo "  memory:      $(ratio "$MEM_debezium" "$MEM_outboxx") less (debezium / outboxx)"
echo "  cpu peak:    $(ratio "$CPU_debezium" "$CPU_outboxx") less (debezium / outboxx)"

echo
echo "outboxx vs pgstream:"
echo "  throughput:  $(ratio "$THR_outboxx" "$THR_pgstream") (outboxx / pgstream)"
echo "  memory:      $(ratio "$MEM_pgstream" "$MEM_outboxx") less (pgstream / outboxx)"
echo "  cpu peak:    $(ratio "$CPU_pgstream" "$CPU_outboxx") less (pgstream / outboxx)"
