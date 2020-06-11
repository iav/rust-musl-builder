# to build need to use set of 3 ARGs:
# amd64) --build-arg OPENSSL_TARGET=linux-x86_64 --build-arg LD_MUSL_ARCH=x86_64 --build-arg  TRIPLET=x86_64-linux-gnu --build-arg RUST_TARGET=x86_64-unknown-linux-musl
# arm)   --build-arg OPENSSL_TARGET=linux-armv4 --build-arg LD_MUSL_ARCH=armhf --build-arg  TRIPLET=arm-linux-gnueabihf --build-arg RUST_TARGET=armv7-unknown-linux-musleabihf
# arm64) --build-arg OPENSSL_TARGET=linux-aarch64 --build-arg LD_MUSL_ARCH=aarch64 --build-arg TRIPLET=aarch64-linux-gnu --build-arg RUST_TARGET=aarch64-unknown-linux-musl

# success:
# docker build --build-arg OPENSSL_TARGET=linux-armv4 --build-arg LD_MUSL_ARCH=armhf --build-arg  TRIPLET=arm-linux-gnueabihf --build-arg RUST_TARGET=armv7-unknown-linux-musleabihf --build-arg RUSTUSERID=$(id -u) --build-arg BASE_IMAGE=ubuntu:19.10 --build-arg POSTGRESQL_VERSION=11.7 --build-arg OPENSSL_VERSION=1.1.1g -f Dockerfile -t b:ub1910-pg11.7-ssl1.1.1g ../..

# 20.04 bug in sudo https://github.com/sudo-project/sudo/issues/42
# workaround echo "Set disable_coredump false" >> /etc/sudo.conf
#ARG BASE_IMAGE=ubuntu:18.04
#ARG BASE_IMAGE=ubuntu:20.04
ARG BASE_IMAGE=ubuntu:19.10
#ARG BASE_IMAGE=debian:10-slim

FROM $BASE_IMAGE as builder

ARG TARGETPLATFORM
ARG TARGETARCH

RUN echo "Hello, my CPU architecture is $(uname -m)"
RUN echo $TARGETPLATFORM $TARGETARCH

ARG TRIPLET=x86_64-linux-gnu
#ARG TRIPLET=arm-linux-gnueabihf
#ARG TRIPLET=aarch64-linux-gnu

ARG RUST_TARGET=x86_64-unknown-linux-musl
#ARG RUST_TARGET=armv7-unknown-linux-musleabihf
#ARG RUST_TARGET=aarch64-unknown-linux-musl

ARG LD_MUSL_ARCH=x86_64
#ARG LD_MUSL_ARCH=armhf
#ARG LD_MUSL_ARCH=aarch64

ARG OPENSSL_TARGET=linux-x86_64
#ARG OPENSSL_TARGET=linux-armv4
#ARG OPENSSL_TARGET=linux-aarch64

ENV MUSL_PREFIX=/musl

ARG RUSTUSERID=10001


# RUN case "${TARGETARCH##*-}" in \
        # amd64) OPENSSL_TARGET=linux-x86_64 && TRIPLET=arm-linux-gnueabihf ;; \
        # arm) OPENSSL_TARGET=linux-armv4 && TRIPLET=arm-linux-gnueabihf ;; \
        # arm64) OPENSSL_TARGET=linux-aarch64 RUST_TARGET=aarch64-unknown-linux-musl ;;\
        # *) echo >&2 "unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    # esac;

# The Rust toolchain to use when building our image.  Set by `hooks/build`.
ARG TOOLCHAIN=stable

# The OpenSSL version to use. We parameterize this because many Rust
# projects will fail to build with 1.1.
ARG OPENSSL_VERSION=1.1.1g
ENV OPENSSL_VERSION=$OPENSSL_VERSION

ARG POSTGRESQL_VERSION=11.7
ENV POSTGRESQL_VERSION=$POSTGRESQL_VERSION

# Make sure we have basic dev tools for building C libraries.  Our goal
# here is to support the musl-libc builds and Cargo builds needed for a
# large selection of the most popular crates.
#
# We also set up a `rust` user by default, in whose account we'll install
# the Rust toolchain.  This user has sudo privileges if you need to install
# any more software.
#


ENV DEBIAN_FRONTEND=noninteractive

RUN   apt-get update && apt-get upgrade -y && \
      apt-get install -y \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        file \
#        mc \
        git \
        musl-dev \
        musl-tools \
        libpq-dev \
        libsqlite-dev \
        libssl-dev \
        linux-libc-dev \
#       pkg-config \
        pkgconf \
        sudo \
#   wget \
        xutils-dev \
#       gcc-multilib
#        gcc-multilib-arm-linux-gnueabihf \
#        gcc-arm-linux-gnueabihf
        && \
    apt-get clean && rm -rf /var/lib/apt/lists/* 
    
RUN    useradd rust --user-group --create-home --shell /bin/bash --groups sudo -u $RUSTUSERID

# Static linking for C++ code
RUN sudo ln -s "/usr/bin/g++" "/usr/bin/musl-g++"

RUN echo "$$MUSL_PREFIX/lib" >> /etc/ld-musl-${LD_MUSL_ARCH}.path

# Allow sudo without a password.
#ADD sudoers /etc/sudoers.d/nopasswd
RUN echo "rust   ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers.d/rust

# Run all further code as user `rust`, and create our working directories
# as the appropriate user.
USER rust
RUN mkdir -p /home/rust/libs /home/rust/src

# Set up our path with all our binary directories, including those for the
# musl-gcc toolchain and for our Rust toolchain.
ENV PATH=/home/rust/.cargo/bin:$MUSL_PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    
# Set up a `git credentials` helper for using GH_USER and GH_TOKEN to access
# private repositories if desired.
#ADD git-credential-ghtoken /usr/local/bin
#RUN git config --global credential.https://github.com.helper ghtoken

WORKDIR /tmp
RUN echo "Building zlib" && \
    cd /tmp && \
    ZLIB_VERSION=1.2.11 && \
    curl -fLO "http://zlib.net/zlib-$ZLIB_VERSION.tar.gz" && \
    tar xzf "zlib-$ZLIB_VERSION.tar.gz" && cd "zlib-$ZLIB_VERSION" && \
    CC="musl-gcc -fPIE -pie" ./configure --static --prefix=$MUSL_PREFIX && \
    make && sudo make install    && \
    rm -r /tmp/*


# Build a static library version of OpenSSL using musl-libc.  This is needed by
# the popular Rust `hyper` crate.
#
# We point /usr/local/musl/include/linux at some Linux kernel headers (not
# necessarily the right ones) in an effort to compile OpenSSL 1.1's "engine"
# component. It's possible that this will cause bizarre and terrible things to
# happen. There may be "sanitized" header
RUN echo "Building OpenSSL" && \
    sudo mkdir -p $MUSL_PREFIX/include && \
    sudo ln -s /usr/include/linux $MUSL_PREFIX/include/linux && \
    sudo ln -s /usr/include/$TRIPLET/asm $MUSL_PREFIX/include/asm && \
    sudo ln -s /usr/include/asm-generic $MUSL_PREFIX/include/asm-generic
#   && \

WORKDIR /tmp
# FIXME: --no-check-certificate added to workaround ssl error on docker in buildx for arm32 on github builder 20200703
RUN curl -fLO "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" && \
    tar xvzf "openssl-$OPENSSL_VERSION.tar.gz" && \
    echo $OPENSSL_TARGET && cd "openssl-$OPENSSL_VERSION" && \
    env CC="musl-gcc -fPIE -pie" ./Configure  no-zlib -fPIC no-afalgeng \
    --prefix=$MUSL_PREFIX --openssldir=$MUSL_PREFIX/ssl \
    -DOPENSSL_NO_SECURE_MEMORY ${OPENSSL_TARGET} && \
    env C_INCLUDE_PATH=$MUSL_PREFIX/include/ make depend && \
    env C_INCLUDE_PATH=$MUSL_PREFIX make && \
    sudo make install_sw \
   && \
    sudo rm $MUSL_PREFIX/include/linux $MUSL_PREFIX/include/asm $MUSL_PREFIX/include/asm-generic && \
    rm -r /tmp/*


# FIXME: --no-check-certificate added to workaround ssl error on docker in buildx for arm32 on github builder 20200703
RUN echo "Building libpq" && \
    cd /tmp && \
    curl -fLO "https://ftp.postgresql.org/pub/source/v$POSTGRESQL_VERSION/postgresql-$POSTGRESQL_VERSION.tar.gz" && \
    tar xzf "postgresql-$POSTGRESQL_VERSION.tar.gz" && \
    cd "postgresql-$POSTGRESQL_VERSION" && \
    CC="musl-gcc -fPIE -pie" CPPFLAGS=-I$MUSL_PREFIX/include LDFLAGS=-L$MUSL_PREFIX/lib ./configure --with-openssl --without-readline --prefix=$MUSL_PREFIX && \
    cd src/interfaces/libpq && make all-static-lib && sudo make install install-lib-static && \
    cd ../../bin/pg_config && make && sudo make install    && \
    rm -r /tmp/*

ENV TARGET=$RUST_TARGET \
    CARGO_BUILD_TARGET=$RUST_TARGET \
    OPENSSL_DIR=$MUSL_PREFIX \
#    OPENSSL_INCLUDE_DIR=$MUSL_PREFIX/include \
#    OPENSSL_LIB_DIR=$MUSL_PREFIX/lib \
    OPENSSL_STATIC=1 \
#    ARMV7_UNKNOWN_LINUX_MUSLEABIHF_OPENSSL_DIR=$MUSL_PREFIX \
#    ARMV7_UNKNOWN_LINUX_GNUEABIHF_OPENSSL_DIR=/usr \
    CC=musl-gcc \
    DEP_OPENSSL_INCLUDE=$MUSL_PREFIX/include \
#   PQ_LIB_STATIC=1 \
    PQ_LIB_STATIC_X86_64_UNKNOWN_LINUX_MUSL=1 \
    PQ_LIB_STATIC_AARCH64_UNKNOWN_LINUX_MUSL=1 \
    PQ_LIB_STATIC_ARMV7_UNKNOWN_LINUX_MUSLEABIHF=1 \
    PG_CONFIG_X86_64_UNKNOWN_LINUX_GNU=/usr/bin/pg_config \
    PG_CONFIG_AARCH64_UNKNOWN_LINUX_GNU=/usr/bin/pg_config \
    PG_CONFIG_ARMV7_UNKNOWN_LINUX_GNU=/usr/bin/pg_config \
#    PG_CONFIG=/usr/bin/pg_config \
    PKG_CONFIG_PATH=$MUSL_PREFIX/lib/pkgconfig \
    PKG_CONFIG_ALLOW_CROSS=true \
    PKG_CONFIG_ALL_STATIC=true \
    LIBZ_SYS_STATIC=1
    

# Install our Rust toolchain and the `musl` target.  We patch the
# command-line we pass to the installer so that it won't attempt to
# interact with the user or fool around with TTYs.  We also set the default
# `--target` to musl so that our users don't need to keep overriding it
# manually.
RUN curl https://sh.rustup.rs -sSf | \
    sh -s -- -y --default-toolchain $TOOLCHAIN && \
    rustup target add $RUST_TARGET
#    rustup target add x86_64-unknown-linux-musl && \
#    rustup target add armv7-unknown-linux-musleabihf
#    rustup target add aarch64-unknown-linux-musl


ADD cargo-config.toml /home/rust/.cargo/config

# (Please feel free to submit pull requests for musl-libc builds of other C
# libraries needed by the most popular and common Rust crates, to avoid
# everybody needing to build them manually.)

# Install some useful Rust tools from source. This will use the static linking
# toolchain, but that should be OK.
#RUN cargo install -f cargo-audit && \
#    rm -rf /home/rust/.cargo/registry/

RUN sudo chown -R rust /home/rust

# Expect our source code to live in /home/rust/src.  We'll run the build as
# user `rust`, which will be uid 10001, gid 10001 outside the container.
WORKDIR /home/rust/src

# `mdbook` is the standard Rust tool for making searchable HTML manuals.
RUN cargo install mdbook && \
    rm -rf /home/rust/.cargo/registry/

