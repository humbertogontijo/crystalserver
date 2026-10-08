# Grafana with datasource + dashboards provisioned (built by
# .github/workflows/deploy-metrics.yml from the repo root; Coolify only pulls it).
#
# Dashboards live under /etc/grafana so image updates win over the persistent
# /var/lib/grafana volume. Folder = subdirectory name.
FROM grafana/grafana-oss:12.1.1

COPY deploy/metrics/grafana/provisioning/ /etc/grafana/provisioning/
COPY deploy/metrics/grafana/dashboards/crystalserver-performance.json /etc/grafana/dashboards/CrystalServer/

# grafana.com: Node Exporter Full (1860) and cAdvisor (19792), pinned revisions.
ADD https://grafana.com/api/dashboards/1860/revisions/45/download \
	/etc/grafana/dashboards/Host/node-exporter-full.json
ADD https://grafana.com/api/dashboards/19792/revisions/6/download \
	/etc/grafana/dashboards/Containers/cadvisor.json

# Remote ADD writes 0600 files; Grafana runs as uid 472.
USER root
RUN chmod -R a+rX /etc/grafana/dashboards
USER 472
