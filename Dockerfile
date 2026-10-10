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

# crictl, from the cri-tools release matching kubectl's minor version.
# cri-tools is released a few weeks after Kubernetes, so until the matching
# release exists, use the one for the previous minor version.
# The defaults suit kubectl debug node/, which mounts the node at /host:
# crictl talks to the node's containerd, and finds the logs it reads itself.
RUN set -e; \
    major=${KUBECTL_VERSION%%.*}; \
    minor=$(echo "${KUBECTL_VERSION}" | cut -d. -f2); \
    for m in ${minor} $((minor - 1)); do \
      v="v${major}.${m}.0"; \
      url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${v}/crictl-${v}-linux-${TARGETARCH}.tar.gz"; \
      if curl -fsSLo /tmp/crictl.tar.gz "${url}"; then break; fi; \
      rm -f /tmp/crictl.tar.gz; \
    done; \
    echo "$(curl -fsSL "${url}.sha256")  /tmp/crictl.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/crictl.tar.gz -C /tmp crictl; \
    install -m 0755 /tmp/crictl /usr/bin/crictl; \
    rm /tmp/crictl.tar.gz /tmp/crictl; \
    echo 'runtime-endpoint: unix:///host/run/containerd/containerd.sock' > /etc/crictl.yaml; \
    ln -s /host/var/log/pods /var/log/pods; \
    crictl --version
