# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds on top of the org C/C++ base image
# (ghcr.io/savantenvs/base). p11-kit uses meson/ninja; the base ships clang/llvm/libFuzzer/afl++ but
# not meson itself, so we install it (+ the trust-module deps: libtasn1 + its asn1Parser tool, and
# libffi for p11-kit's closures) as root before the build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an empty value
# breaks clang ("must be a non-negative decimal integer") both here and for any in-image rebuild.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default. Declare
# WITHOUT a default (no '=') so the base ENV flows through when not passed, and an explicit
# --build-arg overrides it (an empty default would shadow the base ENV and silently wipe sanitizers).
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# p11-kit's own build needs meson (not in the base) + the trust-module deps (libtasn1 dev headers AND
# its asn1Parser code-generator binary — meson's trust_module=enabled feature probes for both) + libffi
# (p11-kit's closures). Re-pin to SOURCE_DATE_EPOCH first for reproducibility.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      meson libtasn1-dev libtasn1-bin libffi-dev \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run p11-kit's own functional tests at build time — a failing suite fails the image build, so the
# commit image is guaranteed to build AND pass its own tests.
RUN bash mayhem/test.sh

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
