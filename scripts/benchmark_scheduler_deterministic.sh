#!/usr/bin/env bash
set -euo pipefail

RUNS=30
JOBS=4
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/benchmark_scheduler_deterministic.sh [options]

Options:
  --runs <count>    Repetitions per scenario (default: 30)
  --jobs <count>    Simulated worker count (default: 4)
  --out <dir>       Output directory (default: dist/benchmarks/deterministic-<timestamp>)
  --help            Show this help
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
    --out)
      OUTPUT_DIR="${2:?missing value for --out}"
      shift 2
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
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/dist/benchmarks/deterministic-$TIMESTAMP"
fi
mkdir -p "$OUTPUT_DIR"

REPORT_TXT="$OUTPUT_DIR/report.txt"
REPORT_JSON="$OUTPUT_DIR/report.json"

echo "Building SchedulerBenchmark executable..."
(cd "$ROOT_DIR" && swift build -c release --product SchedulerBenchmark >"$OUTPUT_DIR/build.log" 2>&1)

echo "Running deterministic benchmark (runs=$RUNS, jobs=$JOBS)..."
(cd "$ROOT_DIR" && ./.build/release/SchedulerBenchmark --runs "$RUNS" --jobs "$JOBS") >"$REPORT_TXT"
(cd "$ROOT_DIR" && ./.build/release/SchedulerBenchmark --runs "$RUNS" --jobs "$JOBS" --json) >"$REPORT_JSON"

echo "Deterministic benchmark complete."
echo "Text report: $REPORT_TXT"
echo "JSON report: $REPORT_JSON"
