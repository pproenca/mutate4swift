#!/usr/bin/env bash
set -euo pipefail

RUNS=2
JOBS=4
COVERAGE=0
OUTPUT_DIR=""
KEEP_SANDBOX=0
SUBJECT_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/benchmark_scheduler.sh [options]

Options:
  --runs <count>          Number of trials per scheduler (default: 2)
  --jobs <count>          Worker count for mutate4swift --all (default: 4)
  --coverage              Enable coverage filtering during benchmark runs
  --no-coverage           Disable coverage filtering (default)
  --out <dir>             Output directory (default: dist/benchmarks/scheduler-<timestamp>)
  --subject <path>        External Swift package to mutate (default: benchmark mutate4swift repo itself)
  --keep-sandbox          Keep sandbox copy after finishing
  --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      RUNS="${2:?missing value for --runs}"
      shift 2
      ;;
    --jobs)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --coverage)
      COVERAGE=1
      shift
      ;;
    --no-coverage)
      COVERAGE=0
      shift
      ;;
    --out)
      OUTPUT_DIR="${2:?missing value for --out}"
      shift 2
      ;;
    --subject)
      SUBJECT_DIR="${2:?missing value for --subject}"
      shift 2
      ;;
    --keep-sandbox)
      KEEP_SANDBOX=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "--runs must be >= 1" >&2
  exit 1
fi
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  echo "--jobs must be >= 1" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "$SUBJECT_DIR" ]]; then
  SUBJECT_DIR="$(cd "$SUBJECT_DIR" && pwd)"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/dist/benchmarks/scheduler-$TIMESTAMP"
fi
mkdir -p "$OUTPUT_DIR"

SANDBOX_DIR="$(mktemp -d "/tmp/mutate4swift-bench.XXXXXX")"
if [[ "$KEEP_SANDBOX" -eq 0 ]]; then
  trap 'rm -rf "$SANDBOX_DIR"' EXIT
fi

SANDBOX_REPO="$SANDBOX_DIR/repo"

echo "Benchmark output: $OUTPUT_DIR"
echo "Sandbox repo: $SANDBOX_REPO"
if [[ -n "$SUBJECT_DIR" ]]; then
  echo "Benchmark subject package: $SUBJECT_DIR"
else
  echo "Benchmark subject package: <mutate4swift repo>"
fi
echo "Copying mutate4swift workspace into sandbox..."
rsync -a \
  --exclude ".git" \
  --exclude ".build" \
  --exclude ".mutate4swift/worktrees" \
  --exclude "dist" \
  "$ROOT_DIR/" "$SANDBOX_REPO/"

SANDBOX_SUBJECT="$SANDBOX_REPO"
if [[ -n "$SUBJECT_DIR" ]]; then
  SANDBOX_SUBJECT="$SANDBOX_DIR/subject"
  echo "Copying subject package into sandbox..."
  rsync -a \
    --exclude ".git" \
    --exclude ".build" \
    --exclude ".mutate4swift/worktrees" \
    --exclude "dist" \
    "$SUBJECT_DIR/" "$SANDBOX_SUBJECT/"
fi

echo "Building release binary in sandbox..."
(
  cd "$SANDBOX_REPO"
  swift build -c release >"$OUTPUT_DIR/build.log" 2>&1
)
BIN="$SANDBOX_REPO/.build/release/mutate4swift"

if [[ ! -x "$BIN" ]]; then
  echo "Expected binary at $BIN" >&2
  exit 1
fi

SUMMARY_CSV="$OUTPUT_DIR/summary.csv"
cat >"$SUMMARY_CSV" <<'EOF'
mode,run,exit_code,wall_seconds,avg_cpu_percent,peak_cpu_percent,avg_threads,peak_threads,peak_rss_mb,avg_load1,peak_load1,pageins_delta,pageouts_delta,iostat_avg_mb_s,iostat_peak_mb_s,queue_dispatched,queue_steals,total_files,total_mutations,total_survivors,total_build_errors
EOF

now_seconds() {
  perl -MTime::HiRes=time -e 'printf "%.6f\n", time'
}

collect_descendant_pids() {
  local root_pid="$1"
  local frontier="$root_pid"
  local all=""
  while [[ -n "$frontier" ]]; do
    local next=""
    for pid in $frontier; do
      all="$all $pid"
      local children
      children="$(pgrep -P "$pid" || true)"
      if [[ -n "$children" ]]; then
        next="$next $children"
      fi
    done
    frontier="$next"
  done
  echo "$all"
}

sample_process_tree() {
  local root_pid="$1"
  local sample_file="$2"

  local pids
  pids="$(collect_descendant_pids "$root_pid")"
  pids="$(echo "$pids" | xargs || true)"
  if [[ -z "$pids" ]]; then
    return 1
  fi

  local pid_csv
  pid_csv="$(echo "$pids" | tr ' ' ',')"

  local ps_agg
  ps_agg="$(ps -p "$pid_csv" -o %cpu=,rss=,vsz= 2>/dev/null || true)"
  ps_agg="$(echo "$ps_agg" \
    | awk '
      BEGIN { cpu=0; rss=0; vsz=0; count=0 }
      NF >= 3 {
        cpu += $1
        rss += $2
        vsz += $3
        count += 1
      }
      END {
        if (count == 0) {
          print ""
        } else {
          printf "%.2f,%d,%d,%d", cpu, rss, vsz, count
        }
      }
    ')"
  if [[ -z "$ps_agg" ]]; then
    return 1
  fi

  local thread_count
  thread_count="$(ps -M -p "$pid_csv" 2>/dev/null | awk 'NR > 1 { count += 1 } END { print count + 0 }')"

  local load_avg
  load_avg="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
  local load1 load5 load15
  read -r load1 load5 load15 <<<"$load_avg"

  local timestamp
  timestamp="$(date +%s)"
  echo "$timestamp,$ps_agg,$thread_count,$load1,$load5,$load15" >>"$sample_file"
}

vm_stat_value() {
  local vm_blob="$1"
  local label="$2"
  echo "$vm_blob" | awk -F: -v key="$label" '
    $1 ~ key {
      gsub(/\./, "", $2)
      gsub(/[^0-9]/, "", $2)
      print $2
      found=1
      exit
    }
    END {
      if (!found) print 0
    }
  '
}

summarize_samples() {
  local sample_file="$1"
  awk -F, '
    NR == 1 { next }
    {
      cpu_sum += $2
      if ($2 > cpu_peak) cpu_peak = $2
      thr_sum += $6
      if ($6 > thr_peak) thr_peak = $6
      rss_mb = $3 / 1024.0
      if (rss_mb > rss_peak) rss_peak = rss_mb
      load_sum += $7
      if ($7 > load_peak) load_peak = $7
      n += 1
    }
    END {
      if (n == 0) {
        printf "0,0,0,0,0,0"
      } else {
        printf "%.2f,%.2f,%.2f,%.0f,%.2f,%.2f", cpu_sum / n, cpu_peak, thr_sum / n, thr_peak, rss_peak, load_sum / n
      }
    }
  ' "$sample_file"
}

summarize_iostat() {
  local iostat_file="$1"
  awk '
    BEGIN { sum=0; max=0; n=0 }
    /^[[:space:]]*[0-9]/ {
      numeric=0
      for (i = 1; i <= NF; i++) {
        if ($i + 0 == $i) {
          numeric += 1
          if (numeric % 3 == 0) {
            value = $i + 0
            sum += value
            if (value > max) max = value
            n += 1
          }
        }
      }
    }
    END {
      if (n == 0) {
        printf "0,0"
      } else {
        printf "%.2f,%.2f", sum / n, max
      }
    }
  ' "$iostat_file"
}

extract_repository_totals() {
  local stderr_file="$1"
  local line
  line="$(grep -E "repository mutation run complete: files [0-9]+, mutations [0-9]+, survivors [0-9]+, build errors [0-9]+" "$stderr_file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "0,0,0,0"
    return
  fi
  echo "$line" \
    | sed -E 's/.*files ([0-9]+), mutations ([0-9]+), survivors ([0-9]+), build errors ([0-9]+).*/\1,\2,\3,\4/'
}

extract_queue_metrics() {
  local stderr_file="$1"
  local line
  line="$(grep -E "queue dispatch complete: dispatched [0-9]+, steals [0-9]+" "$stderr_file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "0,0"
    return
  fi
  echo "$line" \
    | sed -E 's/.*dispatched ([0-9]+), steals ([0-9]+).*/\1,\2/'
}

run_trial() {
  local mode="$1"
  local run_index="$2"
  local trial_dir="$OUTPUT_DIR/${mode}-run${run_index}"
  mkdir -p "$trial_dir"

  local stdout_log="$trial_dir/stdout.log"
  local stderr_log="$trial_dir/stderr.log"
  local ps_samples="$trial_dir/ps_samples.csv"
  local iostat_log="$trial_dir/iostat.log"

  local cmd=(
    "$BIN"
    "--all"
    "--project" "$SANDBOX_SUBJECT"
    "--jobs" "$JOBS"
    "--scheduler" "$mode"
    "--max-build-error-ratio" "1.0"
    "--no-readiness-scorecard"
  )
  if [[ "$COVERAGE" -eq 1 ]]; then
    cmd+=("--coverage")
  fi

  printf "%q " "${cmd[@]}" >"$trial_dir/command.txt"
  echo >>"$trial_dir/command.txt"

  echo "epoch,cpu_percent,rss_kb,vsz_kb,proc_count,threads,loadavg_1m,loadavg_5m,loadavg_15m" >"$ps_samples"

  local vm_before vm_after
  vm_before="$(vm_stat)"

  /usr/sbin/iostat -d -w 1 >"$iostat_log" 2>&1 &
  local iostat_pid=$!

  local start_ts
  start_ts="$(now_seconds)"
  (
    cd "$SANDBOX_REPO"
    "${cmd[@]}"
  ) >"$stdout_log" 2>"$stderr_log" &
  local app_pid=$!

  while kill -0 "$app_pid" 2>/dev/null; do
    sample_process_tree "$app_pid" "$ps_samples" || true
    sleep 1
  done

  local exit_code=0
  if ! wait "$app_pid"; then
    exit_code=$?
  fi
  kill "$iostat_pid" 2>/dev/null || true
  wait "$iostat_pid" 2>/dev/null || true
  vm_after="$(vm_stat)"

  local end_ts wall_seconds
  end_ts="$(now_seconds)"
  wall_seconds="$(awk -v start="$start_ts" -v end="$end_ts" 'BEGIN { printf "%.2f", end - start }')"

  local sample_summary avg_cpu peak_cpu avg_threads peak_threads peak_rss_mb avg_load1
  sample_summary="$(summarize_samples "$ps_samples")"
  IFS=',' read -r avg_cpu peak_cpu avg_threads peak_threads peak_rss_mb avg_load1 <<<"$sample_summary"
  local peak_load1
  peak_load1="$(awk -F, 'NR > 1 && $7 > max { max = $7 } END { printf "%.2f", max + 0 }' "$ps_samples")"

  local pageins_before pageouts_before pageins_after pageouts_after
  pageins_before="$(vm_stat_value "$vm_before" "Pageins")"
  pageouts_before="$(vm_stat_value "$vm_before" "Pageouts")"
  pageins_after="$(vm_stat_value "$vm_after" "Pageins")"
  pageouts_after="$(vm_stat_value "$vm_after" "Pageouts")"
  local pageins_delta pageouts_delta
  pageins_delta=$((pageins_after - pageins_before))
  pageouts_delta=$((pageouts_after - pageouts_before))

  local iostat_summary iostat_avg_mb_s iostat_peak_mb_s
  iostat_summary="$(summarize_iostat "$iostat_log")"
  IFS=',' read -r iostat_avg_mb_s iostat_peak_mb_s <<<"$iostat_summary"

  local queue_summary queue_dispatched queue_steals
  queue_summary="$(extract_queue_metrics "$stderr_log")"
  IFS=',' read -r queue_dispatched queue_steals <<<"$queue_summary"

  local repo_summary total_files total_mutations total_survivors total_build_errors
  repo_summary="$(extract_repository_totals "$stderr_log")"
  IFS=',' read -r total_files total_mutations total_survivors total_build_errors <<<"$repo_summary"

  cat >>"$SUMMARY_CSV" <<EOF
$mode,$run_index,$exit_code,$wall_seconds,$avg_cpu,$peak_cpu,$avg_threads,$peak_threads,$peak_rss_mb,$avg_load1,$peak_load1,$pageins_delta,$pageouts_delta,$iostat_avg_mb_s,$iostat_peak_mb_s,$queue_dispatched,$queue_steals,$total_files,$total_mutations,$total_survivors,$total_build_errors
EOF

  echo "Completed $mode run $run_index: wall=${wall_seconds}s exit=$exit_code"
}

for mode in static dynamic; do
  for run_index in $(seq 1 "$RUNS"); do
    run_trial "$mode" "$run_index"
  done
done

REPORT_MD="$OUTPUT_DIR/report.md"
STATIC_MEAN_WALL="$(awk -F, '$1 == "static" { sum += $4; n += 1 } END { if (n == 0) print 0; else printf "%.2f", sum / n }' "$SUMMARY_CSV")"
DYNAMIC_MEAN_WALL="$(awk -F, '$1 == "dynamic" { sum += $4; n += 1 } END { if (n == 0) print 0; else printf "%.2f", sum / n }' "$SUMMARY_CSV")"
SPEEDUP="$(awk -v s="$STATIC_MEAN_WALL" -v d="$DYNAMIC_MEAN_WALL" 'BEGIN { if (d <= 0) print "0.00"; else printf "%.2f", s / d }')"

{
  echo "# Scheduler Benchmark Report"
  echo
  echo "- Timestamp: $TIMESTAMP"
  echo "- Sandbox: $SANDBOX_REPO"
  echo "- Subject package in sandbox: $SANDBOX_SUBJECT"
  echo "- Runs per mode: $RUNS"
  echo "- Jobs: $JOBS"
  echo "- Coverage enabled: $COVERAGE"
  echo
  echo "## Mean Metrics by Mode"
  echo
  echo "| Mode | Mean wall (s) | Mean CPU (%) | Peak CPU (%) | Mean threads | Peak threads | Peak RSS (MB) | Mean load1 | Peak load1 | Mean disk MB/s | Peak disk MB/s | Mean queue steals | Mean mutations |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  awk -F, '
    NR == 1 { next }
    {
      mode = $1
      wall[mode] += $4
      cpu[mode] += $5
      if ($6 > cpu_peak[mode]) cpu_peak[mode] = $6
      thr[mode] += $7
      if ($8 > thr_peak[mode]) thr_peak[mode] = $8
      if ($9 > rss_peak[mode]) rss_peak[mode] = $9
      load[mode] += $10
      if ($11 > load_peak[mode]) load_peak[mode] = $11
      disk_avg[mode] += $14
      if ($15 > disk_peak[mode]) disk_peak[mode] = $15
      steals[mode] += $17
      muts[mode] += $19
      n[mode] += 1
    }
    END {
      modes[1] = "static"
      modes[2] = "dynamic"
      for (i = 1; i <= 2; i++) {
        mode = modes[i]
        if (n[mode] == 0) continue
        printf "| %s | %.2f | %.2f | %.2f | %.2f | %.0f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |\n",
          mode,
          wall[mode] / n[mode],
          cpu[mode] / n[mode],
          cpu_peak[mode] + 0,
          thr[mode] / n[mode],
          thr_peak[mode] + 0,
          rss_peak[mode] + 0,
          load[mode] / n[mode],
          load_peak[mode] + 0,
          disk_avg[mode] / n[mode],
          disk_peak[mode] + 0,
          steals[mode] / n[mode],
          muts[mode] / n[mode]
      }
    }
  ' "$SUMMARY_CSV"
  echo
  echo "## Throughput Result"
  echo
  echo "- Dynamic speedup over static (wall time): **${SPEEDUP}x**"
  echo "- Mean wall time static: ${STATIC_MEAN_WALL}s"
  echo "- Mean wall time dynamic: ${DYNAMIC_MEAN_WALL}s"
  echo
  echo "## Raw Data"
  echo
  echo "- Summary CSV: $SUMMARY_CSV"
  echo "- Per-run logs: $OUTPUT_DIR/<mode>-run*/"
} >"$REPORT_MD"

echo "Benchmark complete."
echo "Report: $REPORT_MD"
