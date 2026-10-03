# Changelog

Every entry states **addresses changed**: the resource addresses (or ForceNew attributes) that
change for a consumer who keeps their existing inputs. `none` means a version bump must plan with
no `create`, `delete` or replace.

## v1.3.0 — 2026-10-03

- `modules/pds`: new input `verification_methods` (map of method id -> `did:key:z...`, default
  `{}`). First boot publishes them into the account's did:plc document with a PLC update signed
  by this PDS's rotation key (inside the PDS container, via its `@did-plc/lib`). Idempotent;
  the account's `#atproto` key (refused as an input) and every other method are kept. Use it
  for an application's own signing key, e.g. `org.openlore.application`.
- `scripts/check-user-data.sh` parses the new wrapper and `node --check`s the PLC script.
- Tests: input validation (no `atproto`, values must be `did:key:z...`) and the render.

**Addresses changed: none.** With `verification_methods = {}`, `user_data` is unchanged.

## v1.2.1 — 2026-10-03

- `modules/pds`: a first-boot script over EC2's 16 KiB `user_data` limit (swap plus the account
  step) failed validation. A script that fits is still passed as `user_data`; a larger one goes
  through `user_data_base64` gzipped, which cloud-init unpacks.

**Addresses changed: none.** Every script that fit before still uses `user_data`, unchanged.

## v1.2.0 — 2026-10-03

- `modules/pds`: new input `bootstrap_account` (bool, default `false`). When true, first boot
  creates the descriptor's `handle` as the PDS's first account (email = the ACME contact) plus a
  `deploy-cli` app password, and stores both as SSM SecureString parameters
  `/<name_prefix>/<environment>/account-password` and `.../cli-app-password`. Idempotent: an
  existing handle is left alone. The PDS port is published on `127.0.0.1:3000` only, for this
  step. New output `account_ssm_parameters`.
- `modules/pds-bootstrap`: new input `bootstrap_account` (bool, default `false`) that lets each
  host write exactly those two parameters.
- `scripts/check-user-data.sh` also renders `bootstrap_account = true` and parses (and
  shellchecks) the embedded `pds-ensure-account` script.
- Tests: `account.tftest.hcl` (off matches the golden hash; on renders the step), and two
  bootstrap runs pinning the IAM grant.

**Addresses changed: none.** With `bootstrap_account = false`, `user_data` and the host policy
are unchanged. Turning it on for a live host changes `user_data`; replace the instance for it to
apply (the data volume, and so the identity, survives).

## v1.1.0 — 2026-10-02

- `modules/pds`: new input `swap_mb` (number, default `0`, must be `>= 0`). When greater than 0,
  first boot creates a swap file of that size on the root volume (never on `/pds`), adds it to
  `/etc/fstab` and enables it, before `dnf update`. Re-running is safe.
- `scripts/check-user-data.sh` renders and parses both `swap_mb = 0` and `swap_mb = 1024`.
- Test: `swap.tftest.hcl` (0 matches the v1.0.0 golden hash; 1024 renders the swap step).

**Addresses changed: none.** `user_data` is unchanged when `swap_mb = 0`, so bumping from
v1.0.0 without setting it plans no change. Setting `swap_mb` on a live host changes `user_data`
(an in-place stop/start that does not re-run cloud-init); replace the instance for it to apply.

## v1.0.0 — 2026-10-02

Extracted from `the-reality-base` `deploy/tofu/modules/pds` (history preserved), plus the
shared bootstrap and scripts.

- `modules/pds`: new required inputs `name_prefix` and `project`, and
  `require_namespace_matches_hostname` (default `false`), which gates the namespace precondition
  inside the existing `terraform_data.name_invariants`. The handle-under-hostname precondition
  stays always on. No resource or data block is renamed.
- `modules/pds-bootstrap`: generalised from the-reality-base `deploy/tofu/bootstrap` with
  toggles `create_state_bucket`, `create_oidc_provider`, `enable_ci_roles`, `create_default_vpc`
  and descriptors passed in as `environments`.
- `scripts/check-user-data.sh` renders with OpenTofu's `templatefile()`;
  `scripts/check-no-destroy.sh` takes the directory to scan.
- Tests: render identity (the-reality-base prod/test `user_data` sha256), naming contract,
  invariants, AZ selection, bootstrap toggles and guards.

**Addresses changed: none.** For the-reality-base inputs (`name_prefix = "trb"`,
`project = "the-reality-base"`, `require_namespace_matches_hostname = true`) every name and the
rendered `user_data` are byte-identical to the pre-extraction module.
