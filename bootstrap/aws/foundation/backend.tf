# See ../accounts/backend.tf. Same two-step: local state for the apply that
# creates the bucket, then `make bootstrap-migrate-state` to move in.
terraform {
  backend "s3" {}
}
