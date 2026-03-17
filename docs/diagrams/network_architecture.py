"""
Invoice Document Storage - AWS Network Architecture Diagram
Generates a PNG diagram using official AWS icons via the 'diagrams' library.
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.network import (
    VPC, PrivateSubnet, PublicSubnet, NATGateway,
    InternetGateway, VPCFlowLogs, Endpoint
)
from diagrams.aws.database import Aurora, RDS
from diagrams.aws.storage import S3
from diagrams.aws.security import KMS, IAM, SecretsManager
from diagrams.aws.management import Cloudwatch
from diagrams.aws.integration import SNS
from diagrams.aws.compute import Lambda
from diagrams.aws.general import Users
from diagrams.onprem.network import Internet

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.5",
    "ranksep": "1.2",
    "nodesep": "0.8",
}

with Diagram(
    "Invoice Document Storage - AWS Network Architecture",
    filename="/home/user/invoice-document-storage/docs/diagrams/network_architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    outformat="png",
):
    # External
    on_prem = Users("On-Premises\nLegacy Server")
    internet = Internet("Internet")

    with Cluster("AWS Cloud"):

        # Global / Regional Services (outside VPC)
        with Cluster("Regional Services"):
            kms = KMS("KMS\nEnvelope Encryption")
            iam = IAM("IAM Roles\n& Policies")
            sns = SNS("SNS\nAlert Topics")
            cw = Cloudwatch("CloudWatch\nMetrics & Alarms")

        with Cluster("VPC - invoice-vpc (10.x.0.0/16)"):

            flow_logs = VPCFlowLogs("VPC Flow Logs")

            # Internet Gateway
            igw = InternetGateway("Internet\nGateway")

            # Public NAT Subnets
            with Cluster("Public Subnets (NAT only)\n10.x.100.0/28 per AZ"):
                nat_a = NATGateway("NAT GW\nAZ-a")
                nat_b = NATGateway("NAT GW\nAZ-b")

            # App Subnets
            with Cluster("Private App Subnets\n10.x.1.0/24, 10.x.2.0/24, 10.x.3.0/24"):
                app_lambda = Lambda("Application\n(Lambda / ECS)")

                with Cluster("VPC Interface Endpoints"):
                    ep_sm = Endpoint("Secrets\nManager")
                    ep_kms = Endpoint("KMS")
                    ep_cw = Endpoint("CloudWatch\nLogs")
                    ep_mon = Endpoint("CloudWatch\nMonitoring")

            # Data Subnets
            with Cluster("Private Data Subnets\n10.x.11.0/24, 10.x.12.0/24, 10.x.13.0/24"):
                aurora_primary = Aurora("Aurora PostgreSQL\nWriter (Primary)")
                aurora_reader = Aurora("Aurora PostgreSQL\nReader (Replica)")
                rds_proxy = RDS("RDS Proxy\n(Stage/Prod)")

            # S3 Gateway Endpoint
            s3_ep = Endpoint("S3 Gateway\nEndpoint")

        # S3 (outside VPC, accessed via endpoint)
        with Cluster("S3 Storage"):
            s3_docs = S3("invoice-docs-{env}\nDocument PDFs")
            s3_logs = S3("invoice-docs-{env}\n-access-logs")

    # --- Connections ---

    # External connectivity
    on_prem >> Edge(label="DataSync /\nETL Migration", color="orange", style="bold") >> internet
    internet >> Edge(color="darkgreen") >> igw

    # NAT Gateway flow
    igw >> Edge(color="darkgreen") >> nat_a
    igw >> Edge(color="darkgreen") >> nat_b

    # App to NAT (outbound internet)
    app_lambda >> Edge(label="Outbound\nHTTPS", color="blue", style="dashed") >> nat_a

    # App to Aurora via RDS Proxy
    app_lambda >> Edge(label="Port 5432\n(TLS required)", color="purple", style="bold") >> rds_proxy
    rds_proxy >> Edge(color="purple") >> aurora_primary
    aurora_primary >> Edge(label="Replication", color="gray", style="dashed") >> aurora_reader

    # App to S3 via Gateway Endpoint
    app_lambda >> Edge(label="S3 API\n(Gateway EP)", color="darkorange", style="bold") >> s3_ep
    s3_ep >> Edge(color="darkorange") >> s3_docs
    s3_docs >> Edge(label="Access Logs", color="gray", style="dashed") >> s3_logs

    # VPC Endpoints to regional services
    ep_sm >> Edge(color="gray", style="dotted") >> SecretsManager("Secrets\nManager")
    ep_kms >> Edge(color="gray", style="dotted") >> kms
    ep_cw >> Edge(color="gray", style="dotted") >> cw
    ep_mon >> Edge(color="gray", style="dotted") >> cw

    # Monitoring
    flow_logs >> Edge(color="red", style="dashed") >> cw
    aurora_primary >> Edge(label="PG Logs &\nMetrics", color="red", style="dashed") >> cw
    cw >> Edge(label="Alarms", color="red") >> sns

    # Encryption
    aurora_primary >> Edge(color="gold", style="dotted", label="Encryption") >> kms
    s3_docs >> Edge(color="gold", style="dotted", label="SSE-KMS") >> kms
