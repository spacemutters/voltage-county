"""Pop-up where Davis pastes the Meshy key Claude uses to make Voltage County's realistic cars.

Meshy turns a picture of an original car into a detailed 3D model (image to 3D). The key is saved to
%USERPROFILE%\\.voltage-county\\meshy_api_key, outside the repo, and never shown. Saving checks it against Meshy
(the balance call) so a wrong paste is caught at once.

Launch it through explorer.exe (tools\\open_meshy_key_window.bat).
"""
import json
import os
import subprocess
import tkinter as tk
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

KEY_FILE = Path.home() / ".voltage-county" / "meshy_api_key"
PLAN_PAGE = "https://www.meshy.ai/pricing"
KEY_PAGE = "https://www.meshy.ai/settings/api"
BALANCE = "https://api.meshy.ai/openapi/v1/balance"
CHROME = "C:/Program Files/Google/Chrome/Application/chrome.exe"


def open_page(url):
    # Davis uses Chrome only.
    if os.path.exists(CHROME):
        subprocess.Popen([CHROME, url])
    else:
        webbrowser.open(url)


def check(key: str) -> str:
    """'' when Meshy accepts the key, otherwise what went wrong in plain words."""
    request = urllib.request.Request(BALANCE, headers={"Authorization": f"Bearer {key}"})
    try:
        with urllib.request.urlopen(request, timeout=20) as reply:
            body = json.loads(reply.read().decode("utf-8") or "{}")
            return "" if "balance" in body or reply.status == 200 else "Meshy didn't recognise that key."
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            return "Meshy says that key isn't valid. Copy it again from the API page."
        return f"Meshy answered with an error ({error.code}). Try again in a minute."
    except Exception:
        return "Couldn't reach Meshy. Check the internet connection and try again."


def main():
    root = tk.Tk()
    root.title("Meshy key for Voltage County")
    root.attributes("-topmost", True)
    root.resizable(False, False)
    pad = {"padx": 16, "pady": 6}

    steps = (
        "1. Click \"Open Meshy plans\". Sign up and choose the Pro plan (it includes the API).\n"
        "2. Click \"Open the key page\" and create an API key. Copy it.\n"
        "3. Paste it below and click Save. Claude takes it from there."
    )
    tk.Label(root, text=steps, justify="left").pack(anchor="w", **pad)
    buttons = tk.Frame(root)
    buttons.pack(anchor="w", **pad)
    tk.Button(buttons, text="Open Meshy plans", command=lambda: open_page(PLAN_PAGE)).pack(side="left", padx=(0, 8))
    tk.Button(buttons, text="Open the key page", command=lambda: open_page(KEY_PAGE)).pack(side="left")

    entry = tk.Entry(root, width=60, show="•")
    entry.pack(**pad)
    status = tk.Label(root, text="Already saved: paste a new one to replace it." if KEY_FILE.exists() else "")
    status.pack(anchor="w", **pad)

    def save():
        key = entry.get().strip()
        if len(key) < 16 or any(c.isspace() for c in key):
            status.config(text="That doesn't look like a Meshy key. Copy the whole key and paste it again.")
            return
        status.config(text="Checking with Meshy...")
        root.update()
        problem = check(key)
        if problem:
            status.config(text=problem)
            return
        KEY_FILE.parent.mkdir(parents=True, exist_ok=True)
        KEY_FILE.write_text(key, encoding="utf-8")
        entry.delete(0, "end")
        status.config(text="Saved and working. You can close this window and tell Claude.")

    tk.Button(root, text="Save", command=save, width=12).pack(**pad)
    root.mainloop()


if __name__ == "__main__":
    main()
