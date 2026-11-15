"""Local PC administration. No administration endpoint is exposed to the network."""

from __future__ import annotations

import asyncio
import ipaddress
import json
import os
import queue
import subprocess
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

from internet.pairing import Pairing
from internet.server import Gateway, load_pc

ROOT = Path(__file__).resolve().parent.parent
GODOT = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe")
ADB = Path(r"C:\Android\Sdk\platform-tools\adb.exe")
STATE = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "WoRkPlace" / "internet"
PORT = 47930


def tailscale_address():
    """Read only this device's overlay address, never endpoints or peer metadata."""
    executable = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tailscale" / "tailscale.exe"
    if not executable.is_file():
        return ""
    try:
        result = subprocess.run([str(executable), "ip", "-4"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode != 0:
            return ""
        values = result.stdout.decode("ascii").strip().splitlines()
        if len(values) != 1:
            return ""
        address = ipaddress.IPv4Address(values[0])
        return str(address) if address in ipaddress.IPv4Network("100.64.0.0/10") else ""
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return ""


class Desktop:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("WoRkPlace: подключение через интернет")
        self.root.geometry("640x650")
        self.events = queue.Queue()
        self.loop = asyncio.new_event_loop()
        self.gateway = None
        self.server = None
        self.device_ids = []
        self.pending = []
        self.code_until = 0.0
        self.status = tk.StringVar(value="Подготовка защищённого сервера…")
        self.endpoint = tk.StringVar()
        self.code = tk.StringVar(value="—")
        self.check = tk.StringVar(value="Запросов на привязку нет")
        STATE.mkdir(parents=True, exist_ok=True)
        settings = STATE / "desktop.json"
        if settings.exists():
            self.endpoint.set(json.loads(settings.read_text(encoding="utf-8")).get("endpoint", ""))
        if not self.endpoint.get():
            # Local bootstrap only. Never query a public-address service, SSID,
            # DNS configuration, MAC, provider, account region or timezone.
            try:
                probe = subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                    "$p=Get-NetAdapter -Physical | Where-Object {$_.Status -eq 'Up'}; "
                    "$a=Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceIndex -in $p.ifIndex -and $_.AddressState -eq 'Preferred' -and $_.IPAddress -match '^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)'}; "
                    "if(@($a).Count -eq 1){$a.IPAddress}"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                value = probe.stdout.decode(errors="replace").strip()
                if value:
                    self.endpoint.set(value)
            except (OSError, subprocess.TimeoutExpired):
                pass
        box = ttk.Frame(self.root, padding=20)
        box.pack(fill="both", expand=True)
        ttk.Label(box, textvariable=self.status, wraplength=570).pack(anchor="w", pady=(0, 16))
        ttk.Label(box, text="Адрес подключения к этому ПК (укажи самостоятельно)").pack(anchor="w")
        ttk.Entry(box, textvariable=self.endpoint).pack(fill="x", pady=6)
        ttk.Button(box, text="Использовать адрес Tailscale этого ПК", command=self.use_tailscale).pack(fill="x", pady=4)
        ttk.Label(box, text="Через Tailscale: подключи ПК и Quest к одному аккаунту;\nнастройка роутера не требуется. Для прямого доступа извне\nнужен входящий TCP-порт 47930. Публичный адрес не определяется.").pack(anchor="w")
        ttk.Button(box, text="Передать настройки в Quest по USB и перезапустить его", command=self.prepare_headset).pack(fill="x", pady=12)
        ttk.Separator(box).pack(fill="x", pady=4)
        self.code_button = ttk.Button(box, text="Создать одноразовый код", command=self.create_code, state="disabled")
        self.code_button.pack(fill="x", pady=5)
        ttk.Label(box, textvariable=self.code, font=("Segoe UI", 24)).pack()
        ttk.Label(box, text="Код действует 2 минуты. После ввода в Quest сравни проверочные символы.").pack(anchor="w")
        ttk.Label(box, textvariable=self.check, wraplength=570).pack(anchor="w", pady=8)
        actions = ttk.Frame(box)
        actions.pack(fill="x")
        ttk.Button(actions, text="Подтвердить совпадение", command=lambda: self.confirm(True)).pack(side="left")
        ttk.Button(actions, text="Отклонить", command=lambda: self.confirm(False)).pack(side="left", padx=8)
        ttk.Label(box, text="Привязанные устройства").pack(anchor="w", pady=(15, 3))
        self.devices = tk.Listbox(box, height=3)
        self.devices.pack(fill="x")
        ttk.Button(box, text="Отозвать доступ выбранного устройства", command=self.revoke).pack(fill="x", pady=8)
        threading.Thread(target=self.run_server, daemon=True).start()
        self.root.after(100, self.poll_events)
        self.root.protocol("WM_DELETE_WINDOW", self.close)

    def mode(self):
        try:
            value = int((STATE.parent / "work_mode.txt").read_text(encoding="ascii").strip())
            return value if value in (0, 1, 2, 3) else -1
        except (ValueError, OSError):
            return -1

    def run_server(self):
        asyncio.set_event_loop(self.loop)

        async def start():
            key, cert = STATE / "server.key", STATE / "server.crt"
            if not key.exists() or not cert.exists():
                result = await asyncio.to_thread(subprocess.run,
                    [str(GODOT), "--headless", "--xr-mode", "off", "--path", str(ROOT),
                     "-s", "tools/internet_certificate.gd", "--", str(STATE)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
                if result.returncode != 0:
                    raise RuntimeError("certificate_generation_failed")
            self.store = Pairing(STATE / "devices.sqlite3")
            self.gateway = Gateway(self.store, load_pc(self.store, STATE), mode=self.mode)
            self.server = await self.gateway.listen("0.0.0.0", PORT, cert, key)
            self.events.put(("ready", None))

        try:
            self.loop.run_until_complete(start())
            self.loop.run_forever()
        except Exception as error:
            self.events.put(("error", type(error).__name__))
        finally:
            if self.server:
                self.server.close()
                self.loop.run_until_complete(self.server.wait_closed())
            tasks = asyncio.all_tasks(self.loop)
            for task in tasks:
                task.cancel()
            if tasks:
                self.loop.run_until_complete(asyncio.gather(*tasks, return_exceptions=True))
            if self.gateway:
                self.store.close()
            self.loop.close()

    def call(self, action, callback):
        if not self.gateway or self.loop.is_closed():
            return

        async def run():
            try:
                value = action()
                self.events.put(("callback", (callback, value)))
            except Exception as error:
                self.events.put(("error", type(error).__name__))

        asyncio.run_coroutine_threadsafe(run(), self.loop)

    def create_code(self):
        self.call(self.gateway.create_code, self.show_code)

    def show_code(self, value):
        self.code.set(value["code"][:4] + " " + value["code"][4:])
        self.code_until = time.monotonic() + value["expires_in"]

    def confirm(self, approve):
        if self.pending:
            request = self.pending[0]["request"]
            self.call(lambda: self.gateway.confirm(request, approve), lambda _: self.check.set("Решение сохранено"))

    def revoke(self):
        selected = self.devices.curselection()
        if selected and selected[0] < len(self.device_ids):
            device = self.device_ids[selected[0]]
            self.call(lambda: self.gateway.revoke(device), lambda _: self.status.set("Доступ отозван; активные каналы закрыты"))

    def use_tailscale(self):
        def read():
            address = tailscale_address()
            def apply(value):
                if value:
                    self.endpoint.set(value)
                    self.status.set("Выбран адрес Tailscale. Передай настройки в Quest по USB.")
                else:
                    self.status.set("Адрес Tailscale недоступен. Войди в Tailscale на ПК и включи соединение.")
            self.events.put(("callback", (apply, address)))
        threading.Thread(target=read, daemon=True).start()

    def prepare_headset(self):
        endpoint = self.endpoint.get().strip()
        if not endpoint or len(endpoint) > 253 or any(c in endpoint for c in "/\\@\r\n\t "):
            messagebox.showerror("Адрес подключения", "Укажи адрес ПК без протокола и номера порта. Значение никуда не отправляется автоматически.")
            return
        if not (STATE / "server.crt").exists():
            return
        (STATE / "desktop.json").write_text(json.dumps({"endpoint": endpoint}), encoding="utf-8")
        profile = {"v": 1, "host": endpoint, "port": PORT,
                   "certificate": (STATE / "server.crt").read_text(encoding="ascii")}

        def transfer():
            try:
                def adb(*args, data=None):
                    return subprocess.run([str(ADB), *args], input=data, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, timeout=10,
                                          creationflags=subprocess.CREATE_NO_WINDOW, check=True).stdout
                devices = [line.split()[0] for line in adb("devices").decode().splitlines()
                           if line.endswith("\tdevice")]
                if len(devices) != 1:
                    raise RuntimeError("one_usb_device_required")
                target = ["-s", devices[0]]
                adb(*target, "reverse", "tcp:47930", "tcp:47930")
                adb(*target, "shell", "run-as", "com.workplace.headset", "tee", "files/internet_connection.json",
                    data=json.dumps(profile).encode("utf-8"))
                adb(*target, "shell", "am", "force-stop", "com.workplace.headset")
                adb(*target, "shell", "am", "start", "-n", "com.workplace.headset/com.godot.game.GodotAppLauncher")
                self.events.put(("status", "Настройки переданы по USB. Открой вход в интернет в шлеме."))
            except Exception as error:
                self.events.put(("error", type(error).__name__))

        threading.Thread(target=transfer, daemon=True).start()

    def poll_events(self):
        if self.code_until and time.monotonic() >= self.code_until:
            self.code.set("Срок кода истёк")
            self.code_until = 0.0
        while not self.events.empty():
            kind, value = self.events.get_nowait()
            if kind == "ready":
                self.status.set("Сервер запущен. Для Tailscale выбери его адрес и передай настройки в Quest.")
                self.code_button.configure(state="normal")
            elif kind == "error":
                self.status.set("Операция не выполнена: " + value)
            elif kind == "status":
                self.status.set(value)
            else:
                callback, data = value
                callback(data)
        if self.gateway and not self.loop.is_closed():
            self.call(lambda: (self.gateway.requests(), self.store.devices(self.gateway.pc, "pc")), self.update_devices)
        self.root.after(1000, self.poll_events)

    def update_devices(self, value):
        self.pending, devices = value
        self.check.set("Сравни с Quest: " + self.pending[0]["check"] if self.pending else "Запросов на привязку нет")
        if devices != self.device_ids:
            self.device_ids = devices
            self.devices.delete(0, "end")
            for index in range(len(devices)):
                self.devices.insert("end", "Шлем " + str(index + 1))

    def close(self):
        if self.gateway and not self.loop.is_closed():
            self.loop.call_soon_threadsafe(self.loop.stop)
        self.root.destroy()


if __name__ == "__main__":
    Desktop().root.mainloop()
