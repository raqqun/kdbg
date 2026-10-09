FROM alpine:latest
LABEL maintainer="Alexandros Nikiforidis"

ARG KUBECTL_VERSION=1.37.1
ARG TARGETARCH

RUN apk add --no-cache bash \
    curl \
    wget \
    mtr \
    iputils \
    bind-tools \
    netcat-openbsd \
    iptraf-ng \
    tcptraceroute \
    socat \
    busybox-extras

RUN curl -LO https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl && \
    mv kubectl /usr/bin/kubectl && \
    chmod +x /usr/bin/kubectl
