ARG GRADLE_VERSION
FROM maven:3.9.16-eclipse-temurin-21@sha256:99e61abcff91a9b1333463bd8451fb18495d6eba9250ac66a338b518f8278320

ARG GRADLE_VERSION
ARG HOST_UID=1000
ARG HOST_GID=1000
ENV GRADLE_USER_HOME=/opt/gradle-cache

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl unzip \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip \
  && echo "bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531  /tmp/gradle.zip" | sha256sum -c - \
  && unzip -q /tmp/gradle.zip -d /opt \
  && ln -s "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle \
  && rm /tmp/gradle.zip

WORKDIR /app
COPY build.gradle settings.gradle ./
COPY src ./src
RUN gradle --no-daemon testClasses \
  && chown -R "${HOST_UID}:${HOST_GID}" /opt/gradle-cache

ENTRYPOINT []
CMD ["gradle", "--no-daemon", "test"]
