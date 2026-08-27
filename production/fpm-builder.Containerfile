# FPM builder image — packages Frappe apps from git into .fpm artifacts.
#
# This is NOT a runtime bench image; it is the image the AppBuild pipeline Job
# runs in. It is based on frappe/build (the official Frappe build image, which
# already carries a WORKING node + yarn-classic + bench + a scratch bench at
# /home/frappe/frappe-bench), and adds the `fpm` CLI. We deliberately do NOT
# reuse frappe-for-operator here: that image ships yarn via corepack (yarn 4.x),
# which breaks `bench build` on node 24 — so an fpm package built there ships no
# compiled assets. frappe/build has yarn classic 1.22, which bench build needs.
#
# Build:
#   podman build -f production/fpm-builder.Containerfile \
#     --build-arg FRAPPE_BRANCH=version-16 --build-arg FPM_VERSION=v2.2.0 \
#     -t ghcr.io/vyogotech/fpm-builder:version-16 .
ARG FRAPPE_BRANCH=version-16
FROM docker.io/frappe/build:${FRAPPE_BRANCH}

USER root

# The fpm CLI. Pin the version so builds are reproducible; bump deliberately.
ARG FPM_VERSION=v2.2.0
ARG TARGETARCH=amd64
RUN curl -fsSL -o /usr/local/bin/fpm \
      "https://github.com/vyogotech/fpm/releases/download/${FPM_VERSION}/fpm-linux-${TARGETARCH}" && \
    chmod +x /usr/local/bin/fpm && \
    fpm --version || (echo "fpm CLI failed to install" && exit 1)

# The build-validate script the AppBuild Job invokes.
COPY production/fpm-build-validate.sh /usr/local/bin/fpm-build-validate.sh
RUN chmod +x /usr/local/bin/fpm-build-validate.sh

USER frappe
WORKDIR /home/frappe/frappe-bench
