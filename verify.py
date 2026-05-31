"""Print counts of the Security objects loaded on the demo branch."""
import os
import toml
from infrahub_sdk import InfrahubClientSync, Config

cfg = toml.load(os.environ["INFRAHUBCTL_CONFIG"])
client = InfrahubClientSync(config=Config(address=cfg["server_address"], api_token=cfg["api_token"]))
branch = os.environ.get("INFRAHUB_BRANCH", "fw-cicd-demo")

for kind in [
    "SecurityZone", "SecurityIPAddress", "SecurityService",
    "SecurityPolicy", "SecurityPolicyRule", "SecurityFirewall",
]:
    print(f"{kind}: {len(client.all(kind, branch=branch))}")
