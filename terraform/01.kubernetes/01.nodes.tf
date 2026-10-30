resource "aws_iam_role" "nodes" {
  name = "${var.env}-${var.eks_name}-eks-nodes"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      }
    }
  ]
}
POLICY
}

# This policy now includes AssumeRoleForPodIdentity for the Pod Identity Agent
resource "aws_iam_role_policy_attachment" "amazon_eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.nodes.name
}

resource "aws_iam_role_policy_attachment" "amazon_eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.nodes.name
}

resource "aws_iam_role_policy_attachment" "amazon_ec2_container_registry_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.nodes.name
}

# Tag discovery cho cluster autoscaler (07.cluster-autoscaler.tf). EKS gắn tag của node group lên ASG.
locals {
  autoscaler_node_group_tags = {
    "k8s.io/cluster-autoscaler/enabled"                     = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.eks.name}" = "owned"
  }
}

# Node group Elasticsearch và Kibana. Pod gắn nodeSelector workload=elasticsearch.
resource "aws_eks_node_group" "elasticsearch" {
  cluster_name    = aws_eks_cluster.eks.name
  version         = var.eks_version
  node_group_name = "elasticsearch"
  node_role_arn   = aws_iam_role.nodes.arn

  subnet_ids = data.terraform_remote_state.networking.outputs.values.private_subnet_ids

  capacity_type  = "ON_DEMAND"
  # instance_types = ["t3.medium"] # CPU: 2, RAM: 4GB, Network: Up to 5 Gbps, EBS: Up to 3.5 Gbps
  instance_types = ["t3.large"] # CPU: 2, RAM: 8GB, Network: Up to 5 Gbps, EBS: Up to 3.5 Gbps

  scaling_config {
    desired_size = 6
    max_size     = 10
    min_size     = 6
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "elasticsearch"
  }

  tags = local.autoscaler_node_group_tags

  depends_on = [
    aws_eks_cluster.eks,
    aws_iam_role_policy_attachment.amazon_eks_worker_node_policy,
    aws_iam_role_policy_attachment.amazon_eks_cni_policy,
    aws_iam_role_policy_attachment.amazon_ec2_container_registry_read_only,
  ]

  # Allow external changes without Terraform plan difference
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# Node group Redis Cluster và RedisInsight. Pod gắn nodeSelector workload=redis.
# resource "aws_eks_node_group" "redis" {
#   cluster_name    = aws_eks_cluster.eks.name
#   version         = var.eks_version
#   node_group_name = "redis"
#   node_role_arn   = aws_iam_role.nodes.arn

#   subnet_ids = data.terraform_remote_state.networking.outputs.values.private_subnet_ids

#   capacity_type  = "ON_DEMAND"
#   instance_types = ["t3.medium"] # CPU: 2, RAM: 4GB, Network: Up to 5 Gbps, EBS: Up to 3.5 Gbps

#   scaling_config {
#     desired_size = 6
#     max_size     = 10
#     min_size     = 6
#   }

#   update_config {
#     max_unavailable = 1
#   }

#   labels = {
#     workload = "redis"
#   }

#   tags = local.autoscaler_node_group_tags

#   depends_on = [
#     aws_eks_cluster.eks,
#     aws_iam_role_policy_attachment.amazon_eks_worker_node_policy,
#     aws_iam_role_policy_attachment.amazon_eks_cni_policy,
#     aws_iam_role_policy_attachment.amazon_ec2_container_registry_read_only,
#   ]

#   # Allow external changes without Terraform plan difference
#   lifecycle {
#     ignore_changes = [scaling_config[0].desired_size]
#   }
# }

# resource "aws_eks_node_group" "node_api" {
#   cluster_name    = aws_eks_cluster.eks.name
#   version         = var.eks_version
#   node_group_name = "node_api"
#   node_role_arn   = aws_iam_role.nodes.arn

#   subnet_ids = data.terraform_remote_state.networking.outputs.values.private_subnet_ids

#   capacity_type  = "ON_DEMAND"
#   instance_types = ["t3.medium"] # CPU: 2, RAM: 4GB, Network: Up to 5 Gbps, EBS: Up to 3.5 Gbps

#   scaling_config {
#     desired_size = 1
#     max_size     = 3
#     min_size     = 1
#   }

#   update_config {
#     max_unavailable = 1
#   }

#   labels = {
#     workload = "node_api"
#   }

#   tags = local.autoscaler_node_group_tags

#   depends_on = [
#     aws_eks_cluster.eks,
#     aws_iam_role_policy_attachment.amazon_eks_worker_node_policy,
#     aws_iam_role_policy_attachment.amazon_eks_cni_policy,
#     aws_iam_role_policy_attachment.amazon_ec2_container_registry_read_only,
#   ]

#   # Allow external changes without Terraform plan difference
#   lifecycle {
#     ignore_changes = [scaling_config[0].desired_size]
#   }
# }
