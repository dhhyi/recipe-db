FROM maven:3.9.16-eclipse-temurin-21

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
