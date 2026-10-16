# Hermes Agent for iSH Shell

Install [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) on an iPhone/iPad through [iSH](https://ish.app/).

> **Experimental compatibility port.** Hermes officially supports Linux, macOS and Windows. iSH emulates 32-bit x86 Linux on iOS; this repository supplies the missing `musl-i686` Python wheels and an iSH-specific installer.

## Install

1. Install **iSH Shell**.
2. Keep iSH open in the foreground. iOS suspends long background jobs.
3. Run:

```sh
apk add curl
curl -fsSL https://raw.githubusercontent.com/qingzen/hermes-agent-ish/main/install.sh | sh
. ~/.profile
hermes setup
hermes doctor
hermes
```

Re-run the same command to repair or upgrade the installation.

## What works

- Hermes terminal CLI
- Remote API providers
- File, shell, Git and standard agent tools
- Gateway/messaging features whose dependencies support i686
- Persistent config, memory, sessions and skills under `~/.hermes`

## Limits

- No Hermes desktop app.
- No local LLMs; iSH is a slow x86 emulator with strict iOS memory/runtime limits.
- Browser/computer-use binaries generally have no i686 build.
- Long gateway jobs stop when iOS suspends or kills iSH.
- Document extraction may be unavailable: `firecrawl-anydoc` has no i686 wheel.
- Some optional integrations can require native packages unavailable on i686.

## Why a custom installer exists

The official installer maps only `x86_64` and `aarch64` Linux targets. iSH reports:

```text
Linux
uname -m: i686
libc: musl
```

Therefore the official bootstrap stops with:

```text
no pinned uv build for this platform (Linux i686); Hermes does not support this host
```

PyPI also publishes no current i686-musl wheels for several mandatory dependencies, notably `jiter`, `pydantic-core`, `cryptography`, Pillow, psutil and PyYAML. Building Rust packages inside iSH is impractically slow. This repository ships reproducible wheels built in an Alpine x86 container.

## Alpine compatibility

The installer pins Alpine **3.19**. Do not run `apk upgrade` against newer branches.

Newer Alpine Python builds call Linux interfaces iSH does not currently implement. Python from Alpine 3.22 fails on iSH with errors like:

```text
Error relocating /usr/lib/libpython3.12.so.1.0: pwritev2: symbol not found
Error relocating /usr/lib/libpython3.12.so.1.0: preadv2: symbol not found
```

This is not a Hermes bug. See iSH issue [#2814](https://github.com/ish-app/ish/issues/2814).

## Security

- Wheels are committed publicly and listed in [`wheelhouse/SHA256SUMS`](wheelhouse/SHA256SUMS).
- [`scripts/build-wheels.sh`](scripts/build-wheels.sh) documents the build path.
- API keys belong in `~/.hermes/.env`, never in this repository.
- Review `install.sh` before piping it to `sh` if you prefer:

```sh
curl -fLO https://raw.githubusercontent.com/qingzen/hermes-agent-ish/main/install.sh
less install.sh
sh install.sh
```

## Build wheels

On a Docker host with `linux/386` support:

```sh
git clone https://github.com/qingzen/hermes-agent-ish
cd hermes-agent-ish
docker run --rm --platform linux/386 \
  -v "$PWD:/out" alpine:3.19 \
  sh /out/scripts/build-wheels.sh
sha256sum wheelhouse/*.whl > wheelhouse/SHA256SUMS
```

Build target: CPython 3.11, Alpine/musl, i686.

## Uninstall

```sh
rm -rf ~/.hermes/venv ~/.hermes/wheelhouse ~/.local/bin/hermes
```

Your Hermes state remains under `~/.hermes`. Remove it only if you also want to delete config, sessions, memory and skills:

```sh
rm -rf ~/.hermes
```

## Upstream

- Hermes Agent: https://github.com/NousResearch/hermes-agent
- Official docs: https://hermes-agent.nousresearch.com/docs
- iSH: https://github.com/ish-app/ish
