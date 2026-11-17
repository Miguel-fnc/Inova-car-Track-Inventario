# Destroys only the infrastructure managed by Terraform.
# The S3 bucket is pre-existing/outside Terraform ownership and is left intact.
$ErrorActionPreference = "Stop"
terraform -chdir="$PSScriptRoot" destroy
