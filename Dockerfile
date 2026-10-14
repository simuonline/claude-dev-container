FROM node:24-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates iptables ipset iproute2 dnsutils jq aggregate \
    tmux less vim \
 && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

COPY init-firewall.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh \
 && mkdir -p /workspace && chown node:node /workspace

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
