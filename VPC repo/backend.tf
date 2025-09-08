terraform {
  backend "s3" {
    bucket = "eks-auto-mode-c7i-xlarge-tfstate-alann" # Make sure this bucket exists and is unique.
    key    = "vpc/terraform-vpc.tfstate"
    region = "us-west-1"
  }
}
