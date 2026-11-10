# Optional: mirror a Gitea repository to another forge

The workspace does not require any forge to run. Agents work against the
filesystem, the `session/` envelope, and the sandbox; no GitLab, GitHub, or
Gitea account is needed for a session to start, execute, and complete.

This page covers the optional case where source lives in Gitea and you also
want a copy on GitHub or GitLab. Gitea's push mirror is the simplest path:
Gitea pushes on its own, so no CI job or webhook is involved.

## Gitea -> GitHub (verified end to end)

1. Create the empty target repository on GitHub and mint a token that can
   push to it (fine-grained with contents write, or classic with `repo`).
2. In Gitea open the repository, then Settings -> Repository -> Push mirrors
   -> Add push mirror. Set the target URL, the username, and the token as the
   password, and enable Sync when commits are pushed.
3. Equivalent API call:

   ```bash
   curl -X POST "https://<gitea-host>/api/v1/repos/<owner>/<repo>/push_mirrors" \
     -H "Authorization: token <gitea-token>" \
     -H "Content-Type: application/json" \
     -d '{"remote_address": "https://github.com/<owner>/<repo>.git",
          "remote_username": "<github-user>",
          "remote_password": "<github-token>",
          "sync_on_commit": true}'
   ```

4. Verify the target actually advanced. A 200 from a sync call only proves
   Gitea accepted the request:

   ```bash
   git ls-remote https://github.com/<owner>/<repo>.git refs/heads/main
   ```

   Compare that hash with `git rev-parse main` locally.

## Gitea -> GitLab

Same recipe with a GitLab URL and a personal access token carrying the
`write_repository` scope. Point `remote_address` at
`https://gitlab.com/<group>/<project>.git`, use the token as
`remote_password`, and verify with `git ls-remote` against the GitLab URL.

## Notes

- `sync_on_commit: true` mirrors on every push; without it only manual or
  interval syncs run.
- Mirrors are one-way: editing the target directly is overwritten or rejected
  on the next sync.
