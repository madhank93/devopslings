FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask==3.0.3 requests==2.32.3 waitress==3.0.0
COPY checkout.py pricing.py ./
CMD ["python3", "checkout.py"]
