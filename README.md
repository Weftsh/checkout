# Weft Checkout

Check out your repository from a [Weft mirror](https://weft.sh/mirror) instead
of github.com. One line replaces `actions/checkout`; if the mirror cannot serve
the commit, `actions/checkout` runs instead and the job says why.

```yaml
- uses: weftsh/checkout@v1
  with:
    repository: acme/widget          # the mirror on Weft, org/repo
    token: ${{ secrets.WEFT_TOKEN }}  # repo:read; omit for a public mirror
```

## Why

A mirror on Weft is served straight from object storage, close to the runner,
with the [freshness contract](https://weft.sh/docs/freshness-contract/) behind
it: a commit the mirror does not have yet is fetched from your origin before
the response, within a bounded budget, or refused by name. There is no way to
get a stale tree. Developers keep pushing to GitHub; only the CI read path
moves.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `repository` | `<org>/<this repo's name>` | The mirror on Weft, as `org/repo`. |
| `org` | | The Weft organization, used when `repository` is not given. |
| `token` | | A Weft token with `repo:read` on the mirror. Not needed for a public mirror. Sent as a header, never in the URL, never written to disk. |
| `ref` | `${{ github.sha }}` | The commit to check out. Must be a commit id; a branch name takes the fallback. |
| `fetch-depth` | `1` | `1` for the commit alone, `0` for full history. Anything else takes the fallback. |
| `path` | | Where to put the repository, relative to the workspace. |
| `api-url` | `https://api.weft.sh` | The Weft deployment. |
| `fallback` | `true` | Run `actions/checkout` when the mirror cannot serve. `false` fails the step with the mirror's reason instead. |
| `timeout-seconds` | `10` | How long to wait for the mirror to answer the probe. |

## Outputs

| Output | Meaning |
|---|---|
| `source` | `weft` when the mirror served the checkout, `fallback` when `actions/checkout` did. |
| `commit` | The commit checked out. |
| `reason` | Why the fallback ran, when it did. |

## What takes the fallback

Every one of these is reported on the job as a notice with the reason:

- the mirror does not answer within `timeout-seconds`, or the token cannot
  see it (a private mirror with no token answers as if it did not exist);
- the commit is not on the mirror **and** a synchronous sync of the origin
  did not surface it, or the sync exceeded the freshness budget. The
  mirror's own sentence is in the notice;
- the commit has been superseded on its branch. Today a mirror serves the
  tip of every branch and tag, plus the commits its compaction has
  checkpointed; a commit that a newer push has moved past is refused by
  name (the mirror says so, and the notice carries its sentence). A job
  queued behind a burst of pushes, or a re-run of an older commit, takes
  the fallback. This is a known limit of the serving engine, tracked on
  the Weft side; it never produces a stale tree;
- a `pull_request` event with the default `ref`. `github.sha` there is a
  merge commit GitHub makes for the run and no mirror carries it. To check
  the PR head out from the mirror:

  ```yaml
  - uses: weftsh/checkout@v1
    with:
      repository: acme/widget
      token: ${{ secrets.WEFT_TOKEN }}
      ref: ${{ github.event.pull_request.head.sha }}
  ```

Set `fallback: false` to make any of these fail the job instead, which is
what you want on a workflow whose purpose is to prove the mirror.

## What the checkout looks like

`HEAD` is detached at the requested commit, exactly as `actions/checkout`
leaves it. Two remotes are set: `weft`, the mirror the objects came from, and
`origin`, the GitHub repository, so a later `git push origin` goes where a
developer's push goes. Neither carries a credential: the mirror is read-only
and a push needs the forge's own token, the same as
`actions/checkout` with `persist-credentials: false`.

## Getting a mirror

[Mirror in 5 minutes](https://weft.sh/docs/quickstart-mirror/): paste the
GitHub URL in the dashboard, or install the Weft app for a private origin and
pick the repository. Then mint a `repo:read` token for CI and store it as a
repository secret.

## License

MIT.
