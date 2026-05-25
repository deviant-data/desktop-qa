# Dockerfile — qa-runner-image
#
# Sandbox image for the Desktop QA Suite (v4). Ships bash 5+, jq, git, common
# build tools, and the language runtimes the stage scripts know how to test:
# Node, Python, Go, Ruby, plus a JDK for Maven/Gradle projects.
#
# Build locally:
#   docker build -t qa-runner-image .
# Or via the setup script:
#   bash setup.sh
#
# Design notes:
# - Debian slim base keeps the image small while giving us a real libc (some
#   Python/Node wheels refuse to install on Alpine's musl).
# - We pin major versions only. Pinning exact patch versions in a base image
#   ages badly; the QA pipeline is about finding bugs in the project under
#   test, not about reproducing a specific toolchain bit-for-bit.
# - No network credentials, no baked-in secrets, no third-party auth.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PIP_BREAK_SYSTEM_PACKAGES=1

# --- Core shell + build tools + language runtimes -----------------------
# Grouped into one RUN so the image has a single APT cache layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      findutils \
      git \
      gnupg \
      jq \
      make \
      procps \
      iproute2 \
      unzip \
      xz-utils \
      # Language runtimes the stage scripts dispatch on.
      nodejs npm \
      python3 python3-pip python3-venv \
      golang-go \
      default-jdk \
      maven \
      ruby ruby-dev \
    && rm -rf /var/lib/apt/lists/*

# Some projects invoke `python` (no 3) by convention. Add the symlink
# without installing the full `python-is-python3` package.
RUN ln -sf /usr/bin/python3 /usr/local/bin/python

# Non-root user for the pipeline to run as. Bind-mounts from the host
# override the default UID/GID anyway; this is just a safe default.
RUN useradd -m -s /bin/bash qa
USER qa
WORKDIR /app

# Sanity: confirm the tools the stage scripts expect are actually on PATH.
# Fails the build loudly if a future base-image change drops one.
RUN bash --version | head -n1 \
 && jq --version \
 && git --version \
 && node --version \
 && npm --version \
 && python3 --version \
 && go version \
 && java -version 2>&1 | head -n1 \
 && ruby --version

CMD ["bash"]
