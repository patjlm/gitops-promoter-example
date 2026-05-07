environment         = "stage"
region              = "us-central1"
instance_count      = 2
instance_type       = "medium"
tags                = { team = "platform", env = "stg" }
storage_bucket_name = "myapp-stg-data"
enable_monitoring   = true
