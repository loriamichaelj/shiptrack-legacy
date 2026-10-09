#!/usr/bin/env bash
# Plan or apply terraform/envs/dev. Run by terraform-pr.yml and terraform-apply.yml.
# Usage: .github/scripts/terraform-ci.sh plan|apply
#
# The state bucket name contains the account ID, so the backend is configured at init time instead
# of being committed. A failed step prints Terraform's output with the account and resource IDs
# masked, because the logs of a public repository are public.
#
# Environment:
#   AWS_REGION        region of the state bucket (required)
#   TF_DIR            configuration directory (default: terraform/envs/dev)
#   TF_STATE_KEY      state object key (default: legacy/dev.tfstate)
#   SUMMARY_FILE      where `plan` writes the address-and-action summary as Markdown (optional)
#   TF_VAR_*          input variables
set -euo pipefail

mode=${1:?usage: terraform-ci.sh plan|apply}
[[ "$mode" == plan || "$mode" == apply ]] || { echo "unknown mode: $mode" >&2; exit 2; }
: "${AWS_REGION:?AWS_REGION is required}"
export TF_IN_AUTOMATION=1 TF_INPUT=0

dir=${TF_DIR:-terraform/envs/dev}
state_key=${TF_STATE_KEY:-legacy/dev.tfstate}
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
cd "$dir"

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"
bucket="shiptrack-tfstate-${account}-${AWS_REGION}"

# Run a terraform command quietly; show its output only if it fails, with identifiers masked.
quietly() {
  local out
  out=$(mktemp)
  if ! "$@" >"$out" 2>&1; then
    sed -E "s/${account}/***/g; s/\[id=[^]]*\]/[id=***]/g; s/(vpc|subnet|sg|rtb|igw|eipalloc|nat|vpce|eni|acl|rtbassoc|ami|i|lt)-[0-9a-f]{8,17}/\1-***/g" "$out" >&2
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
}

# Print the changes in a saved plan: addresses and actions, never attribute values. For an update it
# also names the attributes that differ, so a perpetual diff can be traced without publishing what
# changed.
summarize() {
  terraform show -json "$1" | jq -r '
    def changed($c):
      (($c.change.before // {}) as $b | ($c.change.after // {}) as $a
        | ([$b, $a] | map(keys) | add | unique)
        | map(select($b[.] != $a[.]))) | join(", ");
    [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $changes
    | (if ($changes | length) == 0 then "No changes."
       else ($changes | map(
              "- `\(.change.actions | join("+"))` \(.address)"
              + (if .change.actions == ["update"] then " (changed: \(changed(.)))" else "" end)
            ) | join("\n")) end)
      + "\n\n\($changes | length) resource change(s).\n"'
}

quietly terraform init -input=false \
  -backend-config="bucket=${bucket}" \
  -backend-config="key=${state_key}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true"

# The plan file stays on the runner: it is never uploaded, and apply makes its own in the same job.
plan=$(mktemp -u)
trap 'rm -f "$plan"' EXIT
quietly terraform plan -input=false -lock-timeout=120s -out="$plan"
text=$(summarize "$plan")
printf '%s\n' "$text"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '## Terraform %s (%s)\n\n%s\n' "$mode" "$dir" "$text" >>"$GITHUB_STEP_SUMMARY"
fi
if [[ "$mode" == plan ]]; then
  [[ -z "${SUMMARY_FILE:-}" ]] || printf '%s\n' "$text" >"$SUMMARY_FILE"
  exit 0
fi

quietly terraform apply -input=false "$plan"
echo "Apply complete."
