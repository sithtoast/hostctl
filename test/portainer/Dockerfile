FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 systemd
WORKDIR /source
COPY priv/portainer /source/priv/portainer
COPY priv/deploy/hostctl-portainer.service /source/priv/deploy/hostctl-portainer.service
COPY test/portainer /source/test/portainer
CMD ["python3", "-m", "unittest", "discover", "-s", "test/portainer", "-v"]
