FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir locust==2.32.0
COPY locustfile.py ./
EXPOSE 8089
# Headless by default in compose. Override CMD if you want the web UI.
CMD ["locust", "-f", "locustfile.py", "--host", "http://frontend:3000", "--users", "5", "--spawn-rate", "1", "--headless"]
