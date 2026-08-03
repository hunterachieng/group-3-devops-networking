terraform {
  backend "s3" {
    bucket       = "devops-g3-tfstate-827478161993-uswest1"
    key          = "workload/lab/terraform.tfstate"
    region       = "us-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
