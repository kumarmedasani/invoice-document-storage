# Architecture

## Environment Topology

Each environment (QA, Stage, Prod) follows the same topology with differences
in scale (AZ count, NAT gateways, instance sizes).

```mermaid
graph TD
    subgraph VPC["VPC (10.x0.0.0/16)"]
        subgraph AppSubnets["App Subnets (Private)"]
            AZa_App["AZ-a: App Subnet"]
            AZb_App["AZ-b: App Subnet"]
            AZc_App["AZ-c: App Subnet (Prod only)"]
            Lambda["Lambda / ECS<br/>Ingestion Service"]
        end
        subgraph DataSubnets["Data Subnets (Private, No Internet)"]
            AZa_Data["AZ-a: Data Subnet"]
            AZb_Data["AZ-b: Data Subnet"]
            AZc_Data["AZ-c: Data Subnet (Prod only)"]
            Aurora["Aurora PostgreSQL<br/>Cluster"]
            Proxy["RDS Proxy<br/>(Stage/Prod)"]
        end
        subgraph Endpoints["VPC Endpoints"]
            S3EP["S3 Gateway Endpoint"]
            SMEP["Secrets Manager<br/>Interface Endpoint"]
            KMSEP["KMS Interface Endpoint"]
            CWEP["CloudWatch / Logs<br/>Interface Endpoints"]
        end
        NAT["NAT Gateway<br/>(Stage: 1, Prod: per-AZ)"]
    end

    Lambda --> S3EP
    Lambda --> SMEP
    Lambda --> KMSEP
    Lambda --> Proxy
    Proxy --> Aurora
    Lambda --> CWEP
    NAT --> IGW["Internet Gateway"]

    style VPC fill:#f0f8ff,stroke:#4a90d9
    style AppSubnets fill:#e8f5e9,stroke:#66bb6a
    style DataSubnets fill:#fff3e0,stroke:#ffa726
    style Endpoints fill:#f3e5f5,stroke:#ab47bc
```

### Environment Differences

| Component | QA | Stage | Prod |
|---|---|---|---|
| VPC CIDR | 10.10.0.0/16 | 10.20.0.0/16 | 10.30.0.0/16 |
| Availability Zones | 2 | 2 | 3 |
| NAT Gateways | 0 | 1 (shared) | 3 (one per AZ) |
| Aurora Instances | 1x db.t4g.medium | 2x db.t4g.large | 2x db.r8g.large |
| RDS Proxy | No | Yes | Yes |
| S3 Object Lock | No | No | Yes (GOVERNANCE) |
| Performance Insights | No | Yes | Yes |
| Log Retention | 90 days | 90 days | 365 days |
| Backup Retention | 7 days | 14 days | 35 days |

## Ingestion Data Flow

```mermaid
sequenceDiagram
    participant Src as Source System
    participant Svc as Ingestion Service<br/>(Lambda/ECS)
    participant SM as Secrets Manager
    participant KMS as KMS
    participant S3 as S3 Bucket
    participant SNS as SNS Topic
    participant DB as Aurora PostgreSQL<br/>(via RDS Proxy)

    Src->>Svc: Document (PDF) + Metadata
    Svc->>SM: GetSecretValue (DB credentials)
    SM-->>Svc: Credentials
    Svc->>KMS: GenerateDataKey
    KMS-->>Svc: Data Key
    Svc->>S3: PutObject (SSE-KMS)<br/>{source}/{year}/{month}/{account}/{uuid}.pdf
    S3-->>Svc: PutObject Response (VersionId)
    S3->>SNS: s3:ObjectCreated event
    Svc->>DB: INSERT document + details<br/>(via RDS Proxy in Stage/Prod)
    DB-->>Svc: Confirmation
```

## S3 Storage Tier Lifecycle

```mermaid
graph LR
    A["S3 Standard<br/>Day 0-730<br/>(Hot Storage, 2 years)"] -->|Day 731| B["Glacier Flexible Retrieval<br/>Day 731-2555<br/>(2-7 years)"]
    B -->|Day 2556| C["Glacier Deep Archive<br/>Day 2556-3649<br/>(7-10 years)"]
    C -->|Day 3650| D["Expired / Deleted<br/>(After 10 years)"]

    style A fill:#4caf50,color:#fff
    style B fill:#2196f3,color:#fff
    style C fill:#673ab7,color:#fff
    style D fill:#f44336,color:#fff
```

### Noncurrent Version Lifecycle

| Days After Becoming Noncurrent | Action |
|---|---|
| 30 | Transition to Glacier Instant Retrieval |
| 365 | Expire (delete) |

Incomplete multipart uploads are aborted after 7 days.

## Backup and Recovery Flow

```mermaid
graph TD
    subgraph Aurora["Aurora PostgreSQL"]
        CB["Continuous Backup<br/>(RPO: ~1 hour)"]
        FS["Final Snapshot<br/>(on deletion)"]
    end

    subgraph Recovery["Recovery Procedures"]
        PITR["Point-in-Time Restore<br/>(RTO: ~4 hours)"]
        NewCluster["New Aurora Cluster"]
        UpdateProxy["Update RDS Proxy Target"]
        UpdateSecrets["Update Secrets Manager"]
    end

    subgraph S3Recovery["S3 Recovery"]
        Versioning["S3 Versioning"]
        RestoreVersion["Restore Noncurrent Version"]
        GlacierRestore["Glacier Restore Request"]
    end

    CB --> PITR
    PITR --> NewCluster
    NewCluster --> UpdateProxy
    NewCluster --> UpdateSecrets

    Versioning --> RestoreVersion
    GlacierRestore --> RestoreVersion
```

## Security Boundary Diagram

```mermaid
graph TD
    subgraph KMSBoundary["KMS Encryption Boundary"]
        KMSKey["KMS Key<br/>(per environment)"]
        KMSKey --> S3Enc["S3 SSE-KMS<br/>(bucket_key_enabled)"]
        KMSKey --> AuroraEnc["Aurora Storage<br/>Encryption"]
        KMSKey --> SecretsEnc["Secrets Manager<br/>Encryption"]
        KMSKey --> LogsEnc["CloudWatch Logs<br/>Encryption"]
        KMSKey --> PIEnc["Performance Insights<br/>Encryption"]
    end

    subgraph IAMBoundary["IAM Role Boundaries"]
        LambdaRole["Lambda Ingestion Role"]
        ECSRole["ECS Ingestion Role"]
        MigrationRole["Migration Role"]

        LambdaRole --> S3Access["S3: Put/Get/List"]
        LambdaRole --> KMSAccess["KMS: GenerateDataKey/Decrypt"]
        LambdaRole --> SMAccess["Secrets Manager: GetSecretValue"]
        LambdaRole --> CWAccess["CloudWatch: Log Write"]

        ECSRole --> S3Access
        ECSRole --> KMSAccess
        ECSRole --> SMAccess
        ECSRole --> CWAccess

        MigrationRole --> S3MigAccess["S3: Put/Get/List"]
        MigrationRole --> KMSMigAccess["KMS: GenerateDataKey/Decrypt"]
    end

    subgraph NetworkBoundary["Network Isolation"]
        AppSG["SG: App Tier<br/>Egress: 443, 5432"]
        AuroraSG["SG: Aurora<br/>Ingress: 5432 from App only"]
        VPCESG["SG: VPC Endpoints<br/>Ingress: 443 from App CIDRs"]
        DataSubnet["Data Subnets<br/>No internet egress"]
    end

    style KMSBoundary fill:#fff3e0,stroke:#ff9800
    style IAMBoundary fill:#e8f5e9,stroke:#4caf50
    style NetworkBoundary fill:#e3f2fd,stroke:#2196f3
```
