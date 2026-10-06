FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY dashboard.py /dashboard.py
ENV DASHBOARD_PORT=7000
EXPOSE 7000
CMD ["python3", "/dashboard.py"]
