output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "budget_sns_topic_arn" {
  value = module.budgets.sns_topic_arn
}

output "terraform_plan_role_arn" {
  value = module.github_oidc.terraform_plan_role_arn
}

output "ecr_push_role_arn" {
  value = module.github_oidc.ecr_push_role_arn
}

output "reaper_repository_url" {
  value = module.ecr.reaper_repository_url
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
