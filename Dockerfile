# Reproducer for the review comment on Percona-Lab/jenkins-pipelines PR 4441, runSpotInstance.groovy:48.
# Real AWS CLI v2 (pinned, checksum-verified) talking to a local EC2 fixture, no account or network at run time.
#   docker build -t pr4441-repro https://github.com/nogueiraanderson/probe-pr4441-launch-loop.git
#   docker run --rm --network none pr4441-repro                  # comparison table, exits 1 if a row differs
#   docker run --rm --network none -e VERBOSE=1 pr4441-repro     # plus every run's console
FROM debian:bookworm-slim

ARG AWSCLI_VERSION=2.33.17
ARG AWSCLI_SHA256_AARCH64=2b46c9ea83b22643f53dd073bbb0d312e692bdf3f0d85519d548d768c007bfd3
ARG AWSCLI_SHA256_X86_64=b20124fd54ba9c46998cfc9cb461a46016cc182af0fffbfa359f1063552da554

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip python3 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    arch="$(uname -m)"; \
    case "$arch" in \
      aarch64) sum="$AWSCLI_SHA256_AARCH64" ;; \
      x86_64)  sum="$AWSCLI_SHA256_X86_64" ;; \
      *) echo "unsupported architecture $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWSCLI_VERSION}.zip"; \
    echo "${sum}  /tmp/awscli.zip" | sha256sum -c -; \
    unzip -q /tmp/awscli.zip -d /tmp; \
    /tmp/aws/install -i /opt/aws-cli -b /opt/aws-bin; \
    rm -rf /tmp/aws /tmp/awscli.zip

WORKDIR /repro
COPY aws /usr/local/bin/aws
COPY fixture.py launch-head.sh launch-fixed.sh repro.sh ./
RUN chmod +x /usr/local/bin/aws ./repro.sh ./launch-head.sh ./launch-fixed.sh && /opt/aws-bin/aws --version
CMD ["./repro.sh"]
