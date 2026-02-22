#!/bin/bash
# init-ollama.sh
#
# Pulls the Llama 3.2 3B model into the Ollama container.
# Run this once after first `docker compose up`.
# The model is ~2GB and is used as the local judge for semantic rails.
#
# ADR-003: The judge model must be local. No data leaves the network.
#
# Usage:
#   bash scripts/init-ollama.sh

set -euo pipefail

OLLAMA_CONTAINER="llm-control-plane-ollama-1"
MODEL="llama3.2:3b"

echo "=== Initializing Ollama judge model ==="
echo "Model: $MODEL"
echo ""

# Wait for Ollama to be ready
echo "Waiting for Ollama to be ready..."
for i in $(seq 1 30); do
    if docker exec "$OLLAMA_CONTAINER" ollama list &>/dev/null; then
        echo "Ollama is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Ollama did not become ready after 30 attempts."
        exit 1
    fi
    echo "  Attempt $i/30 — waiting..."
    sleep 2
done

# Check if model already exists
if docker exec "$OLLAMA_CONTAINER" ollama list | grep -q "$MODEL"; then
    echo "Model $MODEL is already pulled. Nothing to do."
    exit 0
fi

# Pull the model
echo ""
echo "Pulling $MODEL (~2GB, this may take a few minutes)..."
docker exec "$OLLAMA_CONTAINER" ollama pull "$MODEL"

echo ""
echo "=== Done ==="
echo "Judge model $MODEL is ready."
echo "NeMo Guardrails can now use it for semantic evaluation."
