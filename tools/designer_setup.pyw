"""Pop-up that connects the AI Car Designer's backend (Phase 11) in one go.

Davis pastes one key (the database's secret key from Supabase) and clicks Save and go live. The window then:
  * saves four values to the Vercel project voltage-county-designer (Production): his Claude key (already saved on
    this laptop by tools/key_window.pyw), the database address, the database key he pasted, and a new random game
    password (ROBLOX_SHARED_SECRET),
  * redeploys the backend so it picks them up,
  * keeps the game password in %USERPROFILE%\\.voltage-county\\designer_shared_secret so Copy works later.
Then he copies the game password into the experience's Secrets store as designer_key (Roblox has no API for that).

Changing the game password (docs/SECURITY.md "Rotating the game password") is two clicks here plus the two pastes:
  * Change game password: keeps the current one working as ROBLOX_SHARED_SECRET_PREVIOUS, saves a new one as
    ROBLOX_SHARED_SECRET and in the file above, and redeploys. Clicking it again before Finish only retries.
  * Finish change: once Roblox has the new password and the old servers are gone, removes the previous one and
    redeploys.

Nothing is shown on screen or written to the repo. Launch it through explorer.exe (tools\\open_designer_setup.bat):
inside the Claude app's container the clipboard is blocked, so pasting would do nothing there.
"""
import os
import secrets
import shutil
import subprocess
import threading
import tkinter as tk
import webbrowser
from tkinter import messagebox
from pathlib import Path

HOME = Path.home() / ".voltage-county"
ANTHROPIC_KEY_FILE = HOME / "anthropic_api_key"
SHARED_SECRET_FILE = HOME / "designer_shared_secret"
# The old game password while a change is under way (between Change game password and Finish change).
PREVIOUS_SECRET_FILE = HOME / "designer_shared_secret_previous"
BACKEND_DIR = Path(__file__).resolve().parent.parent / "backend"
SCOPE = "spacemutters-projects"
SUPABASE_URL = "https://cfgqkyouedwidwoivnpw.supabase.co"
SUPABASE_KEYS_PAGE = "https://supabase.com/dashboard/project/cfgqkyouedwidwoivnpw/settings/api-keys"
ROBLOX_SECRETS_PAGE = "https://create.roblox.com/dashboard/creations/experiences/10772006656/configure"
BACKEND_DOMAIN = "voltage-county-designer.vercel.app"
CHROME = "C:/Program Files/Google/Chrome/Application/chrome.exe"
FONT = ("Segoe UI", 11)
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def open_page(url):
    # Davis uses Chrome only.
    if os.path.exists(CHROME):
        subprocess.Popen([CHROME, url])
    else:
        webbrowser.open(url)


def looks_like_key(text: str) -> bool:
    text = text.strip()
    return len(text) >= 30 and not any(c.isspace() for c in text)


def vercel_cmd():
    return shutil.which("vercel.cmd") or shutil.which("vercel") or "vercel"


def set_env(name: str, value: str) -> None:
    """Replaces one Production env var on the backend's Vercel project. The value goes in on stdin, never argv."""
    base = [vercel_cmd()]
    subprocess.run(
        base + ["env", "rm", name, "production", "--yes", "--scope", SCOPE],
        cwd=BACKEND_DIR, capture_output=True, text=True, creationflags=NO_WINDOW, timeout=120,
    )
    done = subprocess.run(
        base + ["env", "add", name, "production", "--scope", SCOPE],
        cwd=BACKEND_DIR, input=value, capture_output=True, text=True, creationflags=NO_WINDOW, timeout=120,
    )
    if done.returncode != 0:
        raise RuntimeError(f"Vercel didn't take {name}. Is the Vercel sign-in still good on this laptop?")


def redeploy() -> None:
    done = subprocess.run(
        [vercel_cmd(), "--prod", "--yes", "--scope", SCOPE],
        cwd=BACKEND_DIR, capture_output=True, text=True, creationflags=NO_WINDOW, timeout=600,
    )
    if done.returncode != 0:
        raise RuntimeError("The redeploy didn't finish. Click the same button again.")


def shared_secret() -> str:
    """The game password: made once, then reused, so the Roblox side never needs changing again."""
    if SHARED_SECRET_FILE.exists():
        existing = SHARED_SECRET_FILE.read_text(encoding="utf-8").strip()
        if len(existing) >= 32:
            return existing
    HOME.mkdir(parents=True, exist_ok=True)
    made = secrets.token_urlsafe(36)
    SHARED_SECRET_FILE.write_text(made, encoding="utf-8")
    return made


def change_password(say) -> None:
    """Starts a game password change: the old one keeps working until finish_change. Safe to click again."""
    if PREVIOUS_SECRET_FILE.exists():
        # A change is already under way (maybe its redeploy failed): send the same two values again.
        old = PREVIOUS_SECRET_FILE.read_text(encoding="utf-8").strip()
        new = shared_secret()
    else:
        if not SHARED_SECRET_FILE.exists():
            raise RuntimeError("There's no game password yet. Use Save and go live first.")
        old = shared_secret()
        new = secrets.token_urlsafe(36)
        PREVIOUS_SECRET_FILE.write_text(old, encoding="utf-8")
        SHARED_SECRET_FILE.write_text(new, encoding="utf-8")
    say("Saving 1 of 2…")
    set_env("ROBLOX_SHARED_SECRET_PREVIOUS", old)
    say("Saving 2 of 2…")
    set_env("ROBLOX_SHARED_SECRET", new)
    say("Restarting the designer (about a minute)…")
    redeploy()


def finish_change(say) -> None:
    """Ends a game password change: only the new one works after this."""
    if not PREVIOUS_SECRET_FILE.exists():
        raise RuntimeError("No password change is under way.")
    say("Removing the old password…")
    done = subprocess.run(
        [vercel_cmd(), "env", "rm", "ROBLOX_SHARED_SECRET_PREVIOUS", "production", "--yes", "--scope", SCOPE],
        cwd=BACKEND_DIR, capture_output=True, text=True, creationflags=NO_WINDOW, timeout=120,
    )
    if done.returncode != 0 and "not found" not in (done.stdout + done.stderr).lower():
        raise RuntimeError("Vercel didn't remove the old password. Is the Vercel sign-in still good on this laptop?")
    say("Restarting the designer (about a minute)…")
    redeploy()
    PREVIOUS_SECRET_FILE.unlink()


def main():
    root = tk.Tk()
    root.title("AI Car Designer setup")
    root.attributes("-topmost", True)
    root.resizable(False, False)
    pad = {"padx": 16, "pady": 6}

    steps = (
        "This connects the AI Car Designer. Three steps:\n\n"
        "1. Click \"Open database keys\". Copy the Secret key (it starts with sb_secret_, or the one\n"
        "   labelled service_role), click in the box below and paste it (Ctrl+V).\n"
        "2. Click \"Save and go live\" and wait about a minute. It saves your Claude key (already on this\n"
        "   laptop), the database, that key and a new game password to the designer, and restarts it.\n"
        "3. Click \"Copy game password\", then \"Open Roblox secrets\". In the experience's Secrets, create one\n"
        f"   named designer_key, paste the password, and set the domain to {BACKEND_DOMAIN}.\n"
        "   For testing in Studio, add the same under File > Experience Settings > Security, Local Secrets.\n\n"
        "To change the game password: click \"Change game password\", then copy it into Roblox and Studio as in\n"
        "step 3 (edit the designer_key you made). A day later (or after restarting the servers), click \"Finish change\"."
    )
    tk.Label(root, text=steps, justify="left", font=FONT).pack(anchor="w", **pad)
    tk.Button(root, text="Open database keys", font=FONT, command=lambda: open_page(SUPABASE_KEYS_PAGE)).pack(
        anchor="w", **pad
    )

    entry = tk.Entry(root, show="•", width=64, font=FONT)
    entry.pack(fill="x", **pad)
    status = tk.Label(root, text="", font=FONT, justify="left")

    buttons = tk.Frame(root)
    buttons.pack(anchor="w", **pad)
    go_live = tk.Button(buttons, text="Save and go live", font=FONT)
    go_live.pack(side="left")
    copy_btn = tk.Button(buttons, text="Copy game password", font=FONT)
    copy_btn.pack(side="left", padx=(12, 0))
    tk.Button(buttons, text="Open Roblox secrets", font=FONT, command=lambda: open_page(ROBLOX_SECRETS_PAGE)).pack(
        side="left", padx=(12, 0)
    )
    rotate_row = tk.Frame(root)
    rotate_row.pack(anchor="w", **pad)
    change_btn = tk.Button(rotate_row, text="Change game password", font=FONT)
    change_btn.pack(side="left")
    finish_btn = tk.Button(rotate_row, text="Finish change", font=FONT)
    finish_btn.pack(side="left", padx=(12, 0))
    status.pack(anchor="w", **pad)
    busy_buttons = (go_live, change_btn, finish_btn)

    def say(text: str, color: str = "black"):
        root.after(0, lambda: status.config(text=text, fg=color))

    def work(db_key: str):
        try:
            if not ANTHROPIC_KEY_FILE.exists():
                raise RuntimeError("Your Claude key isn't saved on this laptop. Run tools\\open_key_window.bat first.")
            claude_key = ANTHROPIC_KEY_FILE.read_text(encoding="utf-8").strip()
            values = [
                ("ANTHROPIC_API_KEY", claude_key),
                ("SUPABASE_URL", SUPABASE_URL),
                ("SUPABASE_SERVICE_ROLE_KEY", db_key),
                ("ROBLOX_SHARED_SECRET", shared_secret()),
            ]
            for index, (name, value) in enumerate(values, start=1):
                say(f"Saving {index} of {len(values)}…")
                set_env(name, value)
            say("Restarting the designer (about a minute)…")
            redeploy()
            say("Done. The designer is live. Now step 3: copy the game password into Roblox.", "darkgreen")
        except Exception as error:  # noqa: BLE001 - shown to Davis in plain words
            say(str(error), "firebrick")
        finally:
            root.after(0, lambda: [button.config(state="normal") for button in busy_buttons])

    def on_go_live():
        db_key = entry.get().strip()
        if not looks_like_key(db_key):
            say("That doesn't look like the database key. Copy the whole Secret key and paste it again.", "firebrick")
            return
        for button in busy_buttons:
            button.config(state="disabled")
        entry.delete(0, "end")
        threading.Thread(target=work, args=(db_key,), daemon=True).start()

    def run(job, done_text: str):
        def body():
            try:
                job(say)
                say(done_text, "darkgreen")
            except Exception as error:  # noqa: BLE001 - shown to Davis in plain words
                say(str(error), "firebrick")
            finally:
                root.after(0, lambda: [button.config(state="normal") for button in busy_buttons])

        for button in busy_buttons:
            button.config(state="disabled")
        threading.Thread(target=body, daemon=True).start()

    def on_change():
        run(
            change_password,
            "New password is live; the old one still works. Click Copy game password and paste it into Roblox's\n"
            "designer_key secret and Studio's Local Secrets. Click Finish change a day later.",
        )

    def on_finish():
        sure = messagebox.askyesno(
            "Finish change",
            "Is the new password in Roblox's designer_key secret, and have the game servers restarted (or a day "
            "passed)?\n\nAfter this, only the new password works.",
            parent=root,
        )
        if sure:
            run(finish_change, "Done. Only the new game password works now.")

    def on_copy():
        root.clipboard_clear()
        root.clipboard_append(shared_secret())
        root.update()
        say("Game password copied. Paste it into Roblox as the designer_key secret.", "darkgreen")

    go_live.config(command=on_go_live)
    copy_btn.config(command=on_copy)
    change_btn.config(command=on_change)
    finish_btn.config(command=on_finish)
    root.mainloop()


if __name__ == "__main__":
    main()
