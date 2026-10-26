# prowler/

The daily Prowler scan (ADR-0005): `.github/workflows/prowler.yml` runs it on
a hosted runner as `gha-prowler` (`live/aws/platform-prod/prowler.tf`), with
`mutelist.yaml` here, and writes findings to the security account's bucket.

Until 2026-10-26 it was a CronJob in the cluster (nineteenseventytwo-platform).
A scan peaks at 650-840Mi of real memory, which took a 4GB Pi worker NotReady,
and Prowler audits AWS, not the cluster - so it moved here. The notes below
were learned running it there and still apply: the workflow passes the same
arguments to the same pinned image.

## Reading the results

This repo is public, so its Actions logs and run summaries are too. The scan's
console report never reaches either: the workflow writes it to a file it does
not print, and the run summary carries totals by severity only. The detail -
which checks fail, on which resources - is the HTML/CSV/OCSF report in
`s3://nineteenseventytwo-prowler-517148962038/findings/`, readable from the
security account:

```bash
aws s3 ls s3://nineteenseventytwo-prowler-517148962038/findings/html/ --profile nineteenseventytwo-security
```

Prowler's own console table counts muted FAILs as failures. A finding that is
a decision rather than a gap has `status: Suppressed` in the OCSF output; the
run summary counts only the rest.

## Region filter, or it OOMs

Confirmed 2026-08-28: with no `--region` filter, Prowler scans **every enabled
AWS region** (39 of them) and ran out of memory twice at 1Gi. The account only
ever uses the two in `config/aws.json`'s `regions.allowed`. Scanning regions
this account never touches is waste, not a safety margin.

## --output-directory must be a bare relative name

Prowler's S3 key mapping (`get_object_path` in `providers/aws/lib/s3/s3.py`)
strips everything up to and including the first literal `prowler/` substring
in `--output-directory` before using the rest as the S3 key prefix. **Every
path under the image's home directory contains that substring**, so an
absolute path silently uploads to `<bucket>/output/findings/*` instead of
`<bucket>/findings/*` - outside the prefix the role may write to.

That fails as a bare `AccessDenied` which `send_to_bucket` only sends to
Prowler's logger, never stdout. A relative `findings` avoids the substring and
resolves under the image's working directory, where the workflow mounts the
output directory.

## --output-bucket needs --output-formats

`--output-bucket`'s own `--help` says it requires `-M <mode>`. Without it,
local files are written but nothing reaches S3, and nothing reports an error.

## exit 3 is success

Exit 3 means "the scan ran fine and found FAIL results" - normal for any real
account. Without `--ignore-exit-code-3` every run with a finding would read as
failed, and a real crash would look identical.

## uid 1000

`prowlercloud/prowler` hardcodes uid 1000 and chmods `/home/prowler` 700:
nothing else can even exec the entrypoint. On the runner that means the output
directory the workflow mounts has to be writable by uid 1000, hence its
`chmod 777` on a directory that exists only for the length of the job.
