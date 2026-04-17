# Local models

How to run an LLM on the host and point your agent containers at it.

## The key thing

`localhost` inside the container is the container, not the host. Use the host's LAN IP or hostname instead. Since containers sit on the bridge with real LAN IPs, they can reach the host the same way any other machine on the network would.

```json
{
  "model": "Qwen3.5-9B",
  "base_url": "http://host.lan:8080/v1",
  "api_key": "not-needed"
}
```

Replace `host.lan` with your host's hostname or bridge IP.

## llama.cpp

[llama.cpp](https://github.com/ggml-org/llama.cpp) exposes an OpenAI-compatible API. Build from source with CUDA support if you have an NVIDIA GPU — the benchmarking and MoE offloading flags are worth having.

```bash
./llama-server -m model.gguf --host 0.0.0.0 --port 8080 --jinja
```

The `--jinja` flag is required for tool-calling chat templates to work. `--host 0.0.0.0` binds to all interfaces so the container can reach the server via the bridge IP. If you only want the bridge, bind to that IP specifically:

```bash
./llama-server -m model.gguf --host 10.0.0.1 --port 8080 --jinja
```

Tested with Qwen3.5-9B (fits in 8GB VRAM) and Qwen3-30B-A3B (MoE, GPU + RAM offload via `--n-cpu-moe`).

## Ollama

[Ollama](https://github.com/ollama/ollama) wraps llama.cpp and exposes an OpenAI-compatible endpoint at `http://HOST:11434/v1`. It doesn't expose the MoE offloading flags, so for large MoE models you're better off with llama.cpp directly.

## Binding to the bridge

If the host has a firewall or you don't want the model endpoint exposed to the whole LAN, bind the server to the bridge IP only. The container reaches the host via the bridge, so this is sufficient.

For llama.cpp: `--host YOUR_BRIDGE_IP`.
For Ollama: set `OLLAMA_HOST` to `YOUR_BRIDGE_IP:11434`.

## Running as a service

If the host is always-on, run the model server under systemd so it survives reboots:

```bash
sudo tee /etc/systemd/system/llama-server.service << 'EOF'
[Unit]
Description=llama.cpp inference server
After=network.target

[Service]
Type=simple
User=YOUR_USER
ExecStart=/path/to/llama-server -m /path/to/model.gguf --host 0.0.0.0 --port 8080 --jinja
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now llama-server
```
