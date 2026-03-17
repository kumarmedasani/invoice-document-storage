"""
Invoice Document Storage - AWS Network Architecture Diagram
Generates a PNG diagram using official AWS icons via the 'diagrams' library.

Layout: LR linear flow. Two-bucket design (landing zone + documents).
  External → SFTP → Landing Bucket → Lambda → Documents Bucket + Aurora
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.network import VPCFlowLogs, Endpoint
from diagrams.aws.database import Aurora, RDS
from diagrams.aws.storage import S3
from diagrams.aws.security import KMS, SecretsManager
from diagrams.aws.management import Cloudwatch
from diagrams.aws.integration import SNS
from diagrams.aws.compute import Lambda
from diagrams.aws.migration import TransferForSftp
from diagrams.aws.general import Users

graph_attr = {
    "fontsize": "18",
    "bgcolor": "white",
    "pad": "0.6",
    "ranksep": "1.6",
    "nodesep": "0.8",
    "splines": "spline",
}

with Diagram(
    "Invoice Document Storage - AWS Network Architecture",
    filename="/home/user/invoice-document-storage/docs/diagrams/network_architecture",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    outformat="png",
):

    # ── External ─────────────────────────────────────────────────
    vendors = Users("Vendors\n(SFTP)")
    on_prem = Users("On-Premises\nLegacy Server")

    with Cluster("AWS Cloud"):

        # ── Ingestion entry point ────────────────────────────────
        sftp = TransferForSftp("Transfer Family\n(SFTP)")

        # ── Landing Zone ─────────────────────────────────────────
        with Cluster("Landing Zone  (SSE-KMS, 7-day expiry)"):
            s3_landing = S3("invoice-landing-{env}")

        # ── Documents Bucket ─────────────────────────────────────
        with Cluster("Document Storage  (SSE-KMS, 10-year lifecycle)"):
            s3_docs = S3("invoice-docs-{env}")
            s3_logs = S3("Access Logs")

        # ── VPC ──────────────────────────────────────────────────
        with Cluster("VPC  (10.x.0.0/16)  —  No internet egress"):

            with Cluster("App Subnets (private)"):
                app_lambda = Lambda("Ingestion\nLambda")
                ep_group = Endpoint("VPC Endpoints\nS3-GW | SM | KMS\nCW-Logs | CW-Mon | STS")

            with Cluster("Data Subnets (private)"):
                rds_proxy = RDS("RDS Proxy")
                aurora_w = Aurora("Aurora\nWriter")
                aurora_r = Aurora("Aurora\nReader")

            flow_logs = VPCFlowLogs("Flow Logs")

        # ── Supporting services ──────────────────────────────────
        with Cluster("Regional Services"):
            cw = Cloudwatch("CloudWatch")
            sns = SNS("SNS Alerts")
            kms = KMS("KMS")
            sm = SecretsManager("Secrets Mgr")

    # ════════════════════════════════════════════════════════════
    #  Edges — left-to-right main flow, no circular routes
    # ════════════════════════════════════════════════════════════

    # Vendor → SFTP → Landing Zone
    vendors >> Edge(label="SFTP", color="darkgreen", style="bold") >> sftp
    on_prem >> Edge(label="DataSync", color="orange", style="bold") >> sftp
    sftp >> Edge(label="ZIP / PDF", color="darkorange", style="bold") >> s3_landing

    # Landing Zone → Lambda (S3 event trigger)
    s3_landing >> Edge(label="S3 Event → SNS\n→ Lambda", color="darkgreen", style="bold") >> app_lambda

    # Lambda → Documents Bucket (extracted files)
    app_lambda >> Edge(label="Extracted\nfiles", color="darkorange", style="bold") >> s3_docs

    # Lambda → Aurora via RDS Proxy
    app_lambda >> Edge(label="5432/TLS", color="purple", style="bold") >> rds_proxy
    rds_proxy >> Edge(color="purple") >> aurora_w
    aurora_w >> Edge(label="Replication", color="gray", style="dashed") >> aurora_r

    # S3 access logs
    s3_docs >> Edge(color="gray", style="dashed") >> s3_logs

    # Monitoring (CW → SNS only; Flow Logs → CW implied by VPC placement)
    cw >> Edge(label="Alarms", color="firebrick") >> sns
