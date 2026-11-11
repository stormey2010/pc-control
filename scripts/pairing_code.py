"""Create a private, local-only setup QR. Never prints pairing credentials."""
import base64
import html
import ipaddress
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit

deps = Path(os.environ["LOCALAPPDATA"]) / "PCControlRelease" / "python"
sys.path.insert(0, str(deps))
try:
    import qrcode
except ImportError:
    raise SystemExit("QR support is missing. Run Show-Pairing.ps1 to install it privately.")

directory = Path(os.environ["LOCALAPPDATA"]) / "PCControl"
source = directory / "connection.json"
connection = json.loads(source.read_text(encoding="utf-8"))
payload = {k: connection[k] for k in ("deviceId", "name", "port", "urls", "token", "certificateSha256")}
addresses = []
for raw in payload["urls"]:
    host = urlsplit(raw).hostname
    try:
        ip = ipaddress.ip_address(host)
        if ip.is_private and not ip.is_loopback and not ip.is_link_local:
            addresses.append(raw)
    except ValueError:
        if host and host.endswith(".local"):
            addresses.append(raw)
if not addresses:
    raise SystemExit("Connect this PC to Wi-Fi or Ethernet, restart PC Control, and try again.")
payload["urls"] = addresses
encoded = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")
qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=10, border=4)
qr.add_data("pccontrol://pair?data=" + encoded)
qr.make(fit=True)
qr.make_image(fill_color="black", back_color="white").save(directory / "pairing.png")
name = html.escape(str(payload["name"]))
(directory / "pairing.html").write_text("""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pair PC Control</title><style>body{font-family:system-ui,sans-serif;background:#0e181d;color:#e9f7f0;text-align:center;margin:0;padding:32px}main{max-width:720px;margin:auto}h1{font-size:32px}p{color:#bdccc6;line-height:1.6}img{display:block;width:min(100%,580px);height:auto;margin:24px auto;border-radius:16px}small{color:#bdccc6}</style><main><h1>Pair with """ + name + """</h1><p>Open PC Control on your iPhone and tap <strong>Scan PC setup code</strong>.<br>Keep both devices on the same Wi-Fi network.</p><img src="pairing.png" alt="Private PC Control setup code"><small>This code grants control of your PC. Keep it private.</small></main></html>""", encoding="utf-8")
print("Created private setup code in the PC Control installation folder.")
