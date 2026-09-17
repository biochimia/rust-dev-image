# Vendored third-party artifacts

These files are **not this project's work** and are not covered by this
repository's LICENSE; each retains its upstream terms.

[`vendor-manifest.txt`](vendor-manifest.txt) is the record, and is always
tracked: one row per file giving its name, source URL, local filename, SHA-256
and file mode. A change of source, version or digest surfaces as a reviewable
diff even where the file itself is gitignored.

The build uses these local copies, managed by `scripts/vendor.sh` through these
make targets:

| Target               | Does                                                                           |
| -------------------- | ------------------------------------------------------------------------------ |
| `vendor-check`       | reports local files that don't match their recorded digests                    |
| `vendor`             | re-fetches anything missing or failing `vendor-check`, overwriting local edits |
| `vendor-check-drift` | re-fetches everything to confirm upstream still serves what was recorded       |
| `update`             | moves rows to newer upstream releases, rewriting the manifest and versions.mk  |

`make image` runs `make vendor` first.

Gitignored files are restored by re-fetching, which rests on an invariant worth
preserving when adding a row:

- a file fetched from a **versioned** URL (a GitHub release asset) may be
  gitignored, because the URL keeps serving that exact version;
- a file fetched from an **unversioned** URL must be **tracked**, because
  re-fetching it only ever returns whatever upstream serves today.

Every current row satisfies one or the other. A gitignored file behind an
unversioned URL would have no way back.

## Adding a file

Add a row with just the first three fields. Then `make update` fills in the
hash for GitHub release assets, and `make vendor` fetches the file, recording
its hash if upstream publishes none.

Fields are positional and whitespace-separated, so an omitted column has to be
the last one — a row cannot leave the hash blank while still naming a mode.
