FROM eclipse-temurin:21-jre

ARG KARATE_VERSION=2.1.2
ADD https://github.com/karatelabs/karate/releases/download/v${KARATE_VERSION}/karate-${KARATE_VERSION}.jar /opt/karate.jar
RUN chmod a+r /opt/karate.jar

WORKDIR /app
COPY *.feature ./
COPY karate ./karate

CMD ["sh", "karate", "-T", "1", "."]
