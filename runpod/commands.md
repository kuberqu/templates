Startcommand:
bash -c "([ -f /start.sh ] && /start.sh &); exec >> /workspace/boot.log 2>&1; echo '=== Pod Boot ==='; sleep 2; curl -f -k -L https://raw.githubusercontent.com/kuberqu/templates/main/runpod/entrypoint.sh -o /workspace/entrypoint.sh || true; chmod +x /workspace/entrypoint.sh || true; RUN_IN_BACKGROUND=true bash /workspace/entrypoint.sh; sleep infinity"
