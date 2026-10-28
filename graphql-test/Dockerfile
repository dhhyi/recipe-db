# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG JAVA_VERSION
FROM eclipse-temurin:${JAVA_VERSION}-jre@sha256:f37956012e0cb88400e5b3689aeae2d2d735364c1922ae2225536163b5a99f56

ARG KARATE_VERSION
ADD https://github.com/karatelabs/karate/releases/download/v${KARATE_VERSION}/karate-${KARATE_VERSION}.jar /opt/karate.jar
RUN chmod a+r /opt/karate.jar

WORKDIR /app
COPY *.feature ./
COPY karate-config.js ./
COPY graphql ./graphql
COPY fixtures ./fixtures
COPY karate ./karate

CMD ["sh", "karate", "-T", "1", "."]
