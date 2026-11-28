terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  backend "s3" {
    bucket       = "acs730-tfstate-305951028316"
    key          = "assignment1/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

module "infrastructure" {
  source = "../modules/infrastructure"

  environment            = "prod"
  owner                  = "amibifa"
  vpc_cidr               = "10.42.0.0/16"
  instance_count         = 1
  instance_type          = "t3.micro"
  create_artifact_bucket = false
}
