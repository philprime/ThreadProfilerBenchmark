#!/usr/bin/env bash
set -euo pipefail

target=$1
outcome=$2
results="${RESULTS_DIR:-Results}"
log="$results/$target.log"

case "$target" in
    macos) title="macOS" ;;
    simulator) title="iPhone Simulator" ;;
    *) echo "Unsupported CI benchmark target: $target" >&2; exit 64 ;;
esac

report=""
if [[ -f "$log" ]]; then
    report=$(tr -d '\r' < "$log" | awk '
        /^THREAD PROFILER BENCHMARK / { printing = 1 }
        printing { print }
        /^BENCHMARK_STATUS:/ { exit }
    ')
fi

{
    printf '## %s profiler benchmark\n\n' "$title"
    printf 'Benchmark step: **%s**. Full logs and device profiles are available in the benchmark artifact.\n\n' "$outcome"
    if [[ -n "$report" ]]; then
        printf '~~~text\n%s\n~~~\n\n' "$report"
    else
        printf 'No benchmark report was produced. Check the setup and build logs.\n\n'
    fi
    printf 'Hosted-runner timings are noisy. Five paired trials are not a regression threshold.\n'
} >> "$GITHUB_STEP_SUMMARY"

if [[ "$outcome" != "success" ]] || ! grep -Fq 'BENCHMARK_STATUS: PASS' <<< "$report"; then
    printf '::error title=%s benchmark::No successful benchmark result. See the job summary and artifact logs.\n' "$title"
    exit 1
fi

metrics=$(awk '
    /^(Trials:|Samples:|Relative CPU change:|Paired CPU change:|Pause window median:|Pause window p95:|Pause window p99:|Pause window max:|Suspend calls mean:|Stack capture mean:|Resume calls mean:|Capture failures:)/ {
        if (count++) printf " | "
        printf "%s", $0
    }
' <<< "$report")
# Escape workflow-command data so report text cannot create additional commands or annotations.
metrics=${metrics//'%'/'%25'}
metrics=${metrics//$'\r'/'%0D'}
metrics=${metrics//$'\n'/'%0A'}
printf '::notice title=%s profiler results::%s\n' "$title" "$metrics"
