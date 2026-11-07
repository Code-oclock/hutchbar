#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep these exact job names aligned with ci.yml. CodeQL is public-only and not required.
REQUIRED_CHECKS=('workflow-lint' 'secrets' 'build-test' 'sanitizers (asan)' 'sanitizers (tsan)' 'leaks' 'lint')
repository=${HUTCHBAR_REPOSITORY:-Code-oclock/hutchbar}
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid repository.' >&2; exit 64; }
printf 'Repository: %s\n' "$repository"
echo 'Plan: upsert main PR/check/signature rules; immutable v* tags; admin-only tag creation.'
echo 'Plan: configure release environment with owner review, accepting only v* tags.'
printf 'Required status checks: %s\n' "${REQUIRED_CHECKS[*]}"
if [[ "${1:-}" != --apply ]]; then
  [[ $# == 0 ]] || { echo 'Usage: Tools/apply-rulesets.sh [--apply]' >&2; exit 64; }
  echo 'Dry run. Pass --apply to change GitHub settings.'
  exit 0
fi
command -v gh >/dev/null || { echo 'Install and authenticate gh first.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
private=$(gh api "repos/$repository" --jq '.private')
fail() {
  if [[ "$private" == true ]]; then
    echo 'GitHub rejected protection settings for this private repository. Your plan may not support private rulesets or environment reviewers. Use local hooks until public, or upgrade the plan.' >&2
  else echo 'GitHub rejected settings; check administrator rights and API diagnostics above.' >&2; fi
  exit 1
}
owner=${repository%%/*}
owner_id=$(gh api "users/$owner" --jq '.id')
python3 - "$work" "$owner_id" "${REQUIRED_CHECKS[@]}" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
admin = [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'pull_request'}]
def save(name, pattern, rules, bypass):
    (root / (name + '.json')).write_text(json.dumps({
        'name': name, 'target': 'branch' if pattern == 'refs/heads/main' else 'tag',
        'enforcement': 'active', 'bypass_actors': bypass,
        'conditions': {'ref_name': {'include': [pattern], 'exclude': []}}, 'rules': rules,
    }))
save('hutchbar-main', 'refs/heads/main', [
    {'type': 'pull_request', 'parameters': {
        'required_approving_review_count': 0, 'dismiss_stale_reviews_on_push': True,
        'require_code_owner_review': False, 'require_last_push_approval': False,
        'required_review_thread_resolution': True,
    }},
    {'type': 'required_status_checks', 'parameters': {
        'strict_required_status_checks_policy': True,
        'required_status_checks': [{'context': c, 'integration_id': 15368} for c in sys.argv[3:]],
    }},
    *[{'type': t} for t in ['non_fast_forward', 'deletion', 'required_linear_history', 'required_signatures']],
], admin)
save('hutchbar-release-tags', 'refs/tags/v*',
     [{'type': t} for t in ['deletion', 'non_fast_forward', 'update']], [])
# Separate creation ruleset: admins can create tags but cannot bypass immutability.
save('hutchbar-tag-creation', 'refs/tags/v*', [{'type': 'creation'}],
     [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}])
(root / 'environment.json').write_text(json.dumps({
    'reviewers': [{'type': 'User', 'id': int(sys.argv[2])}],
    'prevent_self_review': False,
    'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True},
}))
(root / 'tag-policy.json').write_text(json.dumps({'name': 'v*', 'type': 'tag'}))
PY
for name in hutchbar-main hutchbar-release-tags hutchbar-tag-creation; do
  id=$(gh api --paginate "repos/$repository/rulesets" --jq ".[] | select(.name == \"$name\") | .id") || fail
  if [[ -n "$id" ]]; then
    gh api --method PUT "repos/$repository/rulesets/$id" --input "$work/$name.json" >/dev/null || fail
  else
    gh api --method POST "repos/$repository/rulesets" --input "$work/$name.json" >/dev/null || fail
  fi
done
gh api --method PUT "repos/$repository/environments/release" --input "$work/environment.json" >/dev/null || fail
# Remove stale branch/tag policies so this environment really accepts only v* tags.
gh api --paginate "repos/$repository/environments/release/deployment-branch-policies" \
  --jq '.branch_policies[] | [.id, .type, .name] | @tsv' > "$work/policies.tsv" || fail
found=0
while IFS=$'\t' read -r id type name; do
  [[ -n "$id" ]] || continue
  if [[ "$type" == tag && "$name" == 'v*' ]]; then found=1; else
    gh api --method DELETE "repos/$repository/environments/release/deployment-branch-policies/$id" || fail
  fi
done < "$work/policies.tsv"
if [[ "$found" == 0 ]]; then
  gh api --method POST "repos/$repository/environments/release/deployment-branch-policies" --input "$work/tag-policy.json" >/dev/null || fail
fi
echo 'Rulesets and release environment are configured. Enable immutable releases and private vulnerability reporting in repository settings.'
