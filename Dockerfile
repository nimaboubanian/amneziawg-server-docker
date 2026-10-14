ARG BASE_IMAGE=docker.arvancloud.ir/library/alpine:3.24

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

FROM ${BASE_IMAGE}

ARG SINGBOX_VERSION=1.14.2
ARG TARGETARCH

RUN apk add --no-cache bash jq curl tini ca-certificates iproute2

RUN set -eux; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/sing_box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl.tar.gz"; \
    tar -xzf /tmp/sing_box.tar.gz -C /tmp \
        "sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl/sing-box"; \
    mv "/tmp/sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl/sing-box" /usr/local/bin/sing-box; \
    chmod +x /usr/local/bin/sing-box; \
    rm -rf /tmp/sing_box.tar.gz "/tmp/sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl"; \
    sing-box version

COPY --from=awg-go-build /src/amneziawg-go /usr/local/bin/amneziawg-go
COPY --from=awg-tools-build /tools/src/wg /usr/local/bin/awg
COPY --from=awg-tools-build /tools/src/wg-quick/linux.bash /usr/local/bin/awg-quick
RUN chmod +x /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg-quick

COPY --chmod=755 scripts /usr/local/bin

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
