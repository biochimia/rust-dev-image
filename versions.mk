# Pinned tool versions
CARGO_BLOAT_VERSION      ?= 0.12.1
CARGO_DENY_VERSION       ?= 0.20.2
CARGO_LLVM_LINES_VERSION ?= 0.4.48
CARGO_MACHETE_VERSION    ?= 0.9.2
CARGO_NEXTEST_VERSION    ?= 0.9.146
DPRINT_VERSION           ?= 0.57.4
RUSTFILT_VERSION         ?= 0.2.1
RUST_FMT_TOOLCHAIN       ?= nightly-2026-09-17
# Not every nightly ships Miri: check it is available before bumping.
MIRI_TOOLCHAIN           ?= nightly-2026-09-17
