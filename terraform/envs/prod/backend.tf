# Backend bucket name is set via -backend-config="bucket=invoice-tfstate-<ACCOUNT_ID>"
# during terraform init. See docs/DEPLOYMENT.md for setup instructions.
terraform {
  backend "s3" {
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "invoice-tfstate-lock"
    encrypt        = true
  }
}
