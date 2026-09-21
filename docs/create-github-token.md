# Creating a GitHub token

The agent needs a **personal access token (PAT)** that can (a) read the pull
requests it reviews and (b) post a comment back. Pick either token type — if
you're unsure, use a **classic** token, it's two clicks.

## What the token has to be able to do

| The agent does | Needs |
|---|---|
| `gh pr list`, `gh pr view`, `gh pr diff` | read access to the repo's **contents** and **pull requests** |
| `gh pr comment` (posting the review) | **write** access to pull requests / comments |
| clone the repo (only if it's private) | read access to **contents** |

## Option A — classic token (simplest)

1. GitHub → your avatar → **Settings**
2. **Developer settings** → **Personal access tokens** → **Tokens (classic)**
3. **Generate new token** → **Generate new token (classic)**
4. **Note:** `sandbox-code-reviewer`
5. **Expiration:** long enough to outlive the demo (e.g. 30 days)
6. **Scopes:** tick **`repo`** — that covers everything above.
   (Only ever reviewing **public** repos? `public_repo` is enough.)
7. **Generate token**, copy it (it's shown once) → into `.env` as `github_token`

If the repo lives in an organisation that uses SAML SSO, click **Configure SSO**
next to the new token afterwards and authorise that organisation, or the token
will 404 on those repos.

## Option B — fine-grained token (least privilege)

1. Same place, but **Tokens (fine-grained)** → **Generate new token**
2. **Token name:** `sandbox-code-reviewer` · **Expiration:** e.g. 30 days ·
   **Resource owner:** you (or the org)
3. **Repository access** → *Only select repositories* → choose the repo you'll
   review (your fork counts)
4. **Permissions** → add:
   - **Contents: Read** — read the code and diffs
   - **Pull requests: Read and write** — read PRs and post reviews/comments
   - **Issues: Read and write** — PR comments are posted through the issue
     comments API, so this is needed for `gh pr comment`
   - *Metadata: Read* is added automatically
5. Generate, copy → into `.env` as `github_token`

Org-owned repo? A fine-grained token may need the org to approve it before it
works.

## Put it in `.env`

```ini
github_token=ghp_xxxxxxxxxxxxxxxxxxxx
```

- `.env` is gitignored — never commit it.
- At deploy time the token is injected into the sandbox as `GH_TOKEN`, which the
  `gh` CLI picks up automatically.

## Check it works

```bash
set -a; . ./.env; set +a

# which account does it belong to?
curl -sS -H "Authorization: Bearer $github_token" https://api.github.com/user | jq -r .login

# can it see the repo you're going to review?
curl -sS -H "Authorization: Bearer $github_token" "https://api.github.com/repos/${target_repo}" \
  | jq -r '.full_name // .message'

# classic tokens only: which scopes does it have?
curl -sSI -H "Authorization: Bearer $github_token" https://api.github.com/user | grep -i x-oauth-scopes
```

Fine-grained tokens don't return an `x-oauth-scopes` header — a missing line
there is expected.

Finally, `./deploy.sh verify` should show `GH_TOKEN=set` (it confirms the token
reached the sandbox; it doesn't validate its permissions).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `404 Not Found` reading the repo | the token can't see it (private repo, or not in the fine-grained selection) | add the repo under *Repository access*, or use a classic `repo` token |
| `403` listing or reading PRs | read permission missing | *Pull requests: Read* + *Contents: Read* |
| `403` when the agent posts the comment | write permission missing | *Pull requests: Read and write* (+ *Issues: Read and write*) |
| Works on one repo, fails on another | fine-grained tokens are scoped per repository | select each repo explicitly, or use a classic token |
| Org repo 404/403 despite the above | SSO not authorised, or the fine-grained token isn't approved yet | classic: **Configure SSO**; fine-grained: ask an org owner to approve it |

## Don't

- Don't commit the token, paste it into a PR, or hard-code it in a script.
- Don't grant more access than the demo needs — `repo` on a classic token, or one
  repo on a fine-grained token.
- Don't reuse a long-lived admin token; give it an expiry.
