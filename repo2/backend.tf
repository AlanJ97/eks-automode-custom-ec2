terraform {
  backend "s3" {
    bucket = "eks-auto-mode-c7i-xlarge-tfstate-alann"
    key    = "repo2/terraform-custom-automode.tfstate"
    region = "us-west-1"
  }
}
