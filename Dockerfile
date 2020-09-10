FROM alpine:latest
LABEL maintainer="Alexandros Nikiforidis"

ARG KUBECTL_VERSION=1.18.0

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

RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
    mv kubectl /usr/bin/kubectl && \
    chmod +x /usr/bin/kubectl
