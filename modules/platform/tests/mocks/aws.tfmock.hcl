# Mocked AWS for `terraform test`: no credentials, no network. Data sources
# and computed attributes get realistic shapes so the community modules plan.
mock_data "aws_availability_zones" {
  defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"], zone_ids = ["use1-az1", "use1-az2", "use1-az4"] }
}
mock_data "aws_caller_identity" {
  defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:role/ci", user_id = "AROAEXAMPLE" }
}
mock_data "aws_iam_session_context" {
  defaults = { issuer_arn = "arn:aws:iam::123456789012:role/ci" }
}
mock_data "aws_partition" {
  defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
}
mock_data "aws_region" {
  defaults = { region = "us-east-1", name = "us-east-1" }
}
mock_data "aws_iam_policy_document" {
  defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
mock_data "aws_eks_addon_version" {
  defaults = { version = "v1.0.0-eksbuild.1" }
}
mock_data "aws_ssm_parameter" {
  defaults = { value = "1.37.0-20261001", insecure_value = "1.37.0-20261001" }
}
mock_resource "aws_iam_role" {
  defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
}
mock_resource "aws_iam_policy" {
  defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
}
mock_resource "aws_kms_key" {
  defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
}
mock_resource "aws_eks_cluster" {
  defaults = {
    arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/mock"
    endpoint              = "https://mock.eks.amazonaws.com"
    certificate_authority = [{ data = "bW9jaw==" }]
    identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/MOCK" }] }]
  }
}
mock_resource "aws_cloudwatch_log_group" {
  defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock" }
}
mock_resource "aws_launch_template" {
  defaults = { id = "lt-0123456789abcdef0", arn = "arn:aws:ec2:us-east-1:123456789012:launch-template/lt-0123456789abcdef0", latest_version = 1 }
}
