variable "environment" {
  description = "Deployment environment name"
  type        = string
}

variable "region" {
  description = "Cloud region for resource placement"
  type        = string
}

variable "instance_count" {
  description = "Number of compute instances to provision"
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "Compute instance size (small, medium, large)"
  type        = string
  default     = "small"
}

variable "tags" {
  description = "Resource tags applied to all provisioned objects"
  type        = map(string)
  default     = {}
}

variable "storage_bucket_name" {
  description = "Name of the cloud storage bucket"
  type        = string
}

variable "enable_monitoring" {
  description = "Whether to enable monitoring and alerting"
  type        = bool
  default     = false
}
