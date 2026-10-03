# Changelog

Every entry states **addresses changed**: the resource addresses (or ForceNew attributes) that
change for a consumer who keeps their existing inputs. `none` means a version bump must plan with
no `create`, `delete` or replace.

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
