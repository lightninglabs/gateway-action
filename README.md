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

1. **Mint token** — [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)
   mints an installation token from the consumer's `app_id` / `private_key`,
   scoped to read `lightninglabs/gateway`. Using GitHub's own public action
   here sidesteps the chicken-and-egg of "the token-minting script lives in the
   private repo."
2. **Checkout runtime** — [`actions/checkout`](https://github.com/actions/checkout)
   pulls `lightninglabs/gateway` at a pinned ref using that token.
3. **Run** — execs `scripts/run-review.sh` from the checked-out tree, the same
   entry point as the private action. `run-review.sh` mints its own token for
   its `gh` calls, so the checkout token is not reused.

No new trust exposure: the consumer already runs this exact runtime today —
this only changes *where the entry point resolves*.

## Usage

Copy [`templates/gateway.yml`](templates/gateway.yml) to
`.github/workflows/gateway.yml` in your consumer repo and fill in the three
marked values. Minimal shape:

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
          installation_id: <INSTALLATION_ID>
          app_id:                  ${{ secrets.GATEWAY_APP_ID }}
          private_key:             ${{ secrets.GATEWAY_PRIVATE_KEY }}
          anthropic_api_key:       ${{ secrets.ANTHROPIC_API_KEY }}
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Pin `uses:` to a **full commit SHA** with a trailing `# vX.Y.Z` comment — never
a bare tag. Full onboarding (App install, secrets, installation id) lives in the
private repo's `docs/consumer-setup.md`.

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
| `v0.4.2`       | `v0.4.2`            |

## License

[MIT](LICENSE)
