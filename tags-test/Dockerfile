ARG JAVA_VERSION
FROM eclipse-temurin:${JAVA_VERSION}-jdk-noble@sha256:114cabb73033ca4ce7ceec3deb62396bc1b716282bae051ed3c1d82e38fcab2d

ARG HOST_UID=1000
ARG HOST_GID=1000
ENV GRADLE_USER_HOME=/opt/gradle-cache

WORKDIR /app
COPY gradlew ./
COPY gradle ./gradle
COPY build.gradle settings.gradle ./
COPY src ./src
RUN ./gradlew --no-daemon testClasses \
  && chown -R "${HOST_UID}:${HOST_GID}" /opt/gradle-cache

ENTRYPOINT []
CMD ["./gradlew", "--no-daemon", "test"]
