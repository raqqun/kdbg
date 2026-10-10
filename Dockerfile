FROM alpine:latest
LABEL maintainer="Alexandros Nikiforidis"

ARG KUBECTL_VERSION=1.37.1
ARG CRICTL_VERSION=1.37.0
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
    busybox-extras \
    tcpdump \
    iproute2 \
    openssl \
    jq \
    yq-go \
    iperf3 \
    nmap \
    strace \
    lsof \
    procps-ng \
    conntrack-tools \
    iptables \
    nftables

RUN curl -LO https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl && \
    mv kubectl /usr/bin/kubectl && \
    chmod +x /usr/bin/kubectl

# The defaults suit kubectl debug node/, which mounts the node at /host:
# crictl talks to the node's containerd, and finds the logs it reads itself.
RUN curl -fsSL https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-${TARGETARCH}.tar.gz | \
    tar -xz -o -C /usr/bin crictl && \
    echo 'runtime-endpoint: unix:///host/run/containerd/containerd.sock' > /etc/crictl.yaml && \
    ln -s /host/var/log/pods /var/log/pods
