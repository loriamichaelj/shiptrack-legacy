#!/usr/bin/env bash
# Run a ShipTrack SSM document on the legacy hosts, wait for it, and report the result.
# Output from the hosts is printed only when a command fails, and only after identifiers (account
# IDs, ARNs, instance IDs, addresses) are masked: the logs of a public repository are public.
#
# Environment:
#   DOCUMENT          document name, for example ShipTrack-Deploy (required)
#   PARAMETERS        the document parameters as JSON (required)
#   INSTANCE_ID       run on this instance only; otherwise on every instance tagged Stack=legacy
#   MAX_CONCURRENCY   hosts at a time (default 1)
#   OUTPUT_FILE       where to write the hosts' standard output, unmasked, for the caller to read
#                     (it stays on the runner and is never uploaded)
#   TIMEOUT_SECONDS   how long to wait (default 900)
set -euo pipefail

: "${DOCUMENT:?DOCUMENT is required}"
: "${PARAMETERS:?PARAMETERS is required}"
max_concurrency=${MAX_CONCURRENCY:-1}
timeout=${TIMEOUT_SECONDS:-900}

scrub() {
  sed -E '
    s/[0-9]{12}/***/g
    s#arn:aws[a-z-]*:[^[:space:]"]+#arn:***#g
    s/i-[0-9a-f]{8,17}/i-***/g
    s/ip-[0-9]+-[0-9]+-[0-9]+-[0-9]+/ip-***/g
    s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/x.x.x.x/g
    s/[A-Za-z0-9.-]+\.amazonaws\.com/host.amazonaws.com/g
  '
}

args=(--document-name "$DOCUMENT" --parameters "$PARAMETERS"
  --max-concurrency "$max_concurrency" --max-errors 0
  --query Command.CommandId --output text)
if [[ -n "${INSTANCE_ID:-}" ]]; then
  args+=(--instance-ids "$INSTANCE_ID")
else
  args+=(--targets "Key=tag:Stack,Values=legacy")
fi
command_id=$(aws ssm send-command "${args[@]}")
echo "sent $DOCUMENT"

statuses() {
  aws ssm list-command-invocations --command-id "$command_id" \
    --query 'CommandInvocations[].Status' --output text
}

deadline=$((SECONDS + timeout))
while :; do
  current=$(statuses)
  # No invocations yet: the targets are still being resolved.
  if [[ -n "$current" ]] && ! grep -qE 'Pending|InProgress|Delayed' <<<"$current"; then
    break
  fi
  if ((SECONDS > deadline)); then
    echo "timed out after ${timeout}s waiting for $DOCUMENT" >&2
    exit 1
  fi
  sleep 5
done

total=$(wc -w <<<"$current" | tr -d ' ')
ok=$(tr '[:space:]' '\n' <<<"$current" | grep -cx Success || true)
echo "$DOCUMENT: $ok of $total hosts succeeded"

: >"${OUTPUT_FILE:-/dev/null}"
failed=0
instances=$(aws ssm list-command-invocations --command-id "$command_id" \
  --query 'CommandInvocations[].InstanceId' --output text | tr '\t' '\n')
for instance in $instances; do
  detail=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" --output json)
  status=$(jq -r .Status <<<"$detail")
  if [[ -n "${OUTPUT_FILE:-}" ]]; then
    jq -r .StandardOutputContent <<<"$detail" >>"$OUTPUT_FILE"
  fi
  if [[ "$status" != Success ]]; then
    failed=1
    echo "--- a host reported $status ---" >&2
    jq -r '.StandardOutputContent, .StandardErrorContent' <<<"$detail" | scrub >&2
  fi
done
exit "$failed"
