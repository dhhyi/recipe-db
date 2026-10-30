# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG RUBY_VERSION
FROM ruby:${RUBY_VERSION}-slim-trixie@sha256:3a8122c4267d89a95b1ce0f3029b44e325180314661856300d29d3e8a80ec46f AS builder

ARG RSPEC_VERSION
ARG AIRBORNE_VERSION
RUN gem install rspec --version "${RSPEC_VERSION}" --no-document \
  && gem install airborne --version "${AIRBORNE_VERSION}" --no-document

FROM ruby:${RUBY_VERSION}-slim-trixie@sha256:3a8122c4267d89a95b1ce0f3029b44e325180314661856300d29d3e8a80ec46f
COPY --from=builder /usr/local/bundle /usr/local/bundle
ENV GEM_HOME=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

WORKDIR /app
COPY spec ./spec
COPY fixtures ./fixtures
CMD ["rspec"]
