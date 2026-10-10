"""After the Moto apply: check, through the AWS API, what plan-time scanners
can't see because the values are only known after apply."""

import sys

import boto3

ENV = sys.argv[1]
NAME = f"moto-{ENV}"
RETENTION = {"dev": 30, "prod": 365}[ENV]
EXPECTED_NATS = {"dev": 1, "prod": 3}[ENV]

kw = {"region_name": "us-east-1"}  # endpoint comes from AWS_ENDPOINT_URL
ec2, logs, kms = boto3.client("ec2", **kw), boto3.client("logs", **kw), boto3.client("kms", **kw)
failures = []


def check(ok: bool, what: str) -> None:
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


vpc = ec2.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [NAME]}])["Vpcs"][0]["VpcId"]
keys = [kms.describe_key(KeyId=k["KeyId"])["KeyMetadata"] for k in kms.list_keys()["Keys"]]
logs_key = next(k for k in keys if k.get("Description") == f"{NAME} CloudWatch log encryption")
key_arn = logs_key["Arn"]
check(kms.get_key_rotation_status(KeyId=logs_key["KeyId"])["KeyRotationEnabled"], "logs CMK rotates")

flows = ec2.describe_flow_logs(Filters=[{"Name": "resource-id", "Values": [vpc]}])["FlowLogs"]
check(any(f["TrafficType"] == "ALL" and f["LogDestinationType"] == "cloud-watch-logs" for f in flows),
      "VPC has an ALL-traffic flow log to CloudWatch (CKV2_AWS_11)")

groups = {g["logGroupName"]: g for g in logs.describe_log_groups()["logGroups"]}
eks_group = groups.get(f"/aws/eks/{NAME}/cluster", {})
flow_groups = [g for n, g in groups.items() if "flow-log" in n]
for label, g in [("EKS control plane", eks_group), ("VPC flow", flow_groups[0] if flow_groups else {})]:
    check(g.get("kmsKeyId") == key_arn, f"{label} log group encrypted with the logs CMK (CKV_AWS_158)")
    check(g.get("retentionInDays") == RETENTION, f"{label} log group keeps {RETENTION} days")

nats = ec2.describe_nat_gateways(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NatGateways"]
subnets = {s["SubnetId"]: s for s in ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["Subnets"]}
check(len(nats) == EXPECTED_NATS, f"{EXPECTED_NATS} NAT gateway(s)")
check(len({subnets[n["SubnetId"]]["AvailabilityZone"] for n in nats}) == EXPECTED_NATS,
      "NAT gateways in distinct AZs")
check(all(n["NatGatewayAddresses"][0].get("AllocationId") for n in nats),
      "every NAT gateway has its Elastic IP (CKV2_AWS_19)")

private = [s for s in subnets.values() if any(t["Key"] == "kubernetes.io/role/internal-elb" for t in s.get("Tags", []))]
check(len(private) == 3 and not any(s["MapPublicIpOnLaunch"] for s in private),
      "3 private subnets, no public IPs on launch")

sys.exit(1 if failures else 0)
