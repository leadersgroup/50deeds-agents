FROM nousresearch/hermes-agent:v0.23.1

USER root

# jq is used by the dispatch CLI to build/parse JSON safely.
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*

# Hermes v0.23 dropped PyYAML from its venv; bootstrap's config step imports yaml.
RUN /opt/hermes/.venv/bin/python -m ensurepip --upgrade && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir pyyaml
# Baked into the image so every deploy is reproducible. The bootstrap copies
# these onto the volume on first boot and never overwrites them afterwards,
# so personas can be edited live over `railway ssh` without a redeploy.
COPY souls/           /usr/local/share/50deeds/souls/
COPY dispatch         /usr/local/share/50deeds/dispatch
COPY sync-staff       /usr/local/share/50deeds/sync-staff
COPY agents.map       /usr/local/share/50deeds/agents.map
COPY staff.csv        /usr/local/share/50deeds/staff.csv
COPY bootstrap.sh     /usr/local/bin/hermes-bootstrap

RUN chmod 0755 /usr/local/bin/hermes-bootstrap \
               /usr/local/share/50deeds/dispatch \
               /usr/local/share/50deeds/sync-staff

# Do NOT set ENTRYPOINT — s6-overlay's /init must stay in the chain. It runs
# as root to chown the volume, then drops every service to the hermes user.
USER hermes
