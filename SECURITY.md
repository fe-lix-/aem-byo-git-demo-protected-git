# Security and public sharing

## Keep environment-specific data local

Only generic configuration, documentation, tests, and source code belong in
this repository. Use reserved documentation IP ranges, `example.com` domains,
and the example account ID `123456789012` in committed examples.

Do not commit:

- Tokens, passwords, private keys, or AWS credentials.
- Real account IDs, IAM principals, repository URLs, customer names, site IDs,
  or approved public IP allowlists.
- Terraform state, saved plans (including extensionless `tfplan`), local variable
  files, provider downloads, or crash logs.
- Generated AWS inspection output, secret-scanner reports, or separate site
  checkouts.

`.gitignore` is a safeguard, not a guarantee: it does not protect files that
are already tracked, and files can be force-added. Inspect staged changes
before every commit. Supply `HLX_TOKEN` and `CM_SECRET` out of band and unset
them after use. Never put literal credentials in shell history or enable
HTTP debug logging when using them.

## Before publishing

1. Review `git status --short`, `git diff --cached`, and `git ls-files`. Confirm
   there are no embedded repositories, private configuration, or generated files.
2. Run the validation commands in `README.md`, including the script tests.
3. Scan the entire reachable Git history and the prospective tracked snapshot
   with a secret scanner such as Gitleaks. Review identifiers and commit metadata
   manually too: account IDs, customer details, and personal email addresses may
   not be detected as secrets. Do not scan or publish ignored local checkouts.
4. Check every branch and tag, not just `main`. Publish only the intended clean
   history; do not use `git push --mirror` or `git push --all` blindly.
5. Share a clean clone of the sanitized Git history, **not a ZIP of this working
   directory**. Ignored files may still contain private deployment information.

Offline and mocked tests do not establish deployment or network readiness.
Secret scans reduce risk but cannot prove that a repository contains no
sensitive information. Confirm permission to publish the code and dependencies.

## If sensitive information was committed

Revoke or rotate exposed credentials first. Removing a file or squashing Git
history does not revoke a credential. Rewrite all affected branches/tags, remove
obsolete refs and reflogs, and prune unreachable local objects only after review.
Do not change the Git metadata of separate site checkouts during cleanup.

A local rewrite does not change a remote repository, forks, clones, pull-request
refs, or cached commit views. Coordinate any force-push with collaborators,
record the expected old remote commit for an explicit force-with-lease, and
have collaborators reclone. Contact the hosting provider if sensitive material
remains accessible in caches or hidden refs. Never publish old backup refs.
