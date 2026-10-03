# tofu-aws-pds

OpenTofu modules that run a single-host [ATProto PDS](https://github.com/bluesky-social/pds) on
AWS: one Graviton EC2 instance (cattle), a separate `prevent_destroy` EBS volume that holds the
identity, an Elastic IP, Route 53 records in an existing zone, and the per-account bootstrap
(backup bucket, host role, optional state bucket / default VPC / GitHub OIDC CI roles).

Extracted from `the-reality-base` so that more than one project can run the same deployment,
each in its own AWS account.

| Path | What it is |
|---|---|
| `modules/pds` | One PDS environment |
| `modules/pds-bootstrap` | Per-account foundation, applied once by a human before any environment |
| `scripts/check-user-data.sh` | Renders `user-data.sh.tftpl` with `templatefile()` and parses it with `bash -n` |
| `scripts/check-no-destroy.sh` | Fails if a workflow directory contains a destroy path or an unsaved-plan `-auto-approve` |
| `examples/single-env` | A minimal consuming root |

## Using it

```hcl
module "pds" {
  source = "git::https://github.com/jeffabailey/tofu-aws-pds.git//modules/pds?ref=v1.3.0"

  name_prefix = "openlore"
  project     = "openlore"

  descriptor            = jsondecode(file("${path.module}/../../../environments/prod.json"))
  hosted_zone_id        = "Z0123456789ABCDEFGHIJ"
  instance_profile_name = "openlore-pds-host-prod"           # pds-bootstrap output
  backup_bucket         = "openlore-identity-backup-111122223333" # pds-bootstrap output
  swap_mb               = 1024 # v1.1.0+: 1 GiB swap on the root volume (t4g.micro)
}
```

Apply `modules/pds-bootstrap` first, in its own root: the environment needs the host instance
profile, the backup bucket and a default VPC to exist at plan time.

## `modules/pds` input contract (v1.x)

| Input | Type / default | Notes |
|---|---|---|
| `name_prefix` | string, **required**, `^[a-z][a-z0-9-]{1,20}$` | Names are `<prefix>-pds-<env>` (SG, instance, EIP) and `<prefix>-pds-<env>-data` (volume). The SG name is ForceNew: never change it on a live deployment |
| `project` | string, **required** | `Project` tag only (in-place) |
| `require_namespace_matches_hostname` | bool, `false` | Refuse a plan unless `reverse(atproto_namespace) == pds_hostname`. The handle-under-hostname check is always on |
| `descriptor` | object (10 fields, below) | The single source of every name |
| `hosted_zone_id` | string, required | Existing public zone; A + wildcard A records are written into it |
| `instance_profile_name` | string, required | From `pds-bootstrap` |
| `backup_bucket` | string, required | From `pds-bootstrap` |
| `pds_image` | string, digest-pinned default | Validation refuses a tag |
| `ami_id` | string, `null` | Null = latest AL2023 arm64 at create time; `ignore_changes = [ami]` |
| `ssh_key_name` | string, `null` | Break-glass only |
| `ssh_ingress_cidr` | string, `null` | One CIDR; `0.0.0.0/0` is refused |
| `swap_mb` (v1.1.0) | number, `0`, `>= 0` | Swap file on the root volume at first boot. `0` renders `user_data` byte-identical to v1.0.0 |
| `verification_methods` (v1.3.0) | map(string), `{}` | `{ "<id>" = "did:key:z..." }` published into the account's did:plc document at first boot (signed with the PDS rotation key). Needs the account to exist |
| `bootstrap_account` (v1.2.0) | bool, `false` | Create the descriptor's handle as the first account at first boot; passwords go to SSM `/<name_prefix>/<env>/{account-password,cli-app-password}`. Needs `bootstrap_account = true` on `modules/pds-bootstrap` too |

`descriptor` fields: `environment`, `atproto_namespace`, `pds_hostname`, `handle`,
`tofu_state_key`, `lifecycle`, `aws_region`, `instance_type`, `data_volume_gb`,
`contact_ssm_parameter`.

Outputs: `public_ip`, `pds_url`, `handle`, `atproto_namespace`, `instance_id`, `data_volume_id`.
None is sensitive, and none can be: every credential is generated on the host at first boot.

## `modules/pds-bootstrap` input contract

| Input | Default | Notes |
|---|---|---|
| `name_prefix`, `project`, `aws_region` | required | Names: `<prefix>-identity-backup-<account>`, `<prefix>-pds-host-<env>`, `<prefix>-tofu-state-<account>`, `<prefix>-tofu-{plan,apply}-<env>` |
| `expected_account_id` | `null` | Account guard; null disables it |
| `hosted_zone_id`, `dns_record_name` | required | Zone must be public and contain the record |
| `environments` | required | Map of decoded descriptors keyed by environment. The module reads no files |
| `create_state_bucket` / `state_bucket_name` / `state_key_prefix` | `true` / `null` / `""` | Reuse an existing bucket with `create_state_bucket = false` |
| `create_default_vpc` | `false` | `aws_default_vpc`, for accounts that deleted theirs |
| `enable_ci_roles` | `true` | Per-environment GitHub OIDC plan/apply roles |
| `create_oidc_provider` | `true` | Only with CI roles; false adopts the existing provider |
| `github_org`, `github_repo`, `apply_job_workflow_ref`, `use_immutable_subject`, `github_org_id`, `github_repo_id` | `null` / `false` | Only with CI roles |

Outputs: `backup_bucket`, `host_instance_profile_names`, `state_bucket`, `hosted_zone_id`,
`default_vpc_id`, `plan_role_arns`, `apply_role_arns`, `account_id`.

## Versioning and upgrades

- Releases are SemVer tags on `main`. Consumers pin `?ref=vX.Y.Z` (or a commit SHA with a
  `# vX.Y.Z` comment).
- Every `CHANGELOG.md` entry lists **addresses changed**: `none`, or the resource addresses whose
  address or ForceNew attributes change for existing inputs. A change to an existing address or
  a ForceNew attribute is a **major** version.
- **Upgrade rule:** bump `?ref=` in one commit, run `tofu init -upgrade && tofu plan`, and apply
  only if the plan matches the CHANGELOG's "addresses changed" line. For a release that says
  `none`, the plan must contain no `create`, `delete` or replace.
- **Tag protection:** the repository has a ruleset that blocks updating or deleting `v*` tags, so
  a published tag cannot be moved under a consumer. Create it before the first tag is pushed
  (Settings -> Rules -> Rulesets -> New tag ruleset, target `v*`, restrict updates and deletions).

## Checks

```sh
tofu fmt -check -recursive
(cd modules/pds && tofu init -backend=false && tofu validate && tofu test)
(cd modules/pds-bootstrap && tofu init -backend=false && tofu validate && tofu test)
scripts/check-user-data.sh
scripts/check-no-destroy.sh .github
```

No AWS credentials are needed for any of them. CI (`.github/workflows/ci.yml`) runs the same.

## License

MIT
