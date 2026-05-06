# Infrastructure module for environment: var.environment
#
# This uses null_resource to keep the example provider-agnostic and
# `terraform validate`-able without real cloud credentials.  In a real
# deployment these would be replaced by aws_instance /
# google_compute_instance / azurerm_virtual_machine, etc.

terraform {
  required_version = ">= 1.0"
}

# --- Compute resource group ---------------------------------------------------
# Represents a logical grouping of compute instances (e.g. an AWS ASG,
# a GCP instance group, or an Azure VMSS).
resource "null_resource" "compute" {
  count = var.instance_count

  triggers = {
    environment   = var.environment
    region        = var.region
    instance_type = var.instance_type
    index         = count.index
  }
}

# --- Storage bucket -----------------------------------------------------------
# Represents a cloud storage bucket (S3, GCS, Azure Blob, etc.).
resource "null_resource" "storage_bucket" {
  triggers = {
    environment = var.environment
    bucket_name = var.storage_bucket_name
    region      = var.region
  }
}

# --- Networking ---------------------------------------------------------------
# Represents a VPC / VNet / network configuration with subnets.
resource "null_resource" "networking" {
  triggers = {
    environment       = var.environment
    region            = var.region
    enable_monitoring = tostring(var.enable_monitoring)
  }
}

# --- Config summary -----------------------------------------------------------
# In a real module this could be a local_file or template_file rendering
# a configuration artifact.  Here we use a null_resource to keep the
# provider footprint minimal.
resource "null_resource" "config" {
  triggers = {
    environment       = var.environment
    region            = var.region
    instance_count    = tostring(var.instance_count)
    instance_type     = var.instance_type
    storage_bucket    = var.storage_bucket_name
    enable_monitoring = tostring(var.enable_monitoring)
    tags              = jsonencode(var.tags)
  }
}
