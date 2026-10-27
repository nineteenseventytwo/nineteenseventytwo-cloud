# asset-graph/

Steampipe over every account in the org, read-only, run from a workstation
(nineteenseventytwo-platform `docs/plan/07-completion-plan.md` Phase 10.3).
SQL over the live AWS estate: the questions that would otherwise take an
afternoon of clicking through five accounts' consoles.

```bash
aws sso login --sso-session nineteenseventytwo-mgmt
asset-graph/run.sh                    # every query in queries/
asset-graph/run.sh external-trust     # one, by file name
```

Results land in `build/asset-graph/out/<query>.csv`, which is gitignored.
This repo is public: which roles trust what is for the person running the
query. What a result *means* goes in a write-up under `docs/asset-graph/`,
with the detail a reader needs and no more.

## How it is put together

- **Steampipe, pinned and checksum-verified.** `run.sh` downloads one exact
  release into `build/asset-graph/bin` and refuses a download whose SHA-256 does
  not match the hash written in the script. The AWS plugin is pinned too.
  Nothing is installed system-wide, and `STEAMPIPE_INSTALL_DIR` keeps its
  database and plugins under `build/`.
- **Audit-only credentials.** `run.sh` generates its own AWS config with one
  `audit-<account>` profile per account on the **SecurityAudit** permission set
  (`live/aws/org-management/identity-center.tf`: SecurityAudit +
  ViewOnlyAccess, assigned in every account). It reuses your existing SSO
  login. It does not use your `~/.aws/config` profiles, because several of
  those are admin permission sets, and a read-only inventory must not be able
  to change what it reads.
- **One connection per account, plus `aws_org`.** Queries name
  `aws_org.<table>` to see every account at once, or `aws_<account>.<table>`
  for one. Both allowed regions (`config/aws.json`).

## Queries

| Query | Question |
|---|---|
| `external-trust` | Which roles, in any account, can be assumed from outside the org, and on what conditions? |
| `access-analyzer` | What does IAM Access Analyzer, with the org as its zone of trust, say is reachable from outside? A second opinion on the first query |

Add a query by dropping a `.sql` file in `queries/`. Write down what it
answered in `docs/asset-graph/`:

- [0001](../docs/asset-graph/0001-external-trust.md): who can assume a role from outside the org?
