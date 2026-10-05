FROM python:3.13.7-slim-bookworm

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt
COPY link-extract.robot ./
CMD ["robot", "--outputdir", "target", "."]
