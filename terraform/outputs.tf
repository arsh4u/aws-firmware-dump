output "region" {
  value = local.region
}

output "vpc_id" {
  value = local.vpc_id
}

output "subnet_ids" {
  value = local.subnet_ids
}

output "subnet_azs" {
  description = "Map of subnet id -> availability zone."
  value       = local.subnet_azs
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "helper_role_name" {
  value = aws_iam_role.helper.name
}

output "helper_instance_profile" {
  value = aws_iam_instance_profile.helper.name
}

output "helper_security_group_id" {
  value = aws_security_group.helper.id
}

output "helper_instance_ids" {
  value = aws_instance.helper[*].id
}

output "purpose_tag" {
  value = var.purpose_tag
}

# Ready-to-source shell fragment for the dump scripts.
output "dump_env" {
  value = <<-EOT
    export AWS_REGION=${local.region}
    export DUMP_BUCKET=${aws_s3_bucket.artifacts.bucket}
    export DUMP_INSTANCE_PROFILE=${aws_iam_instance_profile.helper.name}
    export DUMP_SECURITY_GROUP=${aws_security_group.helper.id}
    export DUMP_SUBNETS="${join(",", local.subnet_ids)}"
    export DUMP_PURPOSE=${var.purpose_tag}
    export DUMP_ASSOCIATE_PUBLIC_IP=${var.associate_public_ip}
    export DUMP_HELPER_TYPE=${var.helper_instance_type}
    export DUMP_HELPER_DISK_GB=${var.helper_root_volume_gb}
  EOT
}
