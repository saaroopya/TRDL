output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_eks_cluster.primary.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.primary.endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.trdl.repository_url
}

output "lb_controller_role_arn" {
  value = aws_iam_role.lb_controller.arn
}
