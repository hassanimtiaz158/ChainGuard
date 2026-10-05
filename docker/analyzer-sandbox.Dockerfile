# syntax=docker/dockerfile:1
#
# Uploaded-Solidity sandbox.
#
# SECURITY: this container is started with `network_mode: none`, a read-only
# root filesystem, all capabilities dropped and a tmpfs workspace. It only ever
# compiles and statically analyses user source -- it never deploys and never
# executes it. Interaction happens over a mounted unix socket so no TCP port is
# required.

FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Static analysers. Pinned so CI and the demo produce identical findings.
RUN pip install --no-cache-dir \
      slither-analyzer==0.10.4 \
      solc-select==1.0.4

# Unprivileged runtime user (uid/gid 10001).
RUN groupadd --gid 10001 sandbox \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin sandbox

WORKDIR /opt/sandbox
COPY sandbox/ /opt/sandbox/

RUN mkdir -p /workspace && chown sandbox:sandbox /workspace

USER 10001:10001

CMD ["python", "/opt/sandbox/server.py"]