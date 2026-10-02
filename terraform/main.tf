data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ---------------------------------------------------------------------------
# Dedicated VPC. Created only when vpc_id is empty, so an existing VPC is
# never selected or modified by accident. No NAT gateway: idle cost is zero.
# Instances need a public IP (or VPC endpoints you add yourself) for SSM.
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  count = var.vpc_id == "" ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  count = var.vpc_id == "" ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  count = var.vpc_id == "" ? var.subnet_count : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  count = var.vpc_id == "" ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  count = var.vpc_id == "" ? var.subnet_count : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

data "aws_subnet" "selected" {
  for_each = toset(var.vpc_id == "" ? [] : var.subnet_ids)
  id       = each.value
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  vpc_id     = var.vpc_id == "" ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = var.vpc_id == "" ? aws_subnet.public[*].id : var.subnet_ids

  subnet_azs = var.vpc_id == "" ? {
    for s in aws_subnet.public : s.id => s.availability_zone
    } : {
    for id, s in data.aws_subnet.selected : id => s.availability_zone
  }

  tags = merge(
    {
      Project = var.name_prefix
      Purpose = var.purpose_tag
    },
    var.tags,
  )

  bucket_name = lower("${var.name_prefix}-artifacts-${local.account_id}-${local.region}")
}

# ---------------------------------------------------------------------------
# Artifact bucket. golden/ is the durable store and has no expiry rule.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.bucket_name
  force_destroy = true

  lifecycle {
    precondition {
      condition     = length(local.bucket_name) <= 63
      error_message = "Bucket name ${local.bucket_name} exceeds 63 characters. Shorten name_prefix."
    }
    precondition {
      condition     = var.vpc_id == "" || length(var.subnet_ids) > 0
      error_message = "subnet_ids is required when vpc_id is set."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # golden/ deliberately has no expiration rule.
  rule {
    id     = "expire-status"
    status = "Enabled"

    filter {
      prefix = "_status/"
    }

    expiration {
      days = 7
    }
  }

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {
      prefix = "_logs/"
    }

    expiration {
      days = var.staging_retention_days
    }
  }

  rule {
    id     = "expire-staging"
    status = "Enabled"

    filter {
      prefix = "staging/"
    }

    expiration {
      days = var.staging_retention_days
    }
  }

  # A killed multi-gigabyte upload must not leave billable parts behind.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# ---------------------------------------------------------------------------
# Helper role: write artifacts, read snapshot bytes, be reachable by SSM.
# No inbound, no SSH. The operator's own credentials launch instances.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "helper_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "helper" {
  name               = "${var.name_prefix}-helper"
  assume_role_policy = data.aws_iam_policy_document.helper_assume.json
}

data "aws_iam_policy_document" "helper_permissions" {
  statement {
    sid = "ArtifactsBucket"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  statement {
    sid = "SsmControlPlane"

    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]

    resources = ["*"]
  }

  # Snapshot bytes are read over HTTPS. No volume is created or attached.
  statement {
    sid = "EbsDirectApis"

    actions = [
      "ebs:GetSnapshotBlock",
      "ebs:ListChangedBlocks",
      "ebs:ListSnapshotBlocks",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:DeleteSnapshot",
      "ec2:DescribeSnapshots",
      "ec2:DescribeVolumes",
    ]

    resources = ["*"]
  }

  # Accounts with EBS encryption-by-default produce encrypted snapshots.
  # GetSnapshotBlock fails without kms:Decrypt on the snapshot's key.
  statement {
    sid = "DecryptSnapshotKeys"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "helper" {
  name   = "helper"
  role   = aws_iam_role.helper.id
  policy = data.aws_iam_policy_document.helper_permissions.json
}

resource "aws_iam_instance_profile" "helper" {
  name = "${var.name_prefix}-helper"
  role = aws_iam_role.helper.name
}

resource "aws_security_group" "helper" {
  name        = "${var.name_prefix}-helper"
  description = "Egress-only SG for the firmware extraction helper (SSM-managed, no inbound)."
  vpc_id      = local.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.helper.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound (S3, SSM, EBS direct APIs)."
}

# ---------------------------------------------------------------------------
# Optional long-lived helper. dump.sh launches an ephemeral one when disabled.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

resource "aws_instance" "helper" {
  count = var.helper_enabled ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.helper_instance_type
  subnet_id                   = local.subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.helper.id]
  iam_instance_profile        = aws_iam_instance_profile.helper.name
  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_size = var.helper_root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = file("${path.module}/../scripts/helper_user_data.sh")

  tags = {
    Name = "${var.name_prefix}-helper"
    Role = "helper"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
