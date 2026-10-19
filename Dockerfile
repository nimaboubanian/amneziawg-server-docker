# amneziawg-go: the userspace AWG 3.1 daemon. Built from source — no release
# binaries published, and the container must not depend on a host kernel
# module (the mainline wireguard module cannot decrypt AWG anyway).
# Base images come via the ArvanCloud mirror: Docker Hub 403s this host's
# egress (docker.io/registry-1.docker.io), gcr.io mirror too.
FROM docker.arvancloud.ir/library/golang:1.25-alpine AS awg-go-build

ARG AWGGO_VERSION=v3.1.20260828

RUN apk add --no-cache git make
RUN git clone --branch "${AWGGO_VERSION}" --depth 1 \
        https://github.com/amnezia-vpn/amneziawg-go /src
RUN make -C /src

# awg + awg-quick: the AWG fork of wireguard-tools. The upstream release zips
# are x86-only, so build from source too — this keeps arm64 publish parity.
FROM docker.arvancloud.ir/library/alpine:3.24 AS awg-tools-build

ARG AWGTOOLS_VERSION=v3.1.20260812

RUN apk add --no-cache git build-base linux-headers
RUN git clone --branch "${AWGTOOLS_VERSION}" --depth 1 \
        https://github.com/amnezia-vpn/amneziawg-tools /tools
RUN make -C /tools/src

# hev-socks5-tunnel: TUN-to-SOCKS5 bridge, built from source as a static
# binary so the runtime image needs no extra libraries.
FROM docker.arvancloud.ir/library/alpine:3.24 AS hev-build

ARG HEV_VERSION=2.14.4

RUN apk add --no-cache gcc make musl-dev git linux-headers
RUN set -eux; \
    git clone --depth 1 --branch "${HEV_VERSION}" --recursive --shallow-submodules \
        https://github.com/heiher/hev-socks5-tunnel /src-hev; \
    sed -i 's/^LDFLAGS=/LDFLAGS=-static /' /src-hev/Makefile; \
    make -C /src-hev -j"$(nproc)"; \
    install -m 0755 /src-hev/bin/hev-socks5-tunnel /usr/local/bin/hev-socks5-tunnel

FROM docker.arvancloud.ir/library/alpine:3.24

RUN apk add --no-cache bash iproute2 tini

COPY --from=hev-build /usr/local/bin/hev-socks5-tunnel /usr/local/bin/hev-socks5-tunnel
COPY --from=awg-go-build /src/amneziawg-go /usr/local/bin/amneziawg-go
COPY --from=awg-tools-build /tools/src/wg /usr/local/bin/awg
COPY --from=awg-tools-build /tools/src/wg-quick/linux.bash /usr/local/bin/awg-quick
RUN chmod +x /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg-quick

COPY --chmod=755 scripts /usr/local/bin

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
