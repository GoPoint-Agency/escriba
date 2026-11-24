FROM python:3.12-alpine
RUN pip install --no-cache-dir "websockets==13.1"
WORKDIR /app
COPY servidor.py .
USER 1000:1000
CMD ["python", "-u", "servidor.py"]
