provider "aws" {
  region              = var.aws_region
  allowed_account_ids = ["121754142617"]

  default_tags {
    tags = local.common_tags
  }
}

data "aws_eks_cluster" "base" {
  name = local.base_exports["cluster-name"]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.base.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.base.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.base.name, "--region", var.aws_region]
  }
}
