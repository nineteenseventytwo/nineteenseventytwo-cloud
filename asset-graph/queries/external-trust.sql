-- Which roles, in any account, can be assumed by something outside the org?
-- (nineteenseventytwo-platform 07 Phase 10.3's attack-path question.)
--
-- One row per (role, principal) in every Allow statement of every trust
-- policy, across every account (aws_org aggregates them all). Service
-- principals are left out: they are AWS services acting for this account,
-- and they are what service-linked roles are made of.
--
-- verdict:
--   OUTSIDE-ORG           an AWS principal in an account that is not in the org
--   ANYONE                Principal "*" with no org condition
--   org-only (condition)  Principal "*", narrowed by aws:PrincipalOrgID
--   external-idp          an OIDC or SAML provider: identities that live
--                         outside AWS by definition. oidc_sub_pinned says
--                         whether an OIDC trust names which subjects may
--                         assume it - an unpinned GitHub OIDC trust is any
--                         repository on GitHub. Empty for SAML, which has no
--                         sub; Identity Center's trusts check saml:aud
--   in-org                another account (or this one) in the org
with org as (
  select array_agg(distinct account_id) as ids from aws_org.aws_account
),
stmts as (
  select r.account_id, r.name, r.path, s as stmt
  from aws_org.aws_iam_role r,
       jsonb_array_elements(r.assume_role_policy_std -> 'Statement') s
  where s ->> 'Effect' = 'Allow'
),
principals as (
  select account_id, name, path, stmt, k.kind, p.value #>> '{}' as principal
  from stmts,
       jsonb_each(stmt -> 'Principal') k(kind, vals),
       jsonb_array_elements(
         case jsonb_typeof(k.vals) when 'array' then k.vals else jsonb_build_array(k.vals) end
       ) p(value)
),
classified as (
  select
    case
      when kind = 'Federated' then 'external-idp'
      when principal = '*' and (stmt -> 'Condition')::text ilike '%aws:principalorgid%' then 'org-only (condition)'
      when principal = '*' then 'ANYONE'
      when coalesce(substring(principal from '^([0-9]{12})$'),
                    substring(principal from ':([0-9]{12}):')) = any(org.ids) then 'in-org'
      else 'OUTSIDE-ORG'
    end as verdict,
    account_id,
    path || name as role,
    kind as principal_type,
    principal,
    case when principal like '%:oidc-provider/%' then (stmt -> 'Condition')::text ~* ':sub"' end
      as oidc_sub_pinned,
    stmt -> 'Condition' as conditions
  from principals, org
  where kind <> 'Service'
)
select *
from classified
order by
  array_position(array['ANYONE', 'OUTSIDE-ORG', 'external-idp', 'org-only (condition)', 'in-org'], verdict),
  account_id, role;
