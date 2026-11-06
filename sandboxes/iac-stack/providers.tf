# Every provider a lesson may require. The image build mirrors exactly these
# versions, and tofu init installs from that mirror without the network.
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.6.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "6.66.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.8.1"
    }
  }
}
