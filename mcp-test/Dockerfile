# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG PYTHON_VERSION
FROM python:${PYTHON_VERSION}-slim-trixie@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt
COPY pyproject.toml test_*.py ./
CMD ["pytest", "-p", "no:cacheprovider", "--junitxml=target/junit.xml"]
