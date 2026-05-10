FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# After installing OTEL libs, run the bootstrap helper. It looks at every
# installed package and pulls in any matching opentelemetry-instrumentation-*
# package not already present. Belt-and-suspenders alongside our explicit pins.
RUN opentelemetry-bootstrap -a install

COPY main.py ./

EXPOSE 8001

# The KEY change: prefix the original CMD with `opentelemetry-instrument`.
# This launcher monkey-patches FastAPI, httpx, psycopg, and the logging module
# at import time so they emit OTEL spans/logs without any code changes.
CMD ["opentelemetry-instrument", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
