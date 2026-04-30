FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

ENV CHATGPT_BROWSER_HOST=0.0.0.0
ENV CHATGPT_BROWSER_PORT=8080

CMD ["python", "app.py"]
