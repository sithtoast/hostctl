FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends postfix dovecot-imapd dovecot-lmtpd dovecot-sieve dovecot-managesieved rspamd redis-server python3 && rm -rf /var/lib/apt/lists/*
COPY integration.py /integration.py
CMD ["python3", "/integration.py"]
