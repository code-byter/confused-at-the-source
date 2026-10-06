FROM python:3.12-slim
RUN pip install --no-cache-dir devpi-server devpi-client && \
    apt-get update -qq && apt-get install -y -qq --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
# root user password set at init from env; index root/pypi created volatile=False
COPY init.sh /init.sh
EXPOSE 3141
CMD ["/init.sh"]
