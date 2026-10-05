# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG JAVA_VERSION
FROM eclipse-temurin:${JAVA_VERSION}-jre@sha256:cff19e6215689161eb6162c11b86b0c60ddf802164f2eaf48d570f8fb79a36c5

ARG KARATE_VERSION
ADD https://github.com/karatelabs/karate/releases/download/v${KARATE_VERSION}/karate-${KARATE_VERSION}.jar /opt/karate.jar
RUN chmod a+r /opt/karate.jar

WORKDIR /app
COPY *.feature ./
COPY karate ./karate

CMD ["sh", "karate", "-T", "1", "."]
