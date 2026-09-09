FROM python:3.13-slim

WORKDIR /app

# Install dependencies first so code edits don't invalidate the layer.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY vista ./vista
COPY tests ./tests

# Vista's own state (users, encrypted Ark tokens) lives here; mount a volume
# over it so accounts survive a rebuild.
ENV VISTA_HOME=/data
VOLUME ["/data"]

EXPOSE 8800

CMD ["python", "-m", "vista", "serve", "--host", "0.0.0.0", "--port", "8800"]
