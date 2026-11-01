#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${repo_root}/tests/bin:${PATH}"

assert_result() {
  local want="$1"
  local permission="$2"
  local event_name="$3"
  local event_action="$4"
  local actor="$5"
  local pr_author="$6"
  local comment_body="$7"
  local got

  got="$(
    TEST_PERMISSION="${permission}" \
    GATEWAY_AUTH_TOKEN="test-job-token" \
    GATEWAY_EVENT_NAME="${event_name}" \
    GATEWAY_EVENT_ACTION="${event_action}" \
    GATEWAY_REPO="lightninglabs/example" \
    GATEWAY_ACTOR="${actor}" \
    GATEWAY_PR_AUTHOR="${pr_author}" \
    GATEWAY_COMMENT_BODY="${comment_body}" \
      "${repo_root}/authorize-event.sh"
  )"

  if [[ "${got}" != "${want}" ]]; then
    printf 'got %q, want %q for actor %s and body %q\n' \
      "${got}" "${want}" "${actor}" "${comment_body}" >&2
    exit 1
  fi
}

assert_result true write issue_comment created maintainer contributor \
  '/gateway review'
assert_result false read issue_comment created outsider contributor \
  '/gateway review'
assert_result false not-found issue_comment created outsider contributor \
  '/gateway review'
assert_result true read issue_comment created contributor contributor \
  '/gateway check'
assert_result false read issue_comment created outsider contributor \
  '/gateway check'
assert_result true read issue_comment created outsider contributor \
  '/gateway explain F1'
assert_result false read issue_comment created outsider contributor \
  'not a command'
assert_result false write issue_comment created 'dependabot[bot]' contributor \
  '/gateway review'
assert_result true write pull_request_review_comment created maintainer contributor \
  '/gateway dismiss F1'
assert_result false write pull_request_review_comment edited maintainer contributor \
  '/gateway dismiss F1'
assert_result true read pull_request closed contributor contributor ''

marker="/tmp/gateway-action-command-injection-$$"
assert_result true write issue_comment created maintainer contributor \
  "/gateway review \`touch ${marker}\`"
if [[ -e "${marker}" ]]; then
  echo "comment text executed as shell code" >&2
  exit 1
fi

set +e
TEST_PERMISSION=error \
GATEWAY_AUTH_TOKEN=test-job-token \
GATEWAY_EVENT_NAME=issue_comment \
GATEWAY_REPO=lightninglabs/example \
GATEWAY_ACTOR=maintainer \
GATEWAY_COMMENT_BODY='/gateway review' \
  "${repo_root}/authorize-event.sh" >/dev/null 2>&1
status=$?
set -e

if [[ "${status}" -ne 2 ]]; then
  echo "authorization lookup failures must exit 2, got ${status}" >&2
  exit 1
fi

assert_guarded_step() {
  local name="$1"
  local block

  block="$(
    awk -v name="${name}" '
      $0 == "    - name: " name { found = 1 }
      found && seen && /^    - name:/ { exit }
      found { print; seen = 1 }
    ' "${repo_root}/action.yml"
  )"

  if [[ -z "${block}" ]]; then
    echo "missing composite step: ${name}" >&2
    exit 1
  fi
  if ! grep -Fq "if: steps.authorize.outputs.authorized == 'true'" \
      <<< "${block}"; then
    echo "composite step is not authorization-gated: ${name}" >&2
    exit 1
  fi
}

assert_guarded_step "Mint bootstrap token (reads private gateway runtime)"
assert_guarded_step "Checkout gateway runtime"
assert_guarded_step "Install Claude Code CLI"
assert_guarded_step "Run gateway"

echo "Gateway authorization tests passed."
