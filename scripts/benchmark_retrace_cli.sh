#!/bin/zsh

set -euo pipefail
zmodload zsh/datetime

if (( $# < 2 )); then
  echo "usage: $0 <iterations> <command...>" >&2
  exit 1
fi

iterations="$1"
shift

if ! [[ "$iterations" =~ '^[0-9]+$' ]] || (( iterations <= 0 )); then
  echo "iterations must be a positive integer" >&2
  exit 1
fi

typeset -a samples
typeset -F total_ms=0
typeset -F min_ms=0
typeset -F max_ms=0

for ((i = 1; i <= iterations; i++)); do
  start="$EPOCHREALTIME"
  "$@" > /dev/null
  end="$EPOCHREALTIME"
  elapsed_ms=$(( (end - start) * 1000.0 ))

  samples+=("$elapsed_ms")
  total_ms=$(( total_ms + elapsed_ms ))

  if (( i == 1 )) || (( elapsed_ms < min_ms )); then
    min_ms="$elapsed_ms"
  fi
  if (( i == 1 )) || (( elapsed_ms > max_ms )); then
    max_ms="$elapsed_ms"
  fi
done

sorted=("${(@on)samples}")
count="${#sorted[@]}"
mid_index=$(( (count + 1) / 2 ))
p50_ms="${sorted[$mid_index]}"
p95_index=$(( (count * 95 + 99) / 100 ))
if (( p95_index < 1 )); then
  p95_index=1
elif (( p95_index > count )); then
  p95_index="$count"
fi
p95_ms="${sorted[$p95_index]}"
avg_ms=$(( total_ms / iterations ))

command_json="$(printf '%s\n' "$@" | sed 's/"/\\"/g' | paste -sd' ' -)"
sample_json="$(printf '%s\n' "${samples[@]}" | paste -sd',' -)"

printf '{\n'
printf '  "iterations": %s,\n' "$iterations"
printf '  "command": "%s",\n' "$command_json"
printf '  "avgMs": %.3f,\n' "$avg_ms"
printf '  "minMs": %.3f,\n' "$min_ms"
printf '  "p50Ms": %.3f,\n' "$p50_ms"
printf '  "p95Ms": %.3f,\n' "$p95_ms"
printf '  "maxMs": %.3f,\n' "$max_ms"
printf '  "samplesMs": [%s]\n' "$sample_json"
printf '}\n'
