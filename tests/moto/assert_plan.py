"""Platform guarantees checked on the resolved plan (Moto), beyond checkov's
generic rules. Usage: assert_plan.py <plan.json>"""

import json
import sys


def resources(module: dict) -> list[dict]:
    out = list(module.get("resources", []))
    for child in module.get("child_modules", []):
        out += resources(child)
    return out


plan = json.load(open(sys.argv[1]))
rs = resources(plan["planned_values"]["root_module"])
by_type: dict[str, list[dict]] = {}
for r in rs:
    by_type.setdefault(r["type"], []).append(r.get("values", {}))
failures = []


def check(ok: bool, what: str) -> None:
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


cluster = by_type["aws_eks_cluster"][0]
vpc_cfg, access = cluster["vpc_config"][0], cluster["access_config"][0]
check(vpc_cfg["endpoint_private_access"] and not vpc_cfg["endpoint_public_access"],
      "API endpoint is private only")
check(access["authentication_mode"] == "API", "access entries only (no aws-auth ConfigMap)")
check(access["bootstrap_cluster_creator_admin_permissions"] is False,
      "Terraform identity is not made cluster-admin")
check(cluster["encryption_config"][0]["resources"] == ["secrets"], "secrets envelope encryption")

for lt in by_type["aws_launch_template"]:
    md = lt["metadata_options"][0]
    check(md["http_tokens"] == "required" and md["http_put_response_hop_limit"] == 1,
          "nodes: IMDSv2 required, hop limit 1")
for ng in by_type["aws_eks_node_group"]:
    check(ng["ami_type"].startswith(("AL2023", "BOTTLEROCKET")), f"nodes: current AMI family ({ng['ami_type']})")

addons = {a["addon_name"] for a in by_type.get("aws_eks_addon", [])}
check({"vpc-cni", "coredns", "kube-proxy", "eks-pod-identity-agent", "aws-ebs-csi-driver"} <= addons,
      "core add-ons managed by EKS")
pia = [p for p in by_type.get("aws_eks_pod_identity_association", [])] + [
    a for a in by_type.get("aws_eks_addon", []) if a.get("pod_identity_association")]
check(bool(pia), "EBS CSI driver uses Pod Identity")

sys.exit(1 if failures else 0)
