-- The second opinion: IAM Access Analyzer's own external-access findings.
-- The org analyzers (security/detection.tf, eu-west-2 and us-east-1) use the
-- organization as their zone of trust, so an ACTIVE finding is AWS saying
-- "this resource is reachable from outside the org". external-trust.sql
-- reads trust policies directly; where the two disagree, one of them is
-- missing something, and finding out which is the point.
select
  region,
  resource_type,
  resource,
  resource_owner_account,
  principal,
  condition,
  is_public,
  action
from aws_security.aws_accessanalyzer_finding
where status = 'ACTIVE'
order by is_public desc, resource_type, resource;
