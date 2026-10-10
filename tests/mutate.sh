#!/usr/bin/env bash
# Tests for the tests. Each mutation removes one platform guarantee the way a
# real change could; at least one test layer must fail, or the mutation
# "survives" and this script fails. Runs on a scratch copy of the repo.
#   fast layers: terraform test (mocks) + Moto plan checks
#   the KMS mutation also needs the Moto apply checks (values known after apply)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
survived=0

mutate() {  # description, file, sed expression, [full]
  local work; work=$(mktemp -d)
  rsync -a --exclude .terraform --exclude '.git' "$root/" "$work/"
  sed -i.bak "$3" "$work/$2"
  if cmp -s "$work/$2" "$work/$2.bak"; then echo "BROKEN MUTATION (no change): $1"; survived=1; return; fi
  # A mutant that doesn't even validate would be "caught" for the wrong reason.
  if ! (cd "$work/modules/platform" && terraform init -backend=false -input=false >/dev/null && terraform validate >/dev/null 2>&1); then
    echo "BROKEN MUTATION (invalid config): $1"; survived=1; rm -rf "$work"; return
  fi
  local plan_only=1; [[ "${4:-}" == full ]] && plan_only=0
  if (cd "$work/modules/platform" && terraform test >/dev/null 2>&1) \
     && PLAN_ONLY=$plan_only "$work/tests/moto/run.sh" >/dev/null 2>&1; then
    echo "SURVIVED: $1"; survived=1
  else
    echo "caught:   $1"
  fi
  rm -rf "$work"
}

# Baseline: the unmutated copy must pass, or every "caught" below is meaningless.
base=$(mktemp -d); rsync -a --exclude .terraform --exclude .git "$root/" "$base/"
(cd "$base/modules/platform" && terraform init -backend=false -input=false >/dev/null && terraform test >/dev/null 2>&1) \
  && PLAN_ONLY=1 "$base/tests/moto/run.sh" >/dev/null 2>&1 \
  || { echo "baseline fails: fix the suite before mutating"; exit 2; }
rm -rf "$base"; echo "baseline: passes"

m=modules/platform/main.tf v=modules/platform/variables.tf
mutate "aws-auth ConfigMap allowed again"         $m 's/authentication_mode                      = "API"/authentication_mode = "API_AND_CONFIG_MAP"/'
mutate "Terraform identity becomes cluster-admin" $m 's/enable_cluster_creator_admin_permissions = false/enable_cluster_creator_admin_permissions = true/'
mutate "IMDSv1 allowed on nodes"                  $m 's/http_tokens                 = "required"/http_tokens = "optional"/'
mutate "public API endpoint by default"           $v '/variable "endpoint_public_access"/,/^}/ s/default     = false/default = true/'
mutate "0.0.0.0/0 accepted for the API"           $v 's/condition     = !contains(var.public_access_cidrs, "0.0.0.0\/0")/condition = length(var.public_access_cidrs) >= 0/'
mutate "prod shares one NAT gateway"              $m 's/single_nat_gateway  = false/single_nat_gateway  = true/'
mutate "prod drops scheduler/controller logs"     $m 's/log_types           = \["api", "audit", "authenticator", "controllerManager", "scheduler"\]/log_types = ["api", "audit", "authenticator"]/'
mutate "control plane logs unencrypted"           $m 's/cloudwatch_log_group_kms_key_id        = aws_kms_key.logs.arn/cloudwatch_log_group_kms_key_id = null/' full
exit $survived
