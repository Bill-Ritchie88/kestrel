# Project Kestrel - one image for both services (build from the repo root):
#
#   docker build -f deploy/Dockerfile -t kestrel .
#
#   SERVICE=api    (default) the REST tier:    uvicorn kestrel.api.main:app
#   SERVICE=agent            the agent service: uvicorn kestrel.agent_service:app
#
# Both listen on $PORT (Cloud Run and Fly.io set it; 8080 otherwise). Secrets
# and settings come from the environment at run time (deploy/README.md); no
# .env file is in the image - only requirements.txt and src/ are copied.

FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    # The package is run from src/ rather than pip-installed.
    PYTHONPATH=/app/src \
    # Containers have no persistent disk: the JSON timing logs go to stdout.
    LOG_TO_STDOUT=1 \
    SERVICE=api \
    PORT=8080

WORKDIR /app

# Dependencies first, so a code change does not reinstall them.
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY src ./src

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin kestrel
USER kestrel

EXPOSE 8080

# exec: uvicorn becomes PID 1 and receives the platform's stop signal.
CMD ["sh", "-c", "if [ \"$SERVICE\" = agent ]; then exec uvicorn kestrel.agent_service:app --host 0.0.0.0 --port \"$PORT\" --proxy-headers; else exec uvicorn kestrel.api.main:app --host 0.0.0.0 --port \"$PORT\" --proxy-headers; fi"]
