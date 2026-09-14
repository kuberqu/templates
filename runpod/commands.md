Startcommand:
bash -c "exec >> /workspace/boot.log 2>&1; echo '=== Pod Boot gestartet ==='; sleep 2; curl -f -L https://raw.githubusercontent.com/kuberqu/templates/main/runpod/entrypoint.sh -o /workspace/entrypoint.sh || true; chmod +x /workspace/entrypoint.sh || true; RUN_IN_BACKGROUND=true bash /workspace/entrypoint.sh; sleep infinity"
