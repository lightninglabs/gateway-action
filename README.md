# gateway-action

Public entry point for **gateway**, the Lightning Labs PR review bot.

The review runtime lives in the **private** repo
[`lightninglabs/gateway`](https://github.com/lightninglabs/gateway). GitHub
only extends a private repo's actions to *private and internal* org repos, so a
**public** consumer (e.g. `lightninglabs/neutrino`) cannot resolve
`lightninglabs/gateway/.github/actions/review@<tag>` — the job fails at setup
with:

```
##[error]Unable to resolve action `lightninglabs/gateway`, not found
```

This repo is **public**, so any consumer — public or private — can resolve it.
At runtime it pulls the private runtime using a token minted from the
consumer-passed App credentials. The review logic, prompts, and skills stay
private; only this thin entry point is public.

## How it works

The composite action ([`action.yml`](action.yml)) runs three steps:

1. **Mint bootstrap token** — [`bootstrap-token.sh`](bootstrap-token.sh) mints a
   **least-privilege** installation token (`contents:read` on
   `lightninglabs/gateway` only) from the consumer's `app_id` / `private_key`.
   It discovers the gateway installation rather than hardcoding an id. This bit
   of logic must live here because it runs *before* the private runtime is on
   disk.
2. **Checkout runtime** — [`actions/checkout`](https://github.com/actions/checkout)
   pulls `lightninglabs/gateway` at `runtime_ref` using that bootstrap token.
3. **Run** — execs `scripts/run-review.sh` from the checked-out tree, the same
   entry point as the private action. `run-review.sh` mints its *own* token
   (scoped to the **consumer's** install, with review write perms) — a
   different installation and scope from the bootstrap token.

Two tokens, two installations — see [docs/architecture.md](docs/architecture.md)
for the full picture. No new trust exposure: the consumer already runs this
exact runtime today — this only changes *where the entry point resolves*.

## Usage

Copy [`templates/gateway.yml`](templates/gateway.yml) to
`.github/workflows/gateway.yml` in your consumer repo and fill in the marked
values. Minimal shape:

```yaml
      - uses: lightninglabs/gateway-action@<COMMIT_SHA> # vX.Y.Z
        with:
          event_name:      ${{ github.event_name }}
          event_action:    ${{ github.event.action }}
          repo:            ${{ github.repository }}
          pr_number:       ${{ github.event.issue.number || github.event.pull_request.number }}
          actor:           ${{ github.event.sender.login }}
          comment_body:    ${{ github.event.comment.body }}
          comment_id:      ${{ github.event.comment.id }}
          app_id:                  ${{ secrets.GATEWAY_APP_ID }}
          private_key:             ${{ secrets.GATEWAY_PRIVATE_KEY }}
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

`installation_id` is optional — omit it and the runtime resolves the App install
covering this repo from `app_id`/`private_key`. Set it only to pin a specific
installation.

At least one of `claude_code_oauth_token` or `anthropic_api_key` must be set;
the example uses OAuth. To use an Anthropic API key instead (tried first if both
are set), add `anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}`.

Pin `uses:` to a **full commit SHA** with a trailing `# vX.Y.Z` comment — never
a bare tag. Full onboarding (App install, secrets) lives in the private repo's
`docs/consumer-setup.md`.

## Prerequisites

- The gateway GitHub App is installed on `lightninglabs/gateway` itself (it is,
  org-wide) and has `contents: read`, so the minted token can read the runtime.
- The App is installed on the consumer repo, and the org secrets
  (`GATEWAY_APP_ID`, `GATEWAY_PRIVATE_KEY`, and one of `ANTHROPIC_API_KEY` /
  `CLAUDE_CODE_OAUTH_TOKEN`) are available to it.

## Versioning

This repo is versioned in **lockstep** with `lightninglabs/gateway`. Each
release tag here pins the matching gateway runtime ref (the `ref:` on the
checkout step in `action.yml`). A given `gateway-action` SHA therefore maps
deterministically to one runtime version — consumers track a single version
axis.

| gateway-action | gateway runtime ref |
|----------------|---------------------|
| `v0.6.1`       | `v0.6.1`            |
| `v0.6.0`       | `v0.6.0`            |
| `v0.4.2`       | `v0.4.2`            |

Starting with `v0.6.1`, the runtime bounds a complete review run to 13 minutes,
including credential retries and multi-to-single dispatch fallback. Existing
15-minute workflows remain supported. The canonical consumer template uses a
recommended 30-minute outer timeout for additional runner, teardown, and
posting margin.

## License

[MIT](LICENSE)
