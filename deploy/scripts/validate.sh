#!/bin/bash
# Health check used by CodeDeploy: fail the deployment (and trigger rollback) if /health is not 200 within 60 s
for i in $(seq 1 12); do
  if curl -fsS http://localhost/health | grep -q '"status":"ok"'; then echo "healthy"; exit 0; fi
  sleep 5
done
echo "health check failed"; exit 1
