# Assignment 1 Report

## Introduction

This assignment extends the pipeline built throughout the course into a full multi-environment deployment. The infrastructure is refactored into a reusable Terraform module, deployed across dev, staging, and prod environments with GitHub Environments providing approval gates. AWS credentials are scoped to environments using GitHub Environment secrets, and observability is added through SSM Parameter Store and CloudWatch alarms.

## OIDC Trust Policy for Production Environment

In a real AWS account (not AWS Academy), we would use OIDC federation instead of stored credentials. The following IAM trust policy JSON would be deployed for the production GitHub Actions role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:environment:prod"
        }
      }
    }
  ]
}
```

### Condition-by-Condition Explanation

1. **`token.actions.githubusercontent.com:aud = "sts.amazonaws.com"`** - This ensures the OIDC token is intended for AWS STS. Without this, a token issued for a different audience (e.g., another cloud provider) could be used to assume this role.

2. **`token.actions.githubusercontent.com:sub = "repo:OWNER/REPO:environment:prod"`** - This is the critical security control. It scopes the trust to:
   - A specific repository (`OWNER/REPO`)
   - A specific GitHub Environment (`prod`)
   
   This prevents:
   - **Cross-repository attacks**: A compromised workflow in another repository cannot assume this role, even if they know the role ARN.
   - **Branch/tag spoofing**: Only workflows running in the `prod` environment can assume the role. A workflow triggered from a feature branch or fork cannot assume the prod role.
   - **Lateral movement**: If an attacker gains push access to the repository, they still cannot deploy to prod without the required reviewer approval (which gates the environment).

   Contrast with a loose wildcard like `repo:OWNER/REPO:*` - that would allow ANY workflow in the repository (including those from forks, feature branches, or compromised PRs) to assume the production role. The environment-scoped sub is what enforces the "human in front of production" requirement.

### Why This Was Not Deployed

AWS Academy denies the IAM permissions required to create OIDC identity providers (`iam:CreateOpenIDConnectProvider`) and roles (`iam:CreateRole`). The course uses session-scoped credentials via `refresh-gha-creds.sh` as an Academy-compatible substitute. In a real account, this trust policy would be applied via Terraform or CloudFormation during initial account setup.

## SSM Parameter Store Pre-Step

The following command was run once, out-of-band, to create the application parameter that Terraform reads via a data source:

```bash
aws ssm put-parameter   --name "/acs730/a1/db_password"   --value "placeholder-db-password-123"   --type "SecureString"   --region us-east-1
```

This is documented as a pre-step because Terraform must not both create and read the same parameter (circular dependency). The parameter is created once by hand; Terraform then reads it with `data "aws_ssm_parameter"` in every environment.

## CloudWatch Alarm

A CloudWatch alarm is defined in the Terraform module on the `CPUUtilization` metric of the web server instances. This metric produces datapoints even on idle instances, ensuring the alarm can be evaluated.

```hcl
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.name}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Triggers when average CPU exceeds 80% for 2 periods"
  
  dimensions = {
    InstanceId = aws_instance.web[0].id
  }
  
  alarm_actions = []
  ok_actions    = []
}
```

The alarm is given evaluation periods to collect datapoints before evidence capture, avoiding the `INSUFFICIENT_DATA` state.

## Recommendation: GitHub Actions vs AWS-Native Pipeline

**Recommendation: GitHub Actions**

For a team fully committed to AWS with no multi-cloud plans, I would still recommend GitHub Actions over an AWS-native pipeline (CodePipeline/CodeBuild) for the following concrete factors:

1. **Identity and OIDC Integration**: GitHub Actions has first-class OIDC support with AWS. The identity lives in GitHub (where the code and workflows live), and the trust policy can be scoped to specific environments (`repo:OWNER/REPO:environment:prod`). CodePipeline requires an IAM role for the pipeline itself and additional setup for cross-account or cross-environment deployments. With GitHub Actions, the same identity model works across all environments with just environment-scoped conditions.

2. **Runner Cost and Maintenance**: GitHub-hosted runners are free for public repositories and included in GitHub plans. AWS CodeBuild charges per build minute ($0.005/min for Linux), and self-hosted CodeBuild agents require patching and maintenance. For a team already paying for GitHub, the marginal cost of Actions is zero. The "who patches it" factor favors GitHub - Microsoft handles runner OS updates, while self-hosted CodeBuild fleets require dedicated maintenance.

3. **Team Familiarity and Developer Experience**: The team already knows GitHub - PR checks, required status checks, branch protection rules, and environment approvals are all native GitHub concepts. Moving to CodePipeline introduces a new UI, new YAML schema (or JSON), and a separate approval model. The day you need VPC-internal access (e.g., deploying to private subnets), GitHub Actions self-hosted runners in your VPC work identically to the current setup; CodePipeline requires VPC endpoints and additional networking configuration.

4. **Ecosystem and Reusability**: The GitHub Actions marketplace has thousands of pre-built actions (Terraform, Docker, security scanning, notifications). CodePipeline has fewer integrations and often requires custom Lambda functions or CodeBuild projects for the same tasks. The Terraform `hashicorp/setup-terraform` action handles version pinning, caching, and CLI installation automatically.

The "industry standard" argument is not a factor - both are widely used. The decision rests on where identity lives (GitHub), what the team already knows (GitHub), and what breaks when you need VPC-internal access (both work, but GitHub Actions requires less new infrastructure).

## Conclusion

This assignment demonstrated a complete multi-environment deployment pipeline with:
- A reusable Terraform module parameterized for dev, staging, and prod
- Independent state files per environment via S3 backend keys
- GitHub Environments with automatic staging deployment and manual prod approval
- Environment-scoped AWS credentials eliminating repository-level secrets
- Real deployment through the pipeline with evidence capture
- Application configuration via SSM Parameter Store (read-only data source)
- CloudWatch alarm on a real metric with proper evaluation periods
- Documented OIDC trust policy for production-grade identity federation
- A justified recommendation for GitHub Actions over AWS-native pipelines

All infrastructure was destroyed after validation to respect the $50 term budget.
