# TODO(registry): extract when team size > 5

# DECISION: KMS key policy grants full admin to the root account principal.
# This delegates KMS permission control to IAM policies (attached to each role),
# breaking the circular dependency between KMS and IAM modules. Each role's IAM
# policy explicitly grants kms:GenerateDataKey, kms:Decrypt, kms:DescribeKey on
# this key's ARN.

resource "aws_kms_key" "main" {
  description             = "Encryption key for invoice document storage - ${var.env}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "invoice-key-policy-${var.env}"
    Statement = [
      {
        Sid    = "RootAccountAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AuroraCreateGrant"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant"
        ]
        Resource = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # DECISION: MFA-equivalent via explicit deny on ScheduleKeyDeletion
        # KMS does not support MFA Delete natively. This deny prevents
        # non-root principals from scheduling key deletion.
        Sid    = "DenyKeyDeletionByNonRoot"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "kms:ScheduleKeyDeletion"
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = "arn:aws:iam::${var.aws_account_id}:root"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "invoice-kms-${var.env}"
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/invoice-${var.env}"
  target_key_id = aws_kms_key.main.key_id
}
