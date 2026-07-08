FROM python:3.13-slim

WORKDIR /app

RUN pip install --no-cache-dir boto3==1.35.76

COPY spot_savings.py .

RUN useradd --uid 1000 --user-group exporter
USER 1000

EXPOSE 9100
CMD ["python", "spot_savings.py"]
