#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

log() {
  local level="$1"
  local outcome="$2"
  local detail="${3:-}"

  printf '%s: level=%s outcome=%s' "${SCRIPT_NAME}" "${level}" \
    "${outcome}" >&2
  if [[ -n "${detail}" ]]; then
    printf ' detail=%s' "${detail}" >&2
  fi
  printf '\n' >&2
}

authorize() {
  log info authorized "$1"
  printf 'true\n'
  exit 0
}

deny() {
  log info denied "$1"
  printf 'false\n'
  exit 0
}

required_env=(
  GATEWAY_AUTH_TOKEN
  GATEWAY_EVENT_NAME
  GATEWAY_REPO
  GATEWAY_ACTOR
)

for name in "${required_env[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    log error invalid_input "missing_${name}"
    exit 2
  fi
done

if ! [[ "${GATEWAY_REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  log error invalid_input invalid_repo
  exit 2
fi

if ! [[ "${GATEWAY_ACTOR}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]]; then
  log error invalid_input invalid_actor
  exit 2
fi

if [[ "${GATEWAY_ACTOR}" == \
      "${GATEWAY_BOT_LOGIN:-lightninglabs-gateway[bot]}" ]]; then
  deny bot_actor
fi

case "${GATEWAY_ACTOR}" in
  dependabot\[bot\]|renovate\[bot\]|github-actions\[bot\])
    deny bot_actor
    ;;
esac

is_known_command() {
  case "$1" in
    review|stop|pause|resume|dismiss|explain|re-review|approve|promote|check)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

parse_command() {
  local line
  local command

  while IFS= read -r line || [[ -n "${line}" ]]; do
    while [[ "${line}" =~ [[:space:]]$ ]]; do
      line="${line%[[:space:]]}"
    done

    if [[ "${line}" =~ ^/gateway[[:space:]]+([^[:space:]]+) ]]; then
      command="${BASH_REMATCH[1]}"
      if is_known_command "${command}"; then
        printf '%s\n' "${command}"
        return 0
      fi
    fi
  done <<< "${GATEWAY_COMMENT_BODY:-}"

  return 1
}

is_maintainer() {
  local error_file
  local permission

  error_file="$(mktemp -t gateway-authorize.XXXXXX)"
  if ! permission="$(
    GH_TOKEN="${GATEWAY_AUTH_TOKEN}" gh api \
      "repos/${GATEWAY_REPO}/collaborators/${GATEWAY_ACTOR}/permission" \
      --jq '.permission' 2>"${error_file}"
  )"; then
    if grep -qE 'HTTP (403|404)' "${error_file}"; then
      rm -f "${error_file}"
      return 1
    fi
    rm -f "${error_file}"
    log error authorization_lookup failed
    return 2
  fi
  rm -f "${error_file}"

  case "${permission}" in
    admin|write)
      return 0
      ;;
    read|none)
      return 1
      ;;
    *)
      log error authorization_lookup unknown_permission
      return 2
      ;;
  esac
}

authorize_maintainer() {
  local status

  if is_maintainer; then
    authorize maintainer
  else
    status=$?
    if [[ "${status}" -eq 1 ]]; then
      deny maintainer_required
    fi
    exit "${status}"
  fi
}

authorize_author_or_maintainer() {
  if [[ -n "${GATEWAY_PR_AUTHOR:-}" && \
        "${GATEWAY_ACTOR}" == "${GATEWAY_PR_AUTHOR}" ]]; then
    authorize pr_author
  fi

  authorize_maintainer
}

case "${GATEWAY_EVENT_NAME}" in
  issue_comment)
    if ! command="$(parse_command)"; then
      deny no_command
    fi

    case "${command}" in
      review|dismiss|re-review|approve|promote)
        authorize_maintainer
        ;;
      stop|pause|resume|check)
        authorize_author_or_maintainer
        ;;
      explain)
        authorize public_command
        ;;
    esac
    ;;

  pull_request_review_comment)
    if [[ "${GATEWAY_EVENT_ACTION:-}" != "created" ]]; then
      deny unsupported_action
    fi
    if ! command="$(parse_command)"; then
      deny no_command
    fi

    case "${command}" in
      dismiss|promote)
        authorize_maintainer
        ;;
      check)
        authorize_author_or_maintainer
        ;;
      explain)
        authorize public_command
        ;;
      *)
        authorize inline_command_reply
        ;;
    esac
    ;;

  pull_request)
    case "${GATEWAY_EVENT_ACTION:-}" in
      review_requested|closed)
        authorize repository_event
        ;;
      *)
        deny unsupported_action
        ;;
    esac
    ;;

  *)
    deny unsupported_event
    ;;
esac

deny unsupported_command
