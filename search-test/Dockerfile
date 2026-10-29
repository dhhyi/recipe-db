# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG PYTHON_VERSION
FROM python:${PYTHON_VERSION}-slim-bookworm@sha256:4e03260adeeebafccd084f3584e6b84823aba5651cfb53ef8a078ed441ddf9cd
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --requirement requirements.txt
COPY search_support.py .
COPY features ./features
CMD ["python3", "-m", "behave", "--no-color", "--junit", "--junit-directory", "target/behave"]
