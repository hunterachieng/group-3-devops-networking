// Bootstrap resources live here.
// This will create the S3 bucket used for Terraform remote state.
// Required settings:
// - versioning enabled
// - server-side encryption enabled
// - public access blocked
// - state locking enabled through S3 lockfile support
// Do not put workload resources in this stack.

