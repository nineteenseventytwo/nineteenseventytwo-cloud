# Configured entirely from the Makefile with -backend-config, because the
# bucket name contains the shared account's ID and is therefore not knowable
# when this file is written — it is created by ../foundation, several steps
# later.
#
# The first apply runs with `-backend=false` and local state. `make
# bootstrap-migrate-state` moves it into S3 once the bucket exists. Until that
# has run, the only copy of the state describing your organisation is in a
# working directory on a laptop, which is a fine place for it for about twenty
# minutes and a terrible one for longer.
terraform {
  backend "s3" {}
}
