"""Moto (local AWS API mock) for plan/apply tests, seeded like a real account.

Two gaps are filled, both read-only "catalog" APIs every AWS account sees:
- public SSM parameters with the latest EKS-optimized AMI release (Moto, like
  AWS, refuses writes under /aws/, so they go straight into its backend);
- eks:DescribeAddonVersions, which Moto doesn't implement. The add-on catalog
  below is a fixed stand-in so plans resolve; the versions are not real.

    python tests/moto/server.py 5055 1.37
"""

import sys
import time

from moto.core.responses import ActionResult
from moto.core.utils import utcnow
from moto.eks import urls as eks_urls
from moto.eks.responses import EKSResponse
from moto.server import ThreadedMotoServer
from moto.ssm.models import Parameter, ssm_backends

ACCOUNT, REGION = "123456789012", "us-east-1"


def seed(k8s_version: str) -> None:
    ssm = ssm_backends[ACCOUNT][REGION]
    for arch in ("x86_64", "arm64"):
        name = (f"/aws/service/eks/optimized-ami/{k8s_version}/amazon-linux-2023/"
                f"{arch}/standard/recommended/release_version")
        ssm._parameters[name].append(Parameter(
            account_id=ACCOUNT, name=name, value=f"{k8s_version}.0-20261001",
            parameter_type="String", description=None, allowed_pattern=None, keyid=None,
            last_modified_date=utcnow(), version=1, data_type="text",
        ))


ADDONS = ["coredns", "kube-proxy", "vpc-cni", "eks-pod-identity-agent", "aws-ebs-csi-driver"]


def describe_addon_versions(self: EKSResponse) -> ActionResult:
    name = self._get_param("addonName")
    k8s = self._get_param("kubernetesVersion") or "1.37"
    return ActionResult({"addons": [
        {"addonName": a, "type": "infra-management", "addonVersions": [{
            "addonVersion": "v1.0.0-eksbuild.1", "architecture": ["amd64", "arm64"],
            "compatibilities": [{"clusterVersion": k8s, "defaultVersion": True}],
        }]}
        for a in ADDONS if name in (None, a)
    ]})


def add_eks_addon_catalog() -> None:
    EKSResponse.describe_addon_versions = describe_addon_versions  # type: ignore[attr-defined]
    eks_urls.url_paths["{0}/addons/supported-versions$"] = eks_urls.response.dispatch


if __name__ == "__main__":
    port, version = int(sys.argv[1]), sys.argv[2]
    add_eks_addon_catalog()  # before the server builds its URL map
    server = ThreadedMotoServer(port=port, verbose=False)
    server.start()
    seed(version)
    print(f"moto ready on :{port}, seeded EKS {version} AMI parameters and add-on catalog", flush=True)
    while True:
        time.sleep(3600)
