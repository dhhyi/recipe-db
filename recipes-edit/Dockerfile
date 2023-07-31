FROM eclipse-temurin:17 AS BUILD
RUN apt update && apt install unzip -y
WORKDIR /app/
COPY gradle /app/gradle/
COPY build.gradle.kts gradlew /app/
RUN ./gradlew --no-daemon clean
RUN ./gradlew vaadinPrepareFrontend -Pvaadin.productionMode --no-daemon --info --stacktrace
COPY . .
RUN ./gradlew build -x test -x detekt -Pvaadin.productionMode --no-daemon --info --stacktrace
WORKDIR /app/build/distributions/
RUN unzip app.zip

FROM eclipse-temurin:17-jre-alpine
COPY --from=BUILD /app/build/distributions/app /app/
WORKDIR /app/bin
ENV PORT=4000 CONTEXT_PATH=/edit
EXPOSE 4000
ENTRYPOINT ./app
