"""Pop-up where Davis pastes the Roblox key Claude uses for Voltage County.

The key lets Claude publish new versions of the place and, from Phase 12, create game passes and developer
products. It is saved to %USERPROFILE%\\.voltage-county\\roblox_api_key, outside the repo, and never shown.

Launch it through explorer.exe (tools\\open_key_window.bat). Inside the Claude app's container the clipboard
is blocked, so pasting would do nothing there.
"""
import os
import subprocess
import tkinter as tk
import webbrowser
from pathlib import Path

KEY_FILE = Path.home() / ".voltage-county" / "roblox_api_key"
ANTHROPIC_KEY_FILE = Path.home() / ".voltage-county" / "anthropic_api_key"
KEY_PAGE = "https://create.roblox.com/dashboard/credentials"
CHROME = "C:/Program Files/Google/Chrome/Application/chrome.exe"
FONT = ("Segoe UI", 11)


def open_page(url):
    # Davis uses Chrome only; the default browser on his laptop was Edge.
    if os.path.exists(CHROME):
        subprocess.Popen([CHROME, url])
    else:
        webbrowser.open(url)


def looks_like_key(text: str) -> bool:
    text = text.strip()
    return len(text) >= 20 and not any(c.isspace() for c in text)


def main():
    root = tk.Tk()
    root.title("Roblox key for Voltage County")
    root.attributes("-topmost", True)
    root.resizable(False, False)
    pad = {"padx": 16, "pady": 6}

    already = KEY_FILE.exists()
    steps = (
        "1. Click \"Open the key page\", then Create API Key. Name it Voltage County.\n"
        "2. Under Access Permissions add these, each for the Voltage County experience:\n"
        "      Places: write\n"
        "      Game Passes: read and write\n"
        "      Developer Products: read and write\n"
        "3. Leave IP addresses empty, set no expiry, then Save and Generate Key.\n"
        "4. Copy the key, click in the box below, paste it (Ctrl+V), and click Save."
    )
    if already:
        steps = "A key is already saved. Pasting a new one replaces it.\n\n" + steps
    tk.Label(root, text=steps, justify="left", font=FONT).pack(anchor="w", **pad)
    tk.Button(root, text="Open the key page", font=FONT, command=lambda: open_page(KEY_PAGE)).pack(anchor="w", **pad)

    entry = tk.Entry(root, show="•", width=60, font=FONT)
    entry.pack(fill="x", **pad)
    status = tk.Label(root, text="", font=FONT)
    status.pack(anchor="w", **pad)

    def fill_from_clipboard(_event=None):
        if entry.get():
            return
        try:
            clip = root.clipboard_get()
        except tk.TclError:
            return
        if looks_like_key(clip):
            entry.insert(0, clip.strip())
            status.config(text="Pasted from your clipboard. Click Save.")

    def save():
        key = entry.get().strip()
        if not looks_like_key(key):
            status.config(text="That doesn't look like a key. Copy the whole key and paste again.")
            return
        # A Claude API key (for the AI Car Designer) is saved under its own name, so it never lands in the
        # Roblox key file.
        target = ANTHROPIC_KEY_FILE if key.startswith("sk-ant-") else KEY_FILE
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(key, encoding="utf-8")
        kind = "Claude" if target == ANTHROPIC_KEY_FILE else "Roblox"
        status.config(text=f"Saved as the {kind} key. You can close this window.")
        root.after(1500, root.destroy)

    entry.bind("<FocusIn>", fill_from_clipboard)
    tk.Button(root, text="Save", font=(FONT[0], FONT[1], "bold"), command=save).pack(anchor="e", **pad)
    root.mainloop()


if __name__ == "__main__":
    main()
