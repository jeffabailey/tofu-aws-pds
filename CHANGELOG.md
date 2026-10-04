# Changelog

Every entry states **addresses changed**: the resource addresses (or ForceNew attributes) that
change for a consumer who keeps their existing inputs. `none` means a version bump must plan with
no `create`, `delete` or replace.

## v1.6.0 — 2026-10-04

- `modules/pds`: new input `backup_alarm` (bool, default `false`, needs `backup_on_calendar`).
  The backup service publishes `PDS/Backup ArchiveUploaded` (dimension `Pds=<prefix>-pds-<env>`)
  after each success; a CloudWatch alarm `<prefix>-pds-<env>-backup-missing` fires after two
  consecutive UTC days without one (one day would false-alarm nightly before the jittered run),
  notifying SNS topic `<prefix>-pds-<env>-backup-alarm` (output `backup_alarm_topic_arn`). The
  topic gets no subscription from OpenTofu, so no email address lands in state: subscribe out
  of band (`aws sns subscribe --protocol email`). About $0.40/month.
- `modules/pds-bootstrap`: new input `backup_metrics` (default `false`): the host may
  `cloudwatch:PutMetricData` in `PDS/Backup` only; the CI plan/apply roles may read/manage the
  `<prefix>-pds-*` topic and alarm.

**Addresses changed: none.** New resources only when `backup_alarm = true`; with it off,
`user_data` and every policy are unchanged.

## v1.5.0 — 2026-10-04

- `modules/pds`: new input `backup_on_calendar` (systemd OnCalendar, default `""`). When set,
  first boot installs and enables `pds-backup-identity.timer` (30 min jitter, `Persistent=true`),
  whose service is skipped until `/pds/backup-pubkey.pem` exists. Logs:
  `journalctl -u pds-backup-identity`.
- Tests: the timer renders gated on the public key; the input refuses unit-file injection.

**Addresses changed: none.** With `backup_on_calendar = ""`, `user_data` is unchanged.

## v1.4.1 — 2026-10-03

- `scripts/check-user-data.sh`: an `A && B || C` test tripped CI's shellcheck (SC2015) since
  v1.3.0; it is an explicit `if` now. Scripts only.

**Addresses changed: none.** No module change: `user_data` is identical to v1.4.0.

## v1.4.0 — 2026-10-03

- `modules/pds`: the identity backup (`pds-backup-identity`) RSA-encrypted the whole archive,
  which only works while the archive is smaller than the key (about 245 bytes for 2048-bit RSA),
  so it failed for most keys. It is now hybrid: a fresh AES-256 + HMAC-SHA256 key pair per
  archive, AES-256-CBC then HMAC (encrypt-then-MAC), and only the 64 key bytes wrapped with
  RSA-OAEP(SHA-256). The object is now `identity-<stamp>.enc.tar` (format v2). `PDS_DIR`
  overrides `/pds` (for tests).
- New `scripts/pds-restore-identity.sh` decrypts a v2 archive, refusing it on an HMAC mismatch.
- `scripts/check-user-data.sh` runs the rendered backup script and restores its output with
  2048- and 4096-bit keys, and checks that a tampered archive is refused.

**Addresses changed: none. `user_data` changes for every consumer** (only the backup script's
body; the golden hashes in `render_identity.tftest.hcl` are updated and the old ones kept in its
comment). On a live host that is an in-place stop/start that does not re-run cloud-init: replace
the instance to get the new backup script (the volume, and the identity, survive).

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
