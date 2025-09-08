terraform {
  backend "s3" {
    bucket = "eks-auto-mode-c7i-xlarge-tfstate-alann" # Make sure this bucket exists and is unique.
    key    = "repo1/terraform-ekscluster.tfstate"
    region = "us-west-1"
  }
}
