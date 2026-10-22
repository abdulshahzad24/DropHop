FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV PORT=8000
# Hosts like Render, Railway and Fly set PORT themselves.
CMD ["sh", "-c", "test -n \"${GHOSTLY_TOKEN}\" || { echo 'Set GHOSTLY_TOKEN before exposing the server'; exit 1; }; exec uvicorn app:app --host 0.0.0.0 --port ${PORT}"]
