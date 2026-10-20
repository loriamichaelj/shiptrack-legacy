#!/usr/bin/env bash
# Take down the legacy root (ADR-0016). Run by destroy-all.yml as <PREFIX>-legacy-apply, in the dev
# environment, in two jobs that each need an approval.
# Usage: .github/scripts/terraform-destroy.sh plan|destroy <name>
#
# plan     shows the addresses and actions a destroy of the whole root would make.
# destroy  makes a fresh plan and applies that plan in the same run; no plan file leaves the runner.
#
# Both modes fail unless the CONFIRM environment variable equals <name>. As in terraform-ci.sh, only
# addresses and actions are printed, and a failure prints Terraform's output with identifiers masked.
#
# The artifacts bucket is versioned and cannot be deleted while it holds objects. `destroy` first
# applies the bucket alone with artifacts_force_destroy set to true, then destroys with it still true.
# The next normal apply sets it back for anything that remains.
#
# Environment:
#   CONFIRM           the value the person typed; must equal <name> (required)
#   AWS_REGION        region of the state bucket (required)
#   TF_STATE_KEY      state object key (default: legacy/dev.tfstate)
#   TF_VAR_*          input variables
set -euo pipefail

mode=${1:?usage: terraform-destroy.sh plan|destroy <name>}
name=${2:?usage: terraform-destroy.sh plan|destroy <name>}
[[ "$mode" == plan || "$mode" == destroy ]] || { echo "unknown mode: $mode" >&2; exit 2; }
: "${AWS_REGION:?AWS_REGION is required}"

if [[ "${CONFIRM:-}" != "$name" ]]; then
  echo "::error::The confirmation does not match. Type ${name} to take it down."
  exit 1
fi
export TF_IN_AUTOMATION=1 TF_INPUT=0

state_key=${TF_STATE_KEY:-legacy/dev.tfstate}
cd "$(dirname "${BASH_SOURCE[0]}")/../../terraform/envs/dev"

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"
bucket="shiptrack-tfstate-${account}-${AWS_REGION}"

log() { printf '%s\n' "$*"; }

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

# summarize <plan> <step>: the addresses and actions of a saved plan, never values.
summarize() {
  local text
  text=$(terraform show -json "$1" | jq -r '
    [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $changes
    | (if ($changes | length) == 0 then "Nothing to change."
       else ($changes | map("- `\(.change.actions | join("+"))` \(.address)") | join("\n")) end)
      + "\n\n\($changes | length) resource change(s).\n"')
  log "$text"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '## destroy %s: %s (%s)\n\n%s\n' "$name" "$2" "$mode" "$text" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# The plan files stay on the runner: they are never uploaded.
quietly terraform init -input=false \
  -backend-config="bucket=${bucket}" \
  -backend-config="key=${state_key}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true"

if [[ "$mode" == destroy ]]; then
  log "Letting Terraform empty the artifacts bucket."
  quietly terraform plan -input=false -lock-timeout=120s -target=aws_s3_bucket.artifacts \
    -var artifacts_force_destroy=true -out=unprotect.tfplan
  summarize unprotect.tfplan "allow the artifacts bucket to be emptied"
  # This only updates. A plan that creates the bucket means it is already gone, as when a run that stopped
  # part-way is dispatched again, and applying it would build it again.
  creates=$(terraform show -json unprotect.tfplan | jq '[.resource_changes[]? | select(.change.actions | index("create"))] | length')
  if ((creates > 0)); then
    log "The plan would create ${creates} resource(s): the bucket is gone. Not applying it."
  else
    quietly terraform apply -input=false -lock-timeout=120s unprotect.tfplan
  fi
fi

quietly terraform plan -destroy -input=false -lock-timeout=120s -var artifacts_force_destroy=true -out=tfplan
summarize tfplan "destroy"
[[ "$mode" == destroy ]] || exit 0
quietly terraform apply -input=false -lock-timeout=120s tfplan
log "Destroy complete."
