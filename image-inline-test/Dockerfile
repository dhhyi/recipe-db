# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG RUBY_VERSION
FROM ruby:${RUBY_VERSION}-slim-bookworm@sha256:72e67ff51f595b44ce2bd04e4b8d5203759a0ff51ba3ea8800514c50d91c3b24 AS builder

ARG RSPEC_VERSION
ARG AIRBORNE_VERSION
RUN gem install rspec --version "${RSPEC_VERSION}" --no-document \
  && gem install airborne --version "${AIRBORNE_VERSION}" --no-document

FROM ruby:${RUBY_VERSION}-slim-bookworm@sha256:72e67ff51f595b44ce2bd04e4b8d5203759a0ff51ba3ea8800514c50d91c3b24
COPY --from=builder /usr/local/bundle /usr/local/bundle
ENV GEM_HOME=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

WORKDIR /app
COPY spec ./spec
COPY fixtures ./fixtures
CMD ["rspec"]
