FROM python:3.13.7-slim-bookworm

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt
COPY pyproject.toml test_mcp.py ./
CMD ["pytest", "-p", "no:cacheprovider", "--junitxml=target/junit.xml"]
