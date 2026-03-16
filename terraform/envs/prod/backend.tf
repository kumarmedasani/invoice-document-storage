terraform {
  backend "s3" {
    bucket         = "invoice-tfstate-123456789012"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "invoice-tfstate-lock"
    encrypt        = true
  }
}
