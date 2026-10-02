variable "region" {
  description = "Region for the bucket, VPC, and extraction helper. The source AMI must already exist in this region; this stack does not copy AMIs."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for resource names. Lowercase, digits, hyphens; embedded in the bucket name."
  type        = string
  default     = "firmware-dump"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 1-20 characters: lowercase letters, digits, hyphens."
  }
}

variable "purpose_tag" {
  description = "Value of the Purpose tag. Cleanup and watch discover resources only by this tag."
  type        = string
  default     = "firmware-dump"
}

variable "vpc_id" {
  description = "Reuse an existing VPC. Empty string creates a dedicated VPC."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated VPC. Ignored when vpc_id is set."
  type        = string
  default     = "10.67.0.0/16"
}

variable "subnet_ids" {
  description = "Existing subnet IDs. Required when vpc_id is set; ignored otherwise."
  type        = list(string)
  default     = []
}

variable "subnet_count" {
  description = "Public subnets to create in the dedicated VPC, one per AZ. Must not exceed the number of AZs."
  type        = number
  default     = 2
}

variable "helper_instance_type" {
  description = "Instance type for the extraction helper. It never attaches a volume; t3.medium is enough."
  type        = string
  default     = "t3.medium"
}

variable "helper_root_volume_gb" {
  description = "Helper root volume size in GB. Images are streamed, so this only needs room for the OS and scripts."
  type        = number
  default     = 30
}

variable "helper_enabled" {
  description = "Create a long-lived helper. false (default) lets dump.sh launch and reuse an ephemeral helper."
  type        = bool
  default     = false
}

variable "associate_public_ip" {
  description = "Give instances a public IP. Required for SSM unless you add VPC endpoints; this VPC has no NAT gateway."
  type        = bool
  default     = true
}

variable "staging_retention_days" {
  description = "Days before objects under staging/ and _logs/ expire. golden/ never expires."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Extra tags merged onto every Terraform-managed resource."
  type        = map(string)
  default     = {}
}
