FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY reaper.py clients.py main.py ./

RUN useradd --uid 1000 --user-group reaper
USER 1000

CMD ["python", "main.py"]
