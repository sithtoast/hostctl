ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 nginx php8.3-fpm acl vsftpd db-util curl openssl passwd
COPY priv/isolation/runtime.py /runtime.py
COPY test/isolation/linux_smoke.py /linux_smoke.py
COPY scripts/ftp-isolation-probe.py /ftp-isolation-probe.py
CMD ["python3", "/linux_smoke.py"]
