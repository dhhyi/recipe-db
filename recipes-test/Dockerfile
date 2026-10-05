# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG MAVEN_VERSION
ARG JAVA_VERSION
FROM maven:${MAVEN_VERSION}-eclipse-temurin-${JAVA_VERSION}@sha256:99e61abcff91a9b1333463bd8451fb18495d6eba9250ac66a338b518f8278320

WORKDIR /app
COPY pom.xml eclipse-formatter.xml ./
COPY src ./src
RUN mkdir -p /opt/maven-repo \
  && mvn -Dmaven.repo.local=/opt/maven-repo \
    --batch-mode --no-transfer-progress dependency:go-offline \
  && mvn --batch-mode --no-transfer-progress dependency:get \
    -Dmaven.repo.local=/opt/maven-repo \
    -Dartifact=org.apache.maven.surefire:surefire-junit-platform:3.5.2 \
    -Dtransitive=true \
  && mvn --batch-mode --no-transfer-progress dependency:get \
    -Dmaven.repo.local=/opt/maven-repo \
    -Dartifact=org.junit.platform:junit-platform-commons:1.9.3 \
  && mvn -Dmaven.repo.local=/opt/maven-repo \
    --batch-mode --no-transfer-progress -DskipTests test \
  && chmod -R a+rwX /opt/maven-repo

ENV MAVEN_ARGS="-o -Dmaven.repo.local=/opt/maven-repo"
ENV MAVEN_CONFIG=/tmp/maven-config
CMD ["mvn", "--batch-mode", "--no-transfer-progress", "test"]
