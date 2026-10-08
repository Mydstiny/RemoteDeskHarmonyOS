#!/bin/sh
set -eu
apk add --no-cache build-base perl linux-headers ca-certificates
cd /work
printf '%s  %s\n' a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2 openssl-3.5.8.tar.gz | sha256sum -c -
mkdir -p musl-src output-musl/bin output-musl/licenses
tar -xzf openssl-3.5.8.tar.gz -C musl-src
cd musl-src/openssl-3.5.8
./Configure linux-x86_64 no-shared no-module no-tests no-zlib --prefix=/opt/remotedesk-pro/openssl -static
make -j4 build_sw
cp apps/openssl /work/output-musl/bin/openssl
cp LICENSE.txt /work/output-musl/licenses/OpenSSL-LICENSE.txt
strip /work/output-musl/bin/openssl
OPENSSL_CONF=/dev/null /work/output-musl/bin/openssl version -a
ldd /work/output-musl/bin/openssl || true
sha256sum /work/output-musl/bin/openssl
apk info -vv > /work/output-musl/build-packages.txt
gcc --version > /work/output-musl/gcc-version.txt
cp configdata.pm /work/output-musl/configdata.pm
