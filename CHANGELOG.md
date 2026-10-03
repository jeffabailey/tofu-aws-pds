# Changelog

Every entry states **addresses changed**: the resource addresses (or ForceNew attributes) that
change for a consumer who keeps their existing inputs. `none` means a version bump must plan with
no `create`, `delete` or replace.

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
