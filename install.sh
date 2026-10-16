#!/bin/sh
# Hermes Agent installer for iSH Shell (iPhone / iPad, x86 Alpine)
#
# The official installer (https://hermes-agent.nousresearch.com/install.sh) cannot
# work here: iSH reports `uname -m` = i686 and the installer only pins `uv` builds
# for x86_64/aarch64, so it fails with "no pinned uv build for this platform".
#
#   curl -fsSL https://raw.githubusercontent.com/qingzen/hermes-agent-ish/main/install.sh | sh
#
# Re-runnable. Re-run to upgrade.
set -eu

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_VENV="${HERMES_VENV:-$HOME/.hermes/venv}"
HERMES_VERSION="${HERMES_VERSION:-0.19.0}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/qingzen/hermes-agent-ish/main}"
REPO_TARBALL="${REPO_TARBALL:-https://github.com/qingzen/hermes-agent-ish/archive/refs/heads/main.tar.gz}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.19}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
say "Checking environment"

[ "$(uname -s)" = "Linux" ] || die "This installer is for iSH (Linux). On Windows use install.ps1."

ARCH="$(uname -m)"
[ "$ARCH" = "i686" ] || warn "uname -m is '$ARCH', expected 'i686' — continuing anyway."

if [ -n "${TERMUX_VERSION:-}" ]; then
    die "Termux detected. Use 'pkg install hermes-agent' there, not this script."
fi

if [ "$(id -u)" = "0" ]; then
    APK="apk"; SUDO=""
else
    command -v doas >/dev/null 2>&1 && SUDO="doas" || SUDO="sudo"
    APK="$SUDO apk"
fi

cat /etc/alpine-release 2>/dev/null || die "Not an Alpine system — is this really iSH?"

# Alpine 3.22+ packages link against libc symbols (pwritev2/preadv2) that iSH's
# kernel does not implement, so python3 fails with "Error relocating ... symbol
# not found". Pin every repository to 3.19, which is also what iSH's default
# rootfs ships. Without this, the install succeeds and the binary never starts.
say "Pinning Alpine ${ALPINE_BRANCH}/x86 repositories"
$APK update >/dev/null 2>&1 || true
REPOS="/etc/apk/repositories"
[ -w "$REPOS" ] || REPOS="$HOME/.harmless-unused"
if [ -w "$REPOS" ]; then
    cp -f "$REPOS" "$REPOS.hermes-ish.bak" 2>/dev/null || true
    cat > "$REPOS" <<EOF
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community
EOF
    $APK update
else
    warn "$REPOS not writable; skipping pin (9999999999-apk-pin)."
fi

# ---------------------------------------------------------------- packages
say "Installing Python 3.11 and build tools"
# python3 on 3.19 = 3.11.14, which satisfies Hermes' requires-python >=3.11,<3.14.
ISH_PACKAGES="python3 python3-dev py3-pip py3-virtualenv py3-setuptools py3-wheel git curl ca-certificates bash ncurses build-base musl-dev openssl-dev libffi-dev zlib-dev pkgconf"
if ! $APK add --no-cache $ISH_PACKAGES; then
    # Older iSH kernels can SIGSYS third-party apk triggers (commonly glib's
    # gio-querymodules trigger). Package extraction normally completed before
    # the trigger phase. Retry without package scripts, then validate every
    # executable we actually rely on instead of treating an unrelated trigger
    # as a failed Hermes install.
    warn "An apk trigger failed (common on older iSH builds); retrying without scripts."
    # apk can keep returning the stale trigger failure even when every requested
    # package is already installed. Do not trust its status here; validate the
    # concrete executables below.
    $APK add --no-cache --no-scripts $ISH_PACKAGES || true
fi
command -v python3 >/dev/null 2>&1 || die "python3 was not installed. Update iSH, then rerun."
command -v git >/dev/null 2>&1 || die "git was not installed. Update iSH, then rerun."
command -v curl >/dev/null 2>&1 || die "curl was not installed. Update iSH, then rerun."
PY_MINOR="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
[ "$PY_MINOR" = "3.11" ] || die "Expected Python 3.11 after pinning Alpine 3.19, got '${PY_MINOR:-broken}'. Your rootfs has mixed Alpine packages; use iSH Settings > File Systems > Import/restore a clean Alpine 3.19 filesystem."

python3 -V

# ---------------------------------------------------------------- wheelhouse
say "Fetching prebuilt musl-i686 wheels"
# PyPI ships no musllinux i686 wheels for cryptography/pydantic-core/jiter/pillow/
# psutil/PyYAML/ruamel.yaml.clib/uvloop/httptools/watchfiles/cffi/MarkupSafe.
# Building them needs Rust + a C toolchain (slow and fragile on iSH), so they are
# prebuilt here: https://github.com/qingzen/hermes-agent-ish (scripts/build-wheels.sh)
WHEELHOUSE="${HERMES_HOME}/wheelhouse"
mkdir -p "$WHEELHOUSE"
TMPDIR_ISH="${TMPDIR:-/tmp}/hermes-ish.$$"
mkdir -p "$TMPDIR_ISH"
trap 'rm -rf "$TMPDIR_ISH"' EXIT INT TERM

curl -fsSL "$REPO_TARBALL" -o "$TMPDIR_ISH/repo.tar.gz" \
    || die "Could not download $REPO_TARBALL"
tar xzf "$TMPDIR_ISH/repo.tar.gz" -C "$TMPDIR_ISH"
SRC="$(find "$TMPDIR_ISH" -maxdepth 1 -type d -name 'hermes-agent-ish-*' | head -1)"
[ -n "$SRC" ] || die "Unexpected repository layout."
cp -f "$SRC"/wheelhouse/*.whl "$WHEELHOUSE"/ 2>/dev/null || true
cp -f "$SRC/constraints-ish.txt" "$WHEELHOUSE/constraints-ish.txt"
printf '%s\n' "$HERMES_VERSION" > "$WHEELHOUSE/.hermes-version"
echo "wheels: $(ls "$WHEELHOUSE"/*.whl 2>/dev/null | wc -l)"

# ---------------------------------------------------------------- venv
say "Creating virtualenv at $HERMES_VENV"
# --system-site-packages lets us reuse Alpine's prebuilt py3-cffi/py3-yaml/
# py3-greenlet/py3-uvloop/py3-httptools/py3-websockets/py3-numpy instead of
# compiling them on the device.
rm -rf "$HERMES_VENV"
python3 -m venv --system-site-packages "$HERMES_VENV"
PY="$HERMES_VENV/bin/python"
"$PY" -m pip install --no-cache-dir --upgrade pip setuptools wheel >/dev/null

# Alpine 3.19 has no py3-pydantic-core and its py3-pydantic is v1. Hermes needs
# pydantic v2, so pip uses the prebuilt pydantic-core from the wheelhouse.

# ---------------------------------------------------------------- install
say "Installing Hermes Agent ${HERMES_VERSION}"
if "$PY" -m pip install --no-cache-dir \
    --find-links "$WHEELHOUSE" \
    --constraint "$WHEELHOUSE/constraints-ish.txt" \
    "hermes-agent==${HERMES_VERSION}" >"$TMPDIR_ISH/pip.log" 2>&1; then
    cat "$TMPDIR_ISH/pip.log"
    PIP_STATUS=0
else
    PIP_STATUS=$?
    cat "$TMPDIR_ISH/pip.log"
fi

if [ "$PIP_STATUS" -ne 0 ]; then
    warn "Binary install failed. Retrying with source builds allowed."
    warn "This needs Rust (apk add rust cargo) and takes a long time on iSH."
    "$PY" -m pip install --no-cache-dir \
        --find-links "$WHEELHOUSE" \
        --constraint "$WHEELHOUSE/constraints-ish.txt" \
        "hermes-agent==${HERMES_VERSION}"
fi

# ---------------------------------------------------------------- launcher
say "Writing launcher"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/hermes" <<EOF
#!/bin/sh
exec "$HERMES_VENV/bin/hermes" "\$@"
EOF
chmod +x "$BIN_DIR/hermes"

PROFILE="$HOME/.profile"
touch "$PROFILE"
case ":${PATH}:" in
    *":$BIN_DIR:"*) ;;
    *)
        grep -q 'hermes-agent-ish' "$PROFILE" 2>/dev/null || cat >> "$PROFILE" <<EOF

# hermes-agent-ish
export PATH="\$HOME/.local/bin:\$PATH"
EOF
        warn "Added $BIN_DIR to PATH in ~/.profile — run: . ~/.profile"
        ;;
esac

# ---------------------------------------------------------------- verify
say "Verifying"
"$PY" -c "import hermes_cli" 2>/dev/null || warn "hermes_cli import check was inconclusive."
"$PY" -c "import pydantic, jiter; print('pydantic', pydantic.VERSION, '| jiter ok')" \
    || warn "pydantic/jiter import failed — see $TMPDIR_ISH/pip.log"
"$PY" -m pip check || true

BIN="$HERMES_VENV/bin/hermes"
if [ -x "$BIN" ]; then
    "$BIN" --version 2>/dev/null || true
fi

cat <<EOF

Hermes Agent is installed.

  launcher : $BIN_DIR/hermes
  venv     : $HERMES_VENV
  config   : $HERMES_HOME/config.yaml
  secrets  : $HERMES_HOME/.env

Next:

  hermes setup        # pick a provider and paste an API key
  hermes doctor       # health check
  hermes              # start chatting

iSH notes:
  - Keep iSH in the foreground while installing; iOS suspends background apps
    and a killed pip leaves a half-built venv (just re-run this script).
  - Do not 'apk upgrade'. Alpine 3.22+ breaks python3 on iSH.
  - The desktop app, dashboard browser automation and local models are not
    usable here; the CLI, the gateway and messaging platforms are.
EOF