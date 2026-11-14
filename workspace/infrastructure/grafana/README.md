# infrastructure/grafana

Grafana dashboards, datasource provisioning, and alert rules. The directory is wired for the compose file but holds nothing yet; a `.gitignore` guards against stray build artifacts.

## What belongs here

Use Grafana's standard provisioning layout so the container picks everything up without manual imports:

    provisioning/datasources/   # datasource definitions (Prometheus, the DB engines)
    provisioning/dashboards/    # dashboard providers
    dashboards/                 # dashboard JSON files

## Rules

- Datasource URLs and credentials come from the environment via compose substitution, never from committed files.
- Dashboards are versioned here as JSON. Export them from Grafana, strip volatile ids, and review the diff before committing.
- Alert rules that page a human belong in code here, not in the UI, so they survive container rebuilds.
