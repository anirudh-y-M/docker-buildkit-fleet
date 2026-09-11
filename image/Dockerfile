# syntax=docker/dockerfile:1
#
# A rebuild of the upstream moby/buildkit rootless image with a current Go
# toolchain and patched dependencies. Same layout, same entrypoint, same uid;
# the only intended difference is what a vulnerability scanner reports.
#
# Why this exists: the upstream image bundles binaries built elsewhere (CNI
# plugins ship prebuilt on an older Go) and pins dependency versions that pick
# up CVEs between releases. Rebuilding every component here on one toolchain,
# with those dependencies raised, is the only way to move the count.
#
# Every version is a build argument (see versions.env). Sources are fetched by
# git tag, so a build is reproducible from the argument set alone.

ARG GO_VERSION=1.26.8
ARG ALPINE_VERSION=3.23
ARG XX_VERSION=1.9.0
ARG BUILDKIT_VERSION=v0.33.0
ARG RUNC_VERSION=v1.5.1
ARG ROOTLESSKIT_VERSION=v3.1.0
ARG CNI_VERSION=v1.9.1
ARG XCRYPTO_VERSION=v0.57.0
ARG XNET_VERSION=v0.59.0
ARG GOARCHIVE_VERSION=v0.3.3

# ---------------------------------------------------------------------------
# Cross-compilation base. xx provides xx-go / xx-apk / xx-verify so every
# component is built natively on the build host for the target platform; no
# emulation is involved.
FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS gobuild-base
RUN apk add --no-cache file bash clang lld musl-dev pkgconfig git make
COPY --link --from=xx / /
# Never let a module's `toolchain` line pull an older Go: the point of this
# image is that everything is compiled with the toolchain above.
ENV GOTOOLCHAIN=local

# ---------------------------------------------------------------------------
# BuildKit itself: buildkitd and buildctl.
FROM gobuild-base AS buildkit-src
WORKDIR /src/buildkit
ARG BUILDKIT_VERSION
ADD --keep-git-dir=true "https://github.com/moby/buildkit.git#${BUILDKIT_VERSION}" .
# Version stamping, taken before the tree is modified so it reads as the
# upstream tag plus a ".m" (modified) marker, which is what upstream's own
# build would print for a dirty tree.
RUN <<'EOT'
  set -ex
  PKG=github.com/moby/buildkit
  VERSION=$(git describe --match 'v[0-9]*' --always --tags).m
  REVISION=$(git rev-parse HEAD).m
  echo "-X ${PKG}/version.Version=${VERSION} -X ${PKG}/version.Revision=${REVISION} -X ${PKG}/version.Package=${PKG}" > /tmp/.ldflags
EOT
ARG XCRYPTO_VERSION XNET_VERSION GOARCHIVE_VERSION
RUN --mount=type=cache,target=/go/pkg/mod <<'EOT'
  set -ex
  export GOFLAGS=-mod=mod
  go get "golang.org/x/crypto@${XCRYPTO_VERSION}" "golang.org/x/net@${XNET_VERSION}" "github.com/moby/go-archive@${GOARCHIVE_VERSION}"
  go mod tidy
  go mod vendor
EOT

FROM buildkit-src AS buildkitd
ARG TARGETPLATFORM
RUN --mount=type=cache,target=/root/.cache <<'EOT'
  set -ex
  CGO_ENABLED=0 xx-go build -mod=vendor -trimpath \
    -ldflags "$(cat /tmp/.ldflags) -extldflags '-static'" \
    -tags "osusergo netgo static_build seccomp" \
    -o /out/buildkitd ./cmd/buildkitd
  xx-verify --static /out/buildkitd
EOT

FROM buildkit-src AS buildctl
ARG TARGETPLATFORM
RUN --mount=type=cache,target=/root/.cache <<'EOT'
  set -ex
  CGO_ENABLED=0 xx-go build -mod=vendor -trimpath \
    -ldflags "$(cat /tmp/.ldflags)" \
    -o /out/buildctl ./cmd/buildctl
  xx-verify --static /out/buildctl
EOT

# ---------------------------------------------------------------------------
# runc: static, with seccomp, exactly as upstream builds it, plus x/net raised.
FROM gobuild-base AS runc
WORKDIR /src/runc
ARG RUNC_VERSION
ADD --keep-git-dir=true "https://github.com/opencontainers/runc.git#${RUNC_VERSION}" .
ARG XNET_VERSION
RUN --mount=type=cache,target=/go/pkg/mod <<'EOT'
  set -ex
  export GOFLAGS=-mod=mod
  go get "golang.org/x/net@${XNET_VERSION}"
  go mod tidy
  go mod vendor
EOT
ARG TARGETPLATFORM
RUN xx-apk add musl-dev gcc libseccomp-dev libseccomp-static
RUN --mount=type=cache,target=/root/.cache <<'EOT'
  set -ex
  CGO_ENABLED=1 xx-go build -mod=vendor -trimpath \
    -ldflags '-extldflags -static' \
    -tags 'apparmor seccomp netgo cgo static_build osusergo' \
    -o /out/buildkit-runc ./
  xx-verify --static /out/buildkit-runc
EOT

# ---------------------------------------------------------------------------
# rootlesskit: the user-namespace launcher that is the image entrypoint.
FROM gobuild-base AS rootlesskit
WORKDIR /src/rootlesskit
ARG ROOTLESSKIT_VERSION
ADD --keep-git-dir=true "https://github.com/rootless-containers/rootlesskit.git#${ROOTLESSKIT_VERSION}" .
ARG XCRYPTO_VERSION XNET_VERSION
RUN --mount=type=cache,target=/go/pkg/mod <<'EOT'
  set -ex
  go get "golang.org/x/crypto@${XCRYPTO_VERSION}" "golang.org/x/net@${XNET_VERSION}"
  go mod tidy
EOT
ARG TARGETPLATFORM
RUN --mount=type=cache,target=/root/.cache --mount=type=cache,target=/go/pkg/mod <<'EOT'
  set -ex
  CGO_ENABLED=0 xx-go build -trimpath -o /out/rootlesskit ./cmd/rootlesskit
  xx-verify --static /out/rootlesskit
EOT

# ---------------------------------------------------------------------------
# CNI plugins. Upstream downloads prebuilt release binaries here, which is where
# an old Go standard library enters the image. Building them from the same tag
# on our toolchain is the fix.
FROM gobuild-base AS cni-plugins
WORKDIR /src/plugins
ARG CNI_VERSION
ADD --keep-git-dir=true "https://github.com/containernetworking/plugins.git#${CNI_VERSION}" .
ARG TARGETPLATFORM
RUN --mount=type=cache,target=/root/.cache <<'EOT'
  set -ex
  for p in main/bridge main/loopback ipam/host-local meta/firewall; do
    CGO_ENABLED=0 xx-go build -mod=vendor -trimpath -o "/out/buildkit-cni-$(basename "$p")" "./plugins/$p"
    xx-verify --static "/out/buildkit-cni-$(basename "$p")"
  done
EOT


# ---------------------------------------------------------------------------
# Final image: upstream's `rootless` stage with the packages upgraded.
# Deliberately omitted relative to upstream: the QEMU binfmt emulators. The
# fleet builds each architecture natively on a shard of that architecture.
FROM alpine:${ALPINE_VERSION} AS rootless
RUN apk upgrade --no-cache \
 && apk add --no-cache fuse3 fuse-overlayfs git openssh openssl pigz shadow-uidmap xz
RUN adduser -D -u 1000 user \
 && mkdir -p /run/user/1000 /home/user/.local/tmp /home/user/.local/share/buildkit \
 && chown -R user /run/user/1000 /home/user \
 && echo user:100000:65536 | tee /etc/subuid | tee /etc/subgid
COPY --link --from=rootlesskit /out/rootlesskit /usr/bin/
COPY --link --from=runc        /out/buildkit-runc /usr/bin/
COPY --link --from=cni-plugins /out/ /usr/bin/
COPY --link --from=buildctl    /out/buildctl /usr/bin/
COPY --link --from=buildkitd   /out/buildkitd /usr/bin/
COPY --link --from=buildkit-src /src/buildkit/examples/buildctl-daemonless/buildctl-daemonless.sh /usr/bin/

ARG BUILDKIT_VERSION
ARG GO_VERSION
ARG ALPINE_VERSION
LABEL org.opencontainers.image.title="buildkit (rebuilt)" \
      org.opencontainers.image.description="moby/buildkit ${BUILDKIT_VERSION} rootless, rebuilt on Go ${GO_VERSION} with patched dependencies for the buildkit-fleet chart" \
      org.opencontainers.image.source="https://github.com/anirudh-y-M/docker-buildkit-fleet" \
      org.opencontainers.image.version="${BUILDKIT_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/alpine:${ALPINE_VERSION}"

USER 1000:1000
ENV HOME=/home/user
ENV USER=user
ENV XDG_RUNTIME_DIR=/run/user/1000
ENV TMPDIR=/home/user/.local/tmp
ENV BUILDKIT_HOST=unix:///run/user/1000/buildkit/buildkitd.sock
VOLUME /home/user/.local/share/buildkit
ENTRYPOINT ["rootlesskit", "buildkitd"]
