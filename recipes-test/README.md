# Recipes Integration Tests

Integration tests for the recipes service, implemented with [Rest-Assured](https://rest-assured.io/) and [JUnit 5](https://junit.org/junit5/).

Run the tests with:

```sh
mise run integration-tests -- --development recipes-test
```

The standalone job image prefetches Maven dependencies during build and runs the suite offline. Its Surefire report is retained under `target/`.
