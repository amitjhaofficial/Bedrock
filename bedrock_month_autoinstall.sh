#!/usr/bin/env bash
# bedrock_month_autoinstall.sh — One-command setup (30 days continuous OR $500 cap)
set -euo pipefail

# ---- Config (edit if needed) ----
MODEL_ID="anthropic.claude-4.5-sonnet"    # change to exact Bedrock model ID in your region
AWS_REGION="ap-south-1"
RPM=300
THREADS=12
AVG_IN=1000
AVG_OUT=300
PRICE_IN_PER_1K=0.003
PRICE_OUT_PER_1K=0.015
TARGET_USD=500
STOP_RATIO=0.995
STATUS_EVERY=15
MAX_SECONDS=$((30*24*3600))              # 30 days
SYSTEM_USER="${SUDO_USER:-$USER}"        # run as invoking user
# ----------------------------------

APP_DIR="/opt/bedrock-burner"
VENV_DIR="$APP_DIR/venv"
SERVICE="bedrock-month-burn"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

echo "[1/5] Creating app dir: $APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo chown -R "$SYSTEM_USER":"$SYSTEM_USER" "$APP_DIR"

echo "[2/5] Writing Python runner"
cat > "$APP_DIR/bedrock_burner.py" <<'PYEOF'
REPLACEME
PYEOF
# Replace placeholder with actual Python (keep permissions)
sudo sed -i 's#REPLACEME#'"$(printf '%s' "$(python3 - <<'INPY'
import sys,base64
b = """#!/usr/bin/env python3
"""
bedrock_burner.py — Continuous Bedrock caller with \$ cap or duration cap.

- Calls Amazon Bedrock (Claude 4.5 or any modelId) at a target RPM using threads.
- Tracks input/output tokens and estimates cost using provided prices.
- Stops automatically at TARGET_USD * STOP_RATIO or after MAX_SECONDS (whichever first).
- Prints periodic JSON status lines for easy monitoring.

Requirements: boto3 (installed by installer).
"""

import argparse, json, os, random, time, threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, asdict, field
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

def approx_token_text(token_count: int) -> str:
    chars_needed = max(8, int(token_count * 5))  # ~5 chars/token heuristic
    chunk = ("lorem ipsum dolor sit amet, " * 400)
    s, rem = [], chars_needed
    while rem > 0:
        add = chunk if len(chunk) <= rem else chunk[:rem]
        s.append(add); rem -= len(add)
    return "".join(s)

@dataclass
class Stats:
    sent: int = 0
    ok: int = 0
    err: int = 0
    throttle: int = 0
    in_tok: int = 0
    out_tok: int = 0
    start: float = field(default_factory=time.time)
    def dict(self):
        d = asdict(self)
        el = time.time() - self.start
        d["elapsed_sec"] = el
        d["rpm_actual"] = self.ok / (el/60) if el>0 else 0.0
        return d

def limiter(rpm: float):
    gap = 60.0 / rpm if rpm > 0 else 0.0
    next_t = time.perf_counter()
    while True:
        now = time.perf_counter()
        if now < next_t:
            time.sleep(next_t - now)
        yield
        next_t += gap

def invoke_once(client, model_id, prompt, max_tokens, temperature):
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": [{"role":"user","content":[{"type":"text","text":prompt}]}],
    }
    resp = client.invoke_model(
        modelId=model_id,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(body).encode("utf-8"),
    )
    payload = json.loads(resp["body"].read().decode("utf-8"))
    usage = payload.get("usage") or {}
    in_tok = usage.get("input_tokens") or usage.get("prompt_tokens") or 0
    out_tok = usage.get("output_tokens") or usage.get("completion_tokens") or 0
    if in_tok == 0:
        in_tok = int(len(prompt)/4.0)
    if out_tok == 0:
        text_out = ""
        for p in payload.get("content", []):
            if isinstance(p, dict) and p.get("type")=="text":
                text_out += p.get("text","")
        out_tok = int(len(text_out)/4.0) if text_out else int(max_tokens*0.7)
    return in_tok, out_tok

def should_stop(st, args):
    # USD cap
    if args.target_usd > 0 and (args.price_in>0 or args.price_out>0):
        est = (st.in_tok/1000.0)*args.price_in + (st.out_tok/1000.0)*args.price_out
        if est >= args.target_usd*args.stop_ratio:
            return True
    # Time cap
    if args.max_seconds>0 and (time.time()-st.start)>=args.max_seconds:
        return True
    return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-id", required=True)
    ap.add_argument("--region", required=True)
    ap.add_argument("--rpm", type=float, default=300.0)
    ap.add_argument("--threads", type=int, default=12)
    ap.add_argument("--avg-in", type=int, default=1000)
    ap.add_argument("--avg-out", type=int, default=300)
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--target-usd", type=float, default=500.0)
    ap.add_argument("--price-in", type=float, default=0.003, help="USD per 1k input tokens")
    ap.add_argument("--price-out", type=float, default=0.015, help="USD per 1k output tokens")
    ap.add_argument("--stop-ratio", type=float, default=0.995)
    ap.add_argument("--max-seconds", type=int, default=30*24*3600)
    ap.add_argument("--status-every", type=float, default=15.0)
    args = ap.parse_args()

    session = boto3.Session(region_name=args.region)
    client = session.client("bedrock-runtime", config=Config(retries={"max_attempts": 10, "mode": "standard"}))

    print(json.dumps({
        "plan": {
            "model_id": args.model_id, "region": args.region,
            "rpm": args.rpm, "threads": args.threads,
            "avg_in": args.avg_in, "avg_out": args.avg_out,
            "target_usd": args.target_usd, "prices_per_1k": {"in": args.price_in, "out": args.price_out},
            "stop_ratio": args.stop_ratio, "max_seconds": args.max_seconds
        }
    }))

    st = Stats()
    text = approx_token_text(args.avg_in)
    lock = threading.Lock()
    rate = limiter(args.rpm)

    def worker():
        nonlocal st
        while True:
            with lock:
                if should_stop(st, args):
                    return
            next(rate)
            try:
                tin, tout = invoke_once(client, args.model_id, text, args.avg_out, args.temperature)
                with lock:
                    st.sent += 1; st.ok += 1
                    st.in_tok += int(tin); st.out_tok += int(tout)
            except ClientError as e:
                with lock:
                    st.sent += 1; st.err += 1
                    code = e.response.get("Error",{}).get("Code","")
                    if "Throttle" in code:
                        st.throttle += 1
                time.sleep(0.5 + random.random())

    pool = ThreadPoolExecutor(max_workers=args.threads)
    futs = [pool.submit(worker) for _ in range(args.threads)]

    last = time.time()
    try:
        while any(not f.done() for f in futs):
            time.sleep(0.25)
            now = time.time()
            if now - last >= args.status_every:
                d = st.dict()
                est = (st.in_tok/1000.0)*args.price_in + (st.out_tok/1000.0)*args.price_out
                d["est_usd"] = est
                print("[STATUS]", json.dumps(d))
                last = now
            with lock:
                if should_stop(st, args):
                    break
        pool.shutdown(wait=False, cancel_futures=True)
    except KeyboardInterrupt:
        pool.shutdown(wait=False, cancel_futures=True)

    final = st.dict()
    final["est_usd"] = (st.in_tok/1000.0)*args.price_in + (st.out_tok/1000.0)*args.price_out
    print("=== FINAL ===")
    print(json.dumps(final, indent=2))

if __name__ == "__main__":
    main()
"""
print(b)
INPY
)")"'#' "$APP_DIR/bedrock_burner.py"

echo "[3/5] Creating venv and installing boto3"
sudo -u "$SYSTEM_USER" bash -c "python3 -m venv '$VENV_DIR' && source '$VENV_DIR/bin/activate' && pip install --upgrade pip boto3 botocore >/dev/null"

echo "[4/5] Creating systemd service"
sudo bash -c "cat > '$SERVICE_FILE' <<SVC
[Unit]
Description=Bedrock Month Burner (auto-stop at USD $TARGET_USD or 30 days)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SYSTEM_USER
Environment=AWS_REGION=$AWS_REGION
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/bedrock_burner.py \\\
  --model-id $MODEL_ID \\\
  --region $AWS_REGION \\\
  --rpm $RPM \\\
  --threads $THREADS \\\
  --avg-in $AVG_IN \\\
  --avg-out $AVG_OUT \\\
  --price-in $PRICE_IN_PER_1K \\\
  --price-out $PRICE_OUT_PER_1K \\\
  --target-usd $TARGET_USD \\\
  --stop-ratio $STOP_RATIO \\\
  --max-seconds $MAX_SECONDS \\\
  --status-every $STATUS_EVERY
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC"

echo "[5/5] Enabling and starting service: $SERVICE"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"

echo
echo "✅ Installed & started. It will run continuously (up to 30 days) and stop near \$$TARGET_USD."
echo "   Logs:    sudo journalctl -u $SERVICE -f"
echo "   Status:  sudo systemctl status $SERVICE"
echo "   Stop:    sudo systemctl stop $SERVICE"
echo "   Disable: sudo systemctl disable $SERVICE"
