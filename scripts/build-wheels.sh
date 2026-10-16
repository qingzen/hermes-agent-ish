#!/bin/sh
# Build musl-i686 (iSH / iPhone x86 Alpine) wheels for every non-pure
# dependency Hermes Agent needs. Runs inside an alpine:3.19 i386 container.
#
#   docker run --platform linux/386 -v "$PWD:/out" alpine:3.19 /out/scripts/build-wheels.sh
#
# Output: /out/wheelhouse/*.whl  (cp311, musllinux_1_2_i686)
set -eu

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.19}"
OUT="${OUT:-/out/wheelhouse}"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

say "repos + toolchain (${ALPINE_BRANCH}/x86, python 3.11)"
printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n' \
    "$ALPINE_BRANCH" "$ALPINE_BRANCH" > /etc/apk/repositories
apk update >/dev/null
apk add --no-cache \
    python3 python3-dev py3-pip build-base musl-dev pkgconf \
    openssl-dev libffi-dev zlib-dev libjpeg-turbo-dev freetype-dev \
    libimagequant-dev lcms2-dev openjpeg-dev tiff-dev \
    curl ca-certificates bash util-linux-misc >/dev/null

# rust comes from edge (3.19's 1.76 cannot parse lockfile v4 / pydantic-core MSRV)
printf 'https://dl-cdn.alpinelinux.org/alpine/edge/main\n' >> /etc/apk/repositories
apk update >/dev/null
apk add --no-cache rust cargo patchelf >/dev/null

python3 -V
setarch linux32 python3 -c 'import sysconfig;print("platform:",sysconfig.get_platform())'

setarch linux32 python3 -m venv /build >/dev/null
/build/bin/python -m pip install -q --no-cache-dir --upgrade \
    pip maturin setuptools wheel pybind11 'setuptools-rust>=1.8' setuptools-scm

mkdir -p "$OUT" /src
build_sdist() { # name version
    _n="$1"; _v="$2"
    _dir=/src/$_n-$_v
    [ -d "$_dir" ] && return 0
    _url=$(/build/bin/python - "$_n" "$_v" <<'PY'
import json, sys, urllib.request
name, ver = sys.argv[1], sys.argv[2]
d = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{ver}/json"))
print(next(f["url"] for f in d["urls"] if f["filename"].endswith((".tar.gz", ".zip"))))
PY
)
    curl -sL "$_url" -o /src/pkg.tgz
    tar xf /src/pkg.tgz -C /src
}
# a plain tar.gz sdist (no PEP 517 backend dance needed)
build_tarball() { build_sdist "$1" "$2"; }

say "cffi (cryptography build dep + hermes dep)"
apk del py3-cffi >/dev/null 2>&1 || true
build_tarball cffi 2.0.0
( cd /src/cffi-2.0.0 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps -w "$OUT" . )

say "MarkupSafe"
build_tarball MarkupSafe 3.0.2
( cd /src/MarkupSafe-3.0.2 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps -w "$OUT" . )

say "PyYAML 6.0.3"
build_tarball pyyaml 6.0.3
( cd /src/pyyaml-6.0.3 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps -w "$OUT" . )

say "psutil 7.2.2"
build_tarball psutil 7.2.2
( cd /src/psutil-7.2.2 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps -w "$OUT" . )

say "Pillow 12.2.0"
build_tarball pillow 12.2.0
( cd /src/pillow-12.2.0 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps --no-build-isolation -w "$OUT" . )

say "ruamel.yaml.clib 0.2.15"
build_tarball ruamel.yaml.clib 0.2.15
( cd /src/ruamel.yaml.clib-0.2.15 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps -w "$OUT" . )

say "jiter 0.13.0 (rust, openai SDK hard dep)"
build_tarball jiter 0.13.0
rm -f /src/jiter-0.13.0/Cargo.lock
( cd /src/jiter-0.13.0 && setarch linux32 /build/bin/maturin build --release --out "$OUT" )

say "pydantic-core 2.46.4 (rust)"
build_tarball pydantic-core 2.46.4
rm -f /src/pydantic_core-2.46.4/Cargo.lock 2>/dev/null || true
rm -f /src/pydantic-core-2.46.4/Cargo.lock 2>/dev/null || true
( cd /src/pydantic_core-2.46.4 && setarch linux32 /build/bin/maturin build --release --out "$OUT" )

say "cryptography 46.0.7 (rust + openssl)"
build_tarball cryptography 46.0.7
rm -f /src/cryptography-46.0.7/src/rust/Cargo.lock
( export PATH="/build/bin:$PATH"; cd /src/cryptography-46.0.7 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps --no-build-isolation -w "$OUT" . )

say "uvloop 0.21.0"
build_tarball uvloop 0.21.0
( cd /src/uvloop-0.21.0 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps --no-build-isolation -w "$OUT" . )

say "httptools 0.6.4"
build_tarball httptools 0.6.4
( cd /src/httptools-0.6.4 && setarch linux32 /build/bin/pip wheel --no-cache-dir --no-deps --no-build-isolation -w "$OUT" . )

say "watchfiles 1.0.1 (rust)"
build_tarball watchfiles 1.0.1
rm -f /src/watchfiles-1.0.1/Cargo.lock
( cd /src/watchfiles-1.0.1 && setarch linux32 /build/bin/maturin build --release --out "$OUT" )

say "result"
ls -la "$OUT"
setarch linux32 python3 - <<'PY'
import glob, zipfile, json
for w in sorted(glob.glob("/out/wheelhouse/*.whl")):
    z = zipfile.ZipFile(w)
    meta = [n for n in z.namelist() if n.endswith(".dist-info/WHEEL")]
    tags = []
    if meta:
        for line in z.read(meta[0]).decode().splitlines():
            if line.startswith("Tag:"):
                tags.append(line.split(":", 1)[1].strip())
    print(f"{w.split('/')[-1]:60s} {tags}")
PY