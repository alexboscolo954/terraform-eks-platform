#!/usr/bin/env bash
# Plan (dev + prod) and apply the network layer against Moto, then policy-check
# the plans with checkov. Never touches a real AWS account:
#  - credentials are fake and every AWS config/credential file is /dev/null;
#  - the provider only accepts Moto's account (allowed_account_ids).
set -euo pipefail
cd "$(dirname "$0")"
PORT=${MOTO_PORT:-5055}
PY=${PY:-python3}
CHECKOV=${CHECKOV:-checkov}
K8S=$(sed -n 's/.*default *= *"\(1\.[0-9]*\)".*/\1/p' ../../modules/platform/variables.tf | head -1)

unset AWS_PROFILE AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
export AWS_ENDPOINT_URL=http://127.0.0.1:$PORT

"$PY" server.py "$PORT" "$K8S" > moto.log 2>&1 & moto=$!
trap 'kill $moto 2>/dev/null; rm -rf .terraform terraform.tfstate* *.plan *.plan.json' EXIT
until curl -sf "$AWS_ENDPOINT_URL/moto-api/" >/dev/null; do sleep 0.5; done

skips() { python3 -c "import yaml,sys; print(','.join(yaml.safe_load(open('../../.checkov.yaml'))['skip-check']))" 2>/dev/null \
  || "$PY" -c "import yaml; print(','.join(yaml.safe_load(open('../../.checkov.yaml'))['skip-check']))"; }

terraform init -input=false -backend=false >/dev/null
for env in dev prod; do
  terraform plan -input=false -var environment=$env -out=$env.plan >/dev/null
  terraform show -json $env.plan > $env.plan.json
  echo "plan $env: $(python3 -c "import json,sys; print(sum(1 for r in json.load(open('$env.plan.json'))['resource_changes'] if r['change']['actions']==['create']))") resources to create"
  extra=()
  # dev trades a year of logs and the noisy controllerManager/scheduler logs for
  # cost, on purpose (modules/platform/main.tf profiles). prod gets no exemption.
  [[ $env == dev ]] && extra=(--skip-check "$(skips),CKV_AWS_338,CKV_AWS_37")
  "$PY" assert_plan.py $env.plan.json
  "$CHECKOV" -f $env.plan.json --config-file ../../.checkov.yaml ${extra[@]+"${extra[@]}"} --compact --quiet
done

[[ "${PLAN_ONLY:-}" == 1 ]] && exit 0

# Apply the network layer and the log groups for real against the Moto API,
# check what plans can't show, prove a re-plan is clean, then destroy.
for env in dev prod; do
  target=(-target=module.platform.module.vpc -target=module.platform.module.eks.aws_cloudwatch_log_group.this -var environment=$env)
  terraform apply -input=false -auto-approve "${target[@]}" >/dev/null
  echo "apply $env network + log groups: ok"
  "$PY" assert_applied.py $env
  terraform plan -input=false -detailed-exitcode "${target[@]}" >/dev/null && echo "re-plan $env: no changes (idempotent)"
  terraform destroy -input=false -auto-approve "${target[@]}" >/dev/null
  echo "destroy $env: ok"
done
