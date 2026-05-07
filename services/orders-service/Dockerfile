FROM python:3.12-slim

WORKDIR /app

# Install deps first (better layer caching)
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./

EXPOSE 8001

# uvicorn is the ASGI server. --host 0.0.0.0 is required so it's reachable from outside the container.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
