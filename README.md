# rust-dev-image

A container image for Rust development with [Claude Code][cc] preinstalled.

The image carries the stable toolchain with `clippy` and `rust-analyzer`, plus
a pinned nightly for `rustfmt`. The cargo tooling covers tests (`nextest`),
dependency and license audits (`deny`, `machete`), binary size and codegen
(`bloat`, `llvm-lines`) and coverage (`llvm-tools`, `rustfilt`), with `dprint`
as a configurable formatter for other file types. Also `node`, `git`, `yq`,
`shellcheck` and `yamllint`.

[cc]: https://claude.com/claude-code

## Requirements

`podman` (or Docker, via `make image CONTAINER_ENGINE=docker`), `git`, `curl`,
GNU `make` 3.82+, `bash` 4+, `yq` and `yamllint`. Built and tested on
`linux/amd64` and `linux/arm64`.

## Quick start

```sh
make help     # List available targets
make check    # Build the image, then smoke test it
make info     # Show the image's build timestamp and provenance labels
```

The image is tagged `rust-dev:<git-hash>` and `rust-dev:latest`. The current
Claude Code release is resolved and installed on every rebuild.

Image sources are in [`image/`](image/), which comprises the build context.

## Running the image

```sh
podman run --rm -it \
  -v "$PWD:/work" -w /work \
  -v rust-dev-cache:/var/cache/rust-dev \
  -v ~/.gitconfig:/home/ubuntu/.gitconfig:ro \
  rust-dev:latest
```

| Mount            | What                                                              | Why                                                                                                         |
| ---------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `rust-dev-cache` | Build artifacts, crate registry, git checkouts, rustup toolchains | Kept off the repository mount, reused across containers. One build directory per crate; registry is shared. |
| `~/.gitconfig`   | Git configuration (read-only)                                     | Share commit identity without letting the container rewrite the host config.                                |

The cache volume is optional: without it caches are discarded with the
container.

The container user is `ubuntu` (uid 1000). On Linux, rootless podman needs
`--userns=keep-id:uid=1000,gid=1000` for the mounts to be writable by it, and
Docker needs a host uid of 1000.

Build output goes to `$CARGO_TARGET_BASE/<crate>` on the cache volume, not
`./target`; `rust-dev info` prints the path. Checkouts of the same crate share
it, and bare `cargo` uses `$CARGO_TARGET_BASE/default` for every project.

Toolchains a project installs, say through `rust-toolchain.toml`, persist on
the volume. The image's entrypoint links its own toolchains into it on every
start.

_Credentials_ — SSH agent, tokens, signing keys — are not covered here. How and
whether to make them available in the container will depend on your setup.

## Using the image

`rust-dev` is a command on the image's `PATH` that drives the installed tooling
with the conventions this image sets up, so a project needs no wiring of its own:

```sh
rust-dev help     # List available targets
rust-dev check    # fmt-check, lint and test
```

`check` also enforces markdown, TOML and YAML formatting, so a project adopting
the image will likely need a first `rust-dev fmt`.

| Target              | Runs                                                                                   |
| ------------------- | -------------------------------------------------------------------------------------- |
| `fmt` / `fmt-check` | `cargo fmt` on the pinned toolchain, then `dprint` for markdown, toml and yaml         |
| `lint`              | `cargo clippy`, then `shellcheck` and `yamllint` over the tracked shell and YAML files |
| `test`              | `cargo nextest run`                                                                    |
| `audit`             | `cargo deny check` and `cargo machete` (requires a `deny.toml`)                        |
| `check`             | `fmt-check`, `lint`, `test`                                                            |
| `info`              | Resolved cache key, target directory and rustfmt version                               |

Every command is a variable you can override, so a project keeps its own flags
without giving up the rest:

```sh
rust-dev test NEXTEST='cargo nextest run --no-fail-fast'
rust-dev lint SHELL_SOURCES='ci/*.sh'
```

`rust-dev` also sets `CARGO_TARGET_DIR` to a subdirectory named after the crate,
or in a workspace, after the alphabetically first member. Adding a member that
sorts first would move it, so a workspace is better named explicitly:

```sh
rust-dev check RUST_CACHE_KEY=my-monorepo
```

## Versions

[`versions.mk`](versions.mk) pins cargo tool versions, and the nightly
toolchain used for `rustfmt`.

Everything else resolves at build time, so the image tracks it: the
`ubuntu:resolute` base, apt packages, Rust `stable`, Node.js 24.x and Claude
Code. Only the Claude Code version is recorded, as the
`io.github.biochimia.rust-dev-image.claude-code-version` label.

The nightly `rustfmt` pin is here because this image targets nightly-only
rustfmt options. When not relying on unstable options, `make image
RUST_FMT_TOOLCHAIN=stable` builds an image without the second toolchain.
Plain `cargo fmt` uses stable.

## Supply chain

| Input            | Verified by                                                                        |
| ---------------- | ---------------------------------------------------------------------------------- |
| Ubuntu packages  | apt, against the distribution's signing keys                                       |
| Node.js          | NodeSource apt repo; its key is vendored, and checksum validated                   |
| Rust toolchains  | rustup, against signed manifests                                                   |
| `yq`             | SHA-256 from the release's own `checksums` asset                                   |
| `cargo-binstall` | SHA-256 of the tarball, captured when the version was pinned                       |
| cargo tools      | version-pinned; prebuilt binaries fetched by `cargo-binstall`, unverified          |
| Claude Code      | a vendored installer that checks the binary's SHA-256 against the release manifest |

Vendored files are documented in
[`image/vendor/README.md`](image/vendor/README.md).

## License

This project's sources are released under the [MIT](LICENSE) license. That does
not extend to the contents of the image built from them: Ubuntu packages,
Node.js, the Rust toolchain and Claude Code each carry their own terms.

In particular, Claude Code is proprietary. Be sure to check [Anthropic's
terms][legal] if you intend to distribute built images.

AI assistance in developing this project is acknowledged in
[ACKNOWLEDGMENTS](ACKNOWLEDGMENTS.md).

[legal]: https://code.claude.com/docs/en/legal-and-compliance
