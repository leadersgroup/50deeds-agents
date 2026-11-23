FROM nousresearch/hermes-agent:v0.23.1

USER root

# jq is used by the dispatch CLI to build/parse JSON safely.
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*

# Hermes v0.23 dropped PyYAML from its venv; bootstrap's config step imports yaml.
RUN /opt/hermes/.venv/bin/python -m ensurepip --upgrade && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir pyyaml
# Agent Python libraries (see requirements-agents.txt). Installed into their
# own directory and appended to the Hermes venv's import path with a .pth
# file: Hermes' own packages still win on any version conflict, and the
# agents' default `python3` can import these with no install step. This keeps
# ~1 GB of per-agent virtualenvs and download caches off the volume.
COPY requirements-agents.txt /usr/local/share/50deeds/requirements-agents.txt
RUN /opt/hermes/.venv/bin/python -m pip install --no-cache-dir \
        --target /opt/50deeds/pylibs \
        -r /usr/local/share/50deeds/requirements-agents.txt \
    && /opt/hermes/.venv/bin/python -c "import sysconfig, pathlib; pathlib.Path(sysconfig.get_paths()['purelib'], '50deeds-agents.pth').write_text('/opt/50deeds/pylibs\n')" \
    && /opt/hermes/.venv/bin/python -c "import pymupdf, pymupdf4llm, onnxruntime, numpy, PIL, docx, lxml, tabulate, networkx, googleapiclient, google.auth, google_auth_oauthlib, requests, openpyxl, yaml; print('agent libs ok: pymupdf', pymupdf.__version__, 'onnxruntime', onnxruntime.__version__)"

# Baked into the image so every deploy is reproducible. The bootstrap copies
# these onto the volume on first boot and never overwrites them afterwards,
# so personas can be edited live over `railway ssh` without a redeploy.
COPY souls/           /usr/local/share/50deeds/souls/
COPY dispatch         /usr/local/share/50deeds/dispatch
COPY sync-staff       /usr/local/share/50deeds/sync-staff
COPY agents.map       /usr/local/share/50deeds/agents.map
COPY staff.csv        /usr/local/share/50deeds/staff.csv
COPY google-access.map /usr/local/share/50deeds/google-access.map
COPY google-share     /usr/local/share/50deeds/google-share
COPY hermes-skills/    /usr/local/share/50deeds/skills/
COPY bootstrap.sh     /usr/local/bin/hermes-bootstrap

RUN chmod 0755 /usr/local/bin/hermes-bootstrap \
               /usr/local/share/50deeds/dispatch \
               /usr/local/share/50deeds/sync-staff \
               /usr/local/share/50deeds/google-share

# Do NOT set ENTRYPOINT — s6-overlay's /init must stay in the chain. It runs
# as root to chown the volume, then drops every service to the hermes user.
USER hermes
