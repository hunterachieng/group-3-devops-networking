terraform {
  backend "s3" {
    bucket       = "devops-g3-tfstate-240462142849-uswest1"
    key          = "workload/lab/terraform.tfstate"
    region       = "us-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
