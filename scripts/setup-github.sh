#!/usr/bin/env bash
# Sets up EazyDisplay's GitHub repository the way FreeAudio's is, and pushes main to it the first time:
#
#   - public, rebase merges only: the commit gate skips merge commits, and a squash would fold every commit's changelog
#     lines into one message (commit.md)
#   - a ruleset on main: changes arrive as pull requests with two approvals and resolved threads, history stays linear,
#     main can't be force-pushed or deleted. Whoever runs this may bypass it, which is how snapshots reach main directly.
#   - FreeAudio's labels, and none of GitHub's defaults
#   - secret scanning with push protection, Dependabot alerts, private vulnerability reporting, CodeQL
#
#   scripts/setup-github.sh                 ExpTechTW/EazyDisplay
#   scripts/setup-github.sh owner/repo
#
# Safe to run again: every step sets a state rather than adding to it. Secrets can't be copied from FreeAudio, since
# GitHub never gives their values back; the last step names the ones still missing and how to set them.
set -euo pipefail

repo="${1:-ExpTechTW/EazyDisplay}"
template=ExpTechTW/FreeAudio
description="住在選單列的 macOS 螢幕亮度工具，可把 XDR 螢幕增亮到 1000 nit"
cd "$(dirname "$0")/.."

# The repository, with `origin` pointing at it and main pushed.
if gh repo view "$repo" --json name >/dev/null 2>&1; then
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$repo.git"
else
  gh repo create "$repo" --public --description "$description" --source . --remote origin --push
fi

gh api -X PATCH "repos/$repo" --silent \
  -f description="$description" -f homepage= \
  -F has_issues=true -F has_projects=true -F has_wiki=false -F has_discussions=false -F has_downloads=false \
  -F allow_merge_commit=false -F allow_squash_merge=false -F allow_rebase_merge=true \
  -F allow_auto_merge=false -F allow_update_branch=false -F delete_branch_on_merge=false
echo "✓ settings"

gh api -X PATCH "repos/$repo" --silent --input - <<'EOF'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"}, "secret_scanning_push_protection": {"status": "enabled"}}}
EOF
gh api -X PUT "repos/$repo/vulnerability-alerts" --silent
gh api -X PUT "repos/$repo/private-vulnerability-reporting" --silent
# CodeQL picks the languages itself, as it did for FreeAudio. Changing it while a setup run is going answers 409, and a
# new public repository often starts one of its own.
if [ "$(gh api "repos/$repo/code-scanning/default-setup" --jq .state)" != configured ]; then
  gh api -X PATCH "repos/$repo/code-scanning/default-setup" --silent -f state=configured -f query_suite=default
fi
echo "✓ security"

# release.yml asks for what it writes itself (contents: write).
gh api -X PUT "repos/$repo/actions/permissions/workflow" --silent \
  -f default_workflow_permissions=write -F can_approve_pull_request_reviews=true
echo "✓ actions"

me="$(gh api user --jq .id)"
ruleset="$(cat <<EOF
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [{"actor_id": $me, "actor_type": "User", "bypass_mode": "always"}],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_linear_history"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 2,
      "dismiss_stale_reviews_on_push": true,
      "required_reviewers": [],
      "require_code_owner_review": true,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true,
      "require_extra_approval_for_unattributed_changes": true,
      "allowed_merge_methods": ["rebase"]
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "do_not_enforce_on_create": false,
      "required_status_checks": []
    }},
    {"type": "code_quality", "parameters": {"severity": "warnings"}},
    {"type": "copilot_code_review", "parameters": {"review_on_push": false, "review_draft_pull_requests": false}}
  ]
}
EOF
)"
id="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "main") | .id')"
if [ -n "$id" ]; then
  gh api -X PUT "repos/$repo/rulesets/$id" --silent --input - <<<"$ruleset"
else
  gh api -X POST "repos/$repo/rulesets" --silent --input - <<<"$ruleset"
fi
echo "✓ ruleset on main (bypass: $(gh api user --jq .login))"

gh label clone "$template" -R "$repo" --force >/dev/null
comm -23 <(gh label list -R "$repo" --limit 200 --json name --jq '.[].name' | sort) \
  <(gh label list -R "$template" --limit 200 --json name --jq '.[].name' | sort) |
  while IFS= read -r label; do gh label delete "$label" -R "$repo" --yes >/dev/null; done
echo "✓ labels from $template"

missing="$(comm -23 \
  <(printf '%s\n' APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_TEAM_ID APPLE_ID APPLE_APP_SPECIFIC_PASSWORD DISCORD_WEBHOOK | sort) \
  <(gh secret list -R "$repo" --json name --jq '.[].name' | sort))"
if [ -z "$missing" ]; then
  echo "✓ secrets"
  exit 0
fi
echo
echo "Secrets still missing: $(printf '%s' "$missing" | tr '\n' ' ')"
if printf '%s\n' "$missing" | grep -q '^APPLE_'; then
  echo "  Until they're set, a push to main stops at signing and publishes nothing. Set them with"
  echo "    scripts/set-apple-secrets.sh <DeveloperID.p12> $repo"
fi
if printf '%s\n' "$missing" | grep -q '^DISCORD_WEBHOOK$'; then
  echo "  Releases are announced on Discord once the webhook is set:"
  echo "    gh secret set DISCORD_WEBHOOK -R $repo"
fi
