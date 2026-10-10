# terraform-eks-platform

[![ci](https://github.com/alexboscolo954/terraform-eks-platform/actions/workflows/ci.yaml/badge.svg)](https://github.com/alexboscolo954/terraform-eks-platform/actions/workflows/ci.yaml)

An opinionated Amazon EKS platform module: a VPC and an EKS cluster with secure defaults, input guardrails, and dev/prod profiles. It's built on the community [`terraform-aws-modules/vpc`](https://github.com/terraform-aws-modules/terraform-aws-vpc) and [`eks`](https://github.com/terraform-aws-modules/terraform-aws-eks) modules.

**It's tested without an AWS account.** It has never been applied to real AWS. Instead, four layers check different things:

| Layer | Tooling | What it proves |
|---|---|---|
| Guardrails and profiles | `terraform test` with mocked providers (14 runs) | Bad inputs are rejected before anything reaches AWS. dev and prod build what they should (NAT count, subnet math, access entries). |
| Resolved-plan policy | Plans against [Moto](https://github.com/getmoto/moto) (a local AWS API), then checkov and platform checks | Security settings **as the community modules actually resolve them**, not as the HCL suggests: private endpoint, IMDSv2, encryption, logs |
| Real API round-trip | Apply, re-plan and destroy of the network layer and log groups on Moto, then checks through the AWS API | What plans can't show (KMS on log groups, flow logs, NAT per AZ). A second plan shows no changes. |
| Tests for the tests | `tests/mutate.sh` | Eight guarantees are removed one at a time, and some layer must fail each time |

## What you get

| | dev | prod |
|---|---|---|
| AZs / private subnets | 3 (2 possible) | 3 |
| NAT gateways | 1 shared (cheaper) | 1 per AZ (egress survives an AZ outage) |
| Control plane logs | api, audit, authenticator | All 5 log types |
| Log retention (control plane and VPC flow logs) | 30 days | 365 days |
| Deletion protection | off | on |
| Nodes (min / desired / max) | 1 / 2 / 3 | 3 / 3 / 10 |

Both profiles also include:
- **A private API endpoint.** A public one needs explicit CIDRs and never allows `0.0.0.0/0`.
- **Access entries only** (`authentication_mode = API`): no aws-auth ConfigMap. The Terraform identity is **not** made cluster-admin; admins are explicit IAM roles.
- **Secrets envelope encryption** (KMS). Control-plane and VPC flow logs are encrypted with a rotating CMK.
- **Nodes:** AL2023, **IMDSv2 required with hop limit 1** (pods can't borrow the node's role), private subnets only.
- **EKS-managed add-ons:** vpc-cni and pod-identity-agent (installed before nodes), coredns, kube-proxy, and the EBS CSI driver on **Pod Identity** (no IRSA trust policies).
- Subnets tagged for the AWS Load Balancer Controller, and VPC flow logs on all traffic.
- **Kubernetes 1.37**, with validation that only accepts versions in EKS **standard** support. Extended support costs extra per cluster-hour.

## Usage

```hcl
module "platform" {
  source          = "github.com/alexboscolo954/terraform-eks-platform//modules/platform"
  name            = "platform-prod"
  environment     = "prod"
  admin_role_arns = ["arn:aws:iam::111111111111:role/platform-admins"]
}
```

[`envs/dev`](envs/dev) and [`envs/prod`](envs/prod) are ready-made roots. They use an S3 backend with native locking (`use_lockfile`, no DynamoDB table) and `allowed_account_ids`, so a wrong AWS profile fails instead of deploying into the wrong account.

## Testing

```bash
make lint     # fmt, validate, tflint (AWS ruleset)
make test     # terraform test, mocked AWS
make moto     # needs: pip install -r requirements-test.txt
make mutate   # about 8 min
```

### Guardrails (`terraform test`)

```
run "defaults_are_accepted"... pass
run "public_endpoint_needs_cidrs"... pass
run "public_endpoint_never_open_to_the_internet"... pass
run "public_endpoint_with_office_cidr_is_fine"... pass
run "single_az_is_rejected"... pass
run "unknown_environment_is_rejected"... pass
run "tiny_vpc_is_rejected"... pass
run "patch_version_is_rejected"... pass
run "extended_support_version_is_rejected"... pass
run "admin_must_be_a_role_arn"... pass
run "bad_name_is_rejected"... pass
run "dev_profile"... pass
run "prod_profile"... pass
run "two_az_dev"... pass
```

### Moto

[`tests/moto/run.sh`](tests/moto/run.sh) starts Moto and plans both environments (74 and 82 resources). It then runs [checkov](https://www.checkov.io/) and [`assert_plan.py`](tests/moto/assert_plan.py) on the **resolved** plan JSON. Then it applies the network layer and log groups, checks the result through the AWS API ([`assert_applied.py`](tests/moto/assert_applied.py)), re-plans with `-detailed-exitcode`, and destroys.

```
plan prod: 82 resources to create
ok   API endpoint is private only
ok   access entries only (no aws-auth ConfigMap)
ok   Terraform identity is not made cluster-admin
ok   secrets envelope encryption
ok   nodes: IMDSv2 required, hop limit 1
...
Passed checks: 166, Failed checks: 0
apply prod network + log groups: ok
ok   EKS control plane log group encrypted with the logs CMK (CKV_AWS_158)
ok   VPC has an ALL-traffic flow log to CloudWatch (CKV2_AWS_11)
ok   3 NAT gateway(s)
ok   NAT gateways in distinct AZs
re-plan prod: no changes (idempotent)
destroy prod: ok
```

Each checkov skip in [`.checkov.yaml`](.checkov.yaml) has a written reason. The two that fire only because values are "known after apply" (log group KMS, flow logs) are **checked after the Moto apply** instead. `CKV_AWS_339` is skipped because checkov 3.3.26 still thinks 1.35 is the newest EKS version. The module's own version validation, which follows the AWS calendar, replaces it. dev is exempt from two cost-related checks (one-year retention, all log types). prod isn't exempt from either.

Moto is missing two read-only "catalog" APIs that every AWS account has. [`tests/moto/server.py`](tests/moto/server.py) fills them: the public SSM parameter with the EKS-optimized AMI release, and `eks:DescribeAddonVersions`, served with fixed stand-in versions.

**Safety:** the tests use fake credentials, set every AWS config and credentials file to `/dev/null`, and set `allowed_account_ids` to Moto's account. With a real profile on the machine, they still can't touch it.

### Mutations

```
baseline: passes
caught:   aws-auth ConfigMap allowed again
caught:   Terraform identity becomes cluster-admin
caught:   IMDSv1 allowed on nodes
caught:   public API endpoint by default
caught:   0.0.0.0/0 accepted for the API
caught:   prod shares one NAT gateway
caught:   prod drops scheduler/controller logs
caught:   control plane logs unencrypted
```

## Limits

- **Not applied to real AWS.** Moto can't run an EKS control plane or nodes, and it doesn't implement add-ons, access entries or Pod Identity at apply time. Those are covered by mocked `terraform test` and plan checks only. The first real `apply` is still the moment of truth, so start with `envs/dev`.
- The add-on versions in the Moto harness are stand-ins. Real versions come from `DescribeAddonVersions` in your account (`most_recent = true`).
- No cost figures: they depend on region, instance types and traffic.

## Design notes

- **Wrap the community modules, don't fork them.** They're maintained by people who track every EKS API change. This repo owns the *decisions* (defaults, guardrails, profiles) and pins exact module versions.
- **Two profiles, not dozens of knobs.** Every variable is a way to drift from the secure baseline. The few inputs that exist are validated.
- **Pod Identity over IRSA** for AWS access from pods: no per-cluster OIDC trust policies to maintain.

## License

MIT
