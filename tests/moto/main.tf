# Root config used only against Moto (tests/moto/run.sh). The provider can only
# talk to Moto's fake account: anything else is refused by allowed_account_ids.
variable "environment" {
  type = string
}

provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = ["123456789012"]
}

module "platform" {
  source          = "../../modules/platform"
  name            = "moto-${var.environment}"
  environment     = var.environment
  admin_role_arns = ["arn:aws:iam::123456789012:role/platform-admins"]
}
