# syntax=mirror.gcr.io/docker/dockerfile:1.25.0@sha256:0adf442eae370b6087e08edc7c50b552d80ddf261576f4ebd6421006b2461f12

FROM icecodexi/python:debian-nonroot@sha256:23e364a880ec13ba1155ebf71f9a7c5a039157bfd7786cd7e3d9f47d658016b6 AS secure-mirrors
COPY --link <<npm <<pip <<uv /

registry=https://npm.flatt.tech/
npm

[global]
index-url = https://pypi.flatt.tech/simple/
pip

[[index]]
url = "https://pypi.flatt.tech/simple/"
default = true
uv

USER root:root
ENV HOME=/home/nonroot
RUN mkdir -p \
    "/secure-mirrors/${HOME}/.config/pnpm/" \
    "/secure-mirrors/${HOME}/.config/pip/" \
    "/secure-mirrors/${HOME}/.config/uv" \
    && cp -f /npm "/secure-mirrors/${HOME}/.npmrc" \
    && cp -f /npm "/secure-mirrors/${HOME}/.config/pnpm/auth.ini" \
    && cp -f /pip "/secure-mirrors/${HOME}/.config/pip/pip.conf" \
    && cp -f /uv  "/secure-mirrors/${HOME}/.config/uv/uv.toml"


FROM icecodexi/python:debian-nonroot@sha256:23e364a880ec13ba1155ebf71f9a7c5a039157bfd7786cd7e3d9f47d658016b6 AS mise
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root:root
RUN extrepo enable mise \
    && install_packages \
    libatomic1 mise
ENV HOME=/home/nonroot
RUN mkdir -p \
    "/empty/${HOME}/.local/share/" \
    "${HOME}/.cache" "${HOME}/.config/mise" "${HOME}/.local/share/mise" "${HOME}/.local/state/mise" \
    && chown -R 65532:65532 "${HOME}" /empty/
USER nonroot:nonroot


FROM mise AS node-assets
# renovate: datasource=node-version packageName=node
ARG NODE_VERSION=24.18.0
# renovate: datasource=github-releases packageName=pnpm/pnpm
ARG PNPM_VERSION=11.11.0
# renovate: datasource=npm packageName=@openai/codex
ARG CODEX_VERSION=0.144.1
# renovate: datasource=npm packageName=@jackwener/opencli
ARG OPENCLI_VERSION=1.8.6
# renovate: datasource=npm packageName=opencode-ai
ARG OPENCODE_VERSION=1.17.18
# renovate: datasource=github packageName=google-antigravity/antigravity-cli
ARG ANTIGRAVITY_CLI_VERSION=1.0.16
RUN --mount=type=cache,id=mise-cache,target=/home/nonroot/.cache/mise,uid=65532,gid=65532 \
    --mount=type=cache,id=mise-downloads-cache,target=/home/nonroot/.local/share/mise/downloads,uid=65532,gid=65532 \
    --mount=type=cache,id=npm-cache,target=/home/nonroot/.npm,uid=65532,gid=65532 \
    --mount=type=cache,id=pnpm-store,target=/home/nonroot/.local/share/pnpm/store,uid=65532,gid=65532 \
    --mount=type=cache,id=sigstore-cache,target=/home/nonroot/.cache/sigstore-rust,uid=65532,gid=65532 \
    <<EOF
set -euo pipefail
cat > "${HOME}/.config/mise/config.toml" <<CONFIG
[settings]
[settings.npm]
package_manager = "pnpm"

[tools]
antigravity-cli = "${ANTIGRAVITY_CLI_VERSION}"
ast-grep = "latest"
gh = "latest"
opencode = "${OPENCODE_VERSION}"
shellcheck = "latest"
tree-sitter = "latest"

"github:aptible/supercronic" = "latest"
CONFIG

mise use -g \
    node@${NODE_VERSION} pnpm@${PNPM_VERSION}
mise use -g \
    "npm:@openai/codex"@${CODEX_VERSION} \
    "npm:@jackwener/opencli"@${OPENCLI_VERSION}
cp -a "${HOME}/.local/share/mise" "${HOME}/.local/share/pnpm" \
    "/empty/${HOME}/.local/share/"
rm -rf "${HOME}/.cache/pnpm"
EOF


FROM scratch AS npm-pkgs
COPY --link --from=node-assets /home/nonroot/ /home/nonroot/
COPY --link --from=node-assets /empty/ /


FROM mise AS final
USER root:root
RUN install_packages \
    bubblewrap \
    build-essential musl \
    ca-certificates curl \
    fd-find \
    git \
    jq \
    openssh-client \
    procps protobuf-compiler \
    ripgrep \
    sudo \
    vim \
    zip unzip
RUN mkdir -p /app /workspace \
    && chown -R 65532:65532 /app /workspace
COPY --link --from=ghcr.io/astral-sh/ruff:0.15.21@sha256:d88c0de3362ae064e5f3175ff558ee1077223d3f81a1e78b1cf57825c4882454 /ruff /usr/local/bin/
COPY --link --from=ghcr.io/astral-sh/ty:0.0.58@sha256:8d279433ab7ebba881fe2c8a66bc892c4f3411a54f440b79c59621bc9db3ef03 /ty /usr/local/bin/
COPY --link --from=ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa /uv /uvx /usr/local/bin/
COPY --link --from=mikefarah/yq:4.53.3@sha256:11a1f0b604b13dbbdc662260d8db6f644b22d8553122a25c1b5b2e8713ca6977 /usr/bin/yq /usr/local/bin/
COPY --link --from=ghcr.io/j178/prek:v0.4.8@sha256:923fe4fde30504a5043a590e8dc175d0dc270a3311d14aec44994ad4fd4a088e /prek /usr/local/bin/

COPY --link --from=npm-pkgs --chown=65532:65532 /home/nonroot/ /home/nonroot/
USER nonroot:nonroot
ENV PNPM_HOME="${HOME}/.local/share/pnpm"
ENV PNPM_CONFIG_STORE_DIR="${PNPM_HOME}/store"
ENV PATH="${HOME}/.local/share/mise/shims:${PNPM_HOME}/bin:${PATH}" \
    SHELL=bash
RUN --mount=type=cache,id=mise-cache,target=/home/nonroot/.cache/mise,uid=65532,gid=65532 \
    --mount=type=cache,id=mise-downloads-cache,target=/home/nonroot/.local/share/mise/downloads,uid=65532,gid=65532 \
    mise install && mise reshim

WORKDIR /app
# Install Python dependencies first (cached layer)
COPY --link --chown=65532:65532 pyproject.toml uv.lock README.md LICENSE entrypoint.sh ./
# Copy the full source and install
COPY --link --chown=65532:65532 src ./src
RUN uv sync --no-dev --no-editable \
    && uv pip install "any-llm-sdk[gemini,xai]"

WORKDIR /workspace

VOLUME /root/.bub

ENTRYPOINT ["catatonit", "-g", "--"]

CMD ["/app/entrypoint.sh"]
