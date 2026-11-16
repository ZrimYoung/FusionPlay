# Mac receiver baseline

Repository: https://github.com/ZrimYoung/FusionPlay-Android

Base branch: fix/miplay-port-conflict

Base commit: cab808224244ddf7dc3f53a260225e362e05ce2e

Development branch: feat/macos-receiver

The separate checkout was cloned without hardlinks from the existing repository,
then reset by checkout to the committed base. No Android working-tree changes
were copied. Runtime data and build products live outside this source checkout.

Initial host: Apple Silicon; Swift 6.2.3; Rust 1.99.1.
The deployment target is macOS 14; older target compatibility requires CI/build
verification and is not equivalent to testing on a physical macOS 14 machine.


Mac 0.3.1 UI development baseline (2026-11-16): `720571df6a3a315a86a27937cfac15a0c26e175f` from `origin/main`, checked out on independent `feat/macos-ui-refinement`. Runtime application/configuration remain on the internal disk.
