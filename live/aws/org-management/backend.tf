# Backend configuration comes from the Makefile (-backend-config), which reads
# config/aws.json. One definition of where state lives, shared by every stack
# and by CI.
terraform {
  backend "s3" {}
}
