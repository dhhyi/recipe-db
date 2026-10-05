FROM ruby:3.4.5-slim-bookworm AS builder

RUN gem install rspec --version 3.13.0 --no-document \
  && gem install airborne --version 0.3.6 --no-document

FROM ruby:3.4.5-slim-bookworm
COPY --from=builder /usr/local/bundle /usr/local/bundle
ENV GEM_HOME=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

WORKDIR /app
COPY spec ./spec
COPY fixtures ./fixtures
CMD ["rspec"]
