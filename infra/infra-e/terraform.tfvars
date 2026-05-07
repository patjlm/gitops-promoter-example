environment         = "integration"
region              = "us-central1"
instance_count      = 2
instance_type       = "medium"
tags                = { team = "platform", env = "int" }
storage_bucket_name = "myapp-int-data"
enable_monitoring   = true
