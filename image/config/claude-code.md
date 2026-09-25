# rust-dev-image

You are running inside rust-dev-image, a container for Rust development. The
conventions below hold for any project mounted here, whether or not the project
mentions the image.

## `rust-dev`

`rust-dev` is on `PATH` and drives the image's tooling, so it works on any
project with no setup there. Prefer it over hand-assembled `cargo` invocations:

- `rust-dev help`: list targets
- `rust-dev check`: `fmt-check`, `lint` and `test`; run it before calling work
  done
- `rust-dev fmt`: `cargo fmt` on the pinned rustfmt toolchain, then `dprint`
  for markdown, TOML and YAML
- `rust-dev miri`: tests under Miri, for undefined behavior in `unsafe` code;
  slow, so run it when touching `unsafe`, not on every change
- `rust-dev info`: cache key, `CARGO_TARGET_DIR` and rustfmt version

Every command is a make variable that can be overridden per invocation, e.g.
`rust-dev test NEXTEST='cargo nextest run -p foo'`. Read `$(command -v
rust-dev)` for the full list.

A project's own `Makefile`, `justfile` or CI config, where present, is the
authority over `rust-dev`.

## Build output

Build output is not in `./target`. It goes to `$CARGO_TARGET_BASE/<crate>` on
a cache volume; `rust-dev info` prints the exact path. Bare `cargo` uses
`$CARGO_TARGET_BASE/default` instead, so look there for artifacts from a plain
`cargo build`.

## Toolchains

- `stable` is the default, with `clippy`, `rust-analyzer` and
  `llvm-tools-preview`.
- `rustfmt` comes from a pinned toolchain, `$RUST_FMT_TOOLCHAIN`: use
  `cargo +$RUST_FMT_TOOLCHAIN fmt`, or `rust-dev fmt`. Plain `cargo fmt` uses
  stable and may disagree with the project's configured options.
- Miri comes from a pinned nightly, `$MIRI_TOOLCHAIN`: use
  `cargo +$MIRI_TOOLCHAIN miri test`, or `rust-dev miri`.

The image's toolchains cannot take new components: `rustup component add`
for them fails with a cross-device rename error, by design. Don't work
around it; tell the user which component is missing. Installing another
toolchain works, and it persists on the cache volume.

## Other tools

- Cargo: `cargo nextest`, `cargo deny`, `cargo machete`, `cargo bloat`,
  `cargo llvm-lines`, `rustfilt`
- Formatting and linting: `dprint`, `shellcheck`, `yamllint`
- General: `git`, `yq`, `node`/`npm`, `bc`, GNU `time` (`/usr/bin/time -v`)

`cargo binstall` is available, but anything installed with it is lost when the
container exits.
