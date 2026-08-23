# Simulated SPIFFE claim for the demo agent. In a real deployment this
# would come from a workload identity issuer (e.g. SPIRE); here it's
# env-driven so the identity banner and every policy check/span agree.
import os
from dataclasses import dataclass

DEFAULT_SPIFFE_ID = "spiffe://homelab/deploy-bot"
DEFAULT_SPIFFE_SCOPE = "staging"


@dataclass(frozen=True)
class Identity:
    spiffe_id: str
    scope: str


def get_identity() -> Identity:
    return Identity(
        spiffe_id=os.environ.get("SPIFFE_ID", DEFAULT_SPIFFE_ID),
        scope=os.environ.get("SPIFFE_SCOPE", DEFAULT_SPIFFE_SCOPE),
    )
