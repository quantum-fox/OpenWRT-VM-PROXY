#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pw2-gui - окно управления роутером OpenWRT-VM-PROXY (Windows и Linux).

Программа ничего не ставит на компьютер и не хранит пароли: она вызывает по SSH те же команды роутера
(pw2-exit, pw2-ru-mode, pw2-ali-mode, pw2-ads, pw2-device, pw2-wan, pw2-lan, pw2-update ...), что и командная строка.
Нужно: Python 3.8+ с tkinter (Windows: входит в установщик python.org; Debian/Ubuntu: apt install python3-tk) и клиент ssh
(Windows 10/11: «Дополнительные компоненты -> Клиент OpenSSH»). Вход на роутер должен быть по ключу (кнопка «Настроить вход по ключу»).
Запуск: python pw2-gui.py   (на Windows - двойной щелчок по pw2-gui.cmd)
Проверка без окна: python pw2-gui.py --self-test
"""
import base64
import json
import os
import queue
import re
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

APP = "pw2 — управление роутером"
IS_WIN = sys.platform.startswith("win")
NO_WINDOW = 0x08000000 if IS_WIN else 0


def cfg_path():
    base = os.environ.get("APPDATA") if IS_WIN else os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base or os.path.expanduser("~"), "pw2-gui", "config.json")


def load_cfg():
    cfg = {"host": "openwrt", "tools_dir": ""}
    try:
        with open(cfg_path(), encoding="utf-8") as f:
            cfg.update(json.load(f))
    except Exception:
        pass
    return cfg


def save_cfg(cfg):
    try:
        os.makedirs(os.path.dirname(cfg_path()), exist_ok=True)
        with open(cfg_path(), "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def find_dir(*names):
    here = os.path.dirname(os.path.abspath(__file__))
    for n in names:
        p = os.path.normpath(os.path.join(here, "..", n))
        if os.path.isdir(p):
            return p
    return ""


class Router:
    """Вызов команд роутера по SSH."""

    def __init__(self, host):
        self.host = host

    def _base(self):
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "LogLevel=ERROR", self.host]

    @staticmethod
    def _clean(text):
        return "\n".join(l for l in text.replace("\r\n", "\n").split("\n") if not l.startswith("**"))

    def run(self, cmd, timeout=90, data=None):
        """-> (код, вывод). Вывод - stdout; при ошибке к нему добавляется stderr."""
        try:
            p = subprocess.run(self._base() + [cmd], input=data, capture_output=True, timeout=timeout,
                               creationflags=NO_WINDOW)
        except FileNotFoundError:
            return 127, "Не найден клиент ssh. Windows: «Параметры -> Приложения -> Дополнительные компоненты -> Клиент OpenSSH»; Linux: apt install openssh-client."
        except subprocess.TimeoutExpired:
            return 124, "Нет ответа от роутера за %d с." % timeout
        out = self._clean(p.stdout.decode("utf-8", "replace"))
        err = self._clean(p.stderr.decode("utf-8", "replace")).strip()
        if p.returncode != 0 and err:
            out = (out + "\n" + err).strip()
        return p.returncode, out

    def stream(self, cmd, emit, data=None):
        """Команда с выводом по мере появления (обновление, перезапуск): emit(строка)."""
        try:
            p = subprocess.Popen(self._base() + [cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
        except FileNotFoundError:
            emit("Не найден клиент ssh.")
            return 127
        if data is not None:
            try:
                p.stdin.write(data)
            except OSError:
                pass
        try:
            p.stdin.close()
        except OSError:
            pass
        for raw in p.stdout:
            line = self._clean(raw.decode("utf-8", "replace")).rstrip()
            if line:
                emit(line)
        return p.wait()

    def upload(self, local_dir, emit):
        """Загрузка скриптов роутера (как install-router.ps1 / install-router.sh)."""
        if not os.path.isfile(os.path.join(local_dir, "pw2-setup")):
            emit("В выбранной папке нет файла pw2-setup: выберите папку tools/router (или tools/openwrt).")
            return False
        rc, out = self.run("mkdir -p /usr/share/pw2/data")
        if rc != 0:
            emit("Нет входа на роутер по SSH: " + out)
            return False
        names = [n for n in sorted(os.listdir(local_dir))
                 if os.path.isfile(os.path.join(local_dir, n))
                 and (re.match(r"^\d\d-.*\.sh$", n) or n.startswith("pw2-") or re.match(r"^verify-.*\.sh$", n)
                      or n in ("VERSION", "secrets.env.example"))]
        count = 0
        for n in names:
            with open(os.path.join(local_dir, n), "rb") as f:
                data = f.read().replace(b"\r\n", b"\n")
            rc, out = self.run("cat > /usr/share/pw2/%s" % n, data=data)
            if rc != 0:
                emit("Не удалось передать %s: %s" % (n, out))
                return False
            count += 1
        ddir = os.path.join(local_dir, "data")
        if os.path.isdir(ddir):
            for n in sorted(os.listdir(ddir)):
                fp = os.path.join(ddir, n)
                if os.path.isfile(fp):
                    with open(fp, "rb") as f:
                        data = f.read()
                    rc, out = self.run("cat > /usr/share/pw2/data/%s" % n, data=data, timeout=180)
                    if rc != 0:
                        emit("Не удалось передать data/%s: %s" % (n, out))
                        return False
                    count += 1
        self.run("chmod +x /usr/share/pw2/*; cp /usr/share/pw2/pw2-setup /usr/bin/pw2-setup; chmod +x /usr/bin/pw2-setup")
        emit("Готово: загружено файлов: %d (в /usr/share/pw2). Дальше: «Обновить скрипты на роутере»." % count)
        return True


class App:
    def __init__(self, test=False):
        self.cfg = load_cfg()
        self.r = Router(self.cfg["host"])
        self.q = queue.Queue()
        self.busy = False
        self.test = test
        self.root = tk.Tk()
        self.root.title(APP)
        self.root.geometry("980x720")
        if test:
            self.root.withdraw()
        self.vars = {}
        self._build()
        self.root.after(100, self._poll)

    # ---------- фоновые задачи ----------
    def bg(self, work, done=None):
        def target():
            try:
                res = work()
            except Exception as e:  # noqa: BLE001
                res = e
            self.q.put((done, res))
        threading.Thread(target=target, daemon=True).start()

    def _poll(self):
        try:
            while True:
                done, res = self.q.get_nowait()
                if isinstance(res, Exception):
                    self.log("Ошибка программы: %r" % (res,))
                elif done:
                    done(res)
        except queue.Empty:
            pass
        self.root.after(100, self._poll)

    def log(self, text):
        self.logbox.configure(state="normal")
        self.logbox.insert("end", text + "\n")
        self.logbox.see("end")
        self.logbox.configure(state="disabled")

    def set_status(self, text):
        """Надпись состояния можно менять только из главного потока: из фоновых потоков - через очередь."""
        self.q.put((lambda _r, t=text: self.status_var.set(t), None))

    def qlog(self, text):
        self.q.put((lambda _r, t=text: self.log(t), None))

    def run_cmd(self, cmd, title=None, after=None, timeout=180, data=None):
        """Команда роутера в фоне; вывод в журнал; after() - обновить экран."""
        if title:
            self.log("» " + title)

        def work():
            self.set_status("Выполняется…")
            rc, out = self.r.run(cmd, timeout=timeout, data=data)
            return rc, out

        def done(res):
            rc, out = res
            if out:
                self.log(out)
            if rc != 0:
                self.log("(код возврата %d)" % rc)
            self.status_var.set("Готово")
            if after:
                after()
        self.bg(work, done)

    def stream_cmd(self, cmd, title, after=None, data=None):
        self.log("» " + title)

        def work():
            self.set_status("Выполняется…")
            rc = self.r.stream(cmd, self.qlog, data=data)
            return rc

        def done(rc):
            self.log("(готово, код %s)" % rc)
            self.status_var.set("Готово")
            if after:
                after()
        self.bg(work, done)

    # ---------- интерфейс ----------
    def _build(self):
        top = ttk.Frame(self.root, padding=6)
        top.pack(fill="x")
        ttk.Label(top, text="Роутер (имя из ~/.ssh/config или root@адрес):").pack(side="left")
        self.host_var = tk.StringVar(value=self.cfg["host"])
        e = ttk.Entry(top, textvariable=self.host_var, width=22)
        e.pack(side="left", padx=4)
        ttk.Button(top, text="Подключиться", command=self.connect).pack(side="left")
        ttk.Button(top, text="Настроить вход по ключу", command=self.setup_key).pack(side="left", padx=6)
        self.status_var = tk.StringVar(value="")
        ttk.Label(top, textvariable=self.status_var, foreground="#555").pack(side="right")

        self.nb = ttk.Notebook(self.root)
        self.nb.pack(fill="both", expand=True, padx=6)
        self._tab_status()
        self._tab_servers()
        self._tab_routes()
        self._tab_devices()
        self._tab_setup()
        if IS_WIN:
            self._tab_windows()

        lf = ttk.LabelFrame(self.root, text="Журнал")
        lf.pack(fill="both", expand=False, padx=6, pady=6)
        self.logbox = tk.Text(lf, height=9, wrap="word", state="disabled", font=("Consolas" if IS_WIN else "monospace", 9))
        sb = ttk.Scrollbar(lf, command=self.logbox.yview)
        self.logbox.configure(yscrollcommand=sb.set)
        self.logbox.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.nb.bind("<<NotebookTabChanged>>", self._tab_changed)

    def _mono(self, parent, height=18):
        t = tk.Text(parent, height=height, wrap="none", state="disabled", font=("Consolas" if IS_WIN else "monospace", 10))
        return t

    def _set_text(self, widget, text):
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        widget.insert("1.0", text)
        widget.configure(state="disabled")

    # --- Состояние
    def _tab_status(self):
        f = ttk.Frame(self.nb, padding=8)
        self.nb.add(f, text="Состояние")
        bar = ttk.Frame(f)
        bar.pack(fill="x")
        ttk.Button(bar, text="Обновить", command=self.refresh_status).pack(side="left")
        ttk.Button(bar, text="Проверить выходы (IP 1080 / 1081)", command=self.check_exits).pack(side="left", padx=6)
        self.status_text = self._mono(f, 24)
        self.status_text.pack(fill="both", expand=True, pady=6)

    def refresh_status(self):
        cmd = ("echo '== версия скриптов:' $(cat /etc/pw2-version 2>/dev/null); echo; echo '== выбор серверов'; pw2-exit status; echo;"
               " echo '== российские ресурсы'; pw2-ru-mode status | head -1; echo; echo '== AliExpress'; pw2-ali-mode status | head -1; echo;"
               " echo '== реклама'; pw2-ads status | head -1; echo; echo '== интернет роутера (WAN)'; pw2-wan status | head -4; echo;"
               " echo '== порты LAN'; pw2-lan status | head -8; echo; echo '== узлы и службы'; pw2-setup status | tail -6")

        def work():
            return self.r.run(cmd, timeout=60)

        def done(res):
            rc, out = res
            self._set_text(self.status_text, out if rc == 0 or out else "Нет связи с роутером (код %d)." % rc)
        self.bg(work, done)

    def check_exits(self):
        self.log("» проверка внешних адресов (до 25 с)…")
        cmd = ("for p in 1080 1081; do echo \"порт $p: $(curl -s --socks5-hostname 127.0.0.1:$p -m 20 https://ifconfig.me/ip || echo "
               "'нет ответа')\"; done")
        self.run_cmd(cmd, timeout=60)

    # --- Серверы
    def _tab_servers(self):
        f = ttk.Frame(self.nb, padding=8)
        self.nb.add(f, text="Серверы")
        ttk.Label(f, text="Закреплённый сервер не меняется сам (нет проверок и переключений). «Авто» возвращает выбор роутера.",
                  foreground="#555").pack(anchor="w")
        pan = ttk.Frame(f)
        pan.pack(fill="both", expand=True, pady=4)
        self.trees = {}
        for kind, title in (("pool", "Выход для 1080 / 8080 и системного трафика"), ("chain", "Первый хоп для рабочего выхода 1081 / 8081")):
            lf = ttk.LabelFrame(pan, text=title)
            lf.pack(side="left", fill="both", expand=True, padx=4)
            cols = ("n", "name", "addr", "ms", "pin")
            tv = ttk.Treeview(lf, columns=cols, show="headings", height=14, selectmode="browse")
            for c, t, w in (("n", "№", 30), ("name", "Сервер", 200), ("addr", "Адрес", 150), ("ms", "мс", 60), ("pin", "", 30)):
                tv.heading(c, text=t)
                tv.column(c, width=w, anchor="w")
            tv.tag_configure("pinned", background="#d9ecff")
            tv.tag_configure("dead", foreground="#999")
            tv.pack(fill="both", expand=True)
            self.trees[kind] = tv
            bar = ttk.Frame(lf)
            bar.pack(fill="x", pady=3)
            ttk.Button(bar, text="Закрепить выбранный", command=lambda k=kind: self.pin_selected(k)).pack(side="left")
            ttk.Button(bar, text="Следующий", command=lambda k=kind: self.exit_cmd("next", k)).pack(side="left", padx=3)
            ttk.Button(bar, text="Самый быстрый", command=lambda k=kind: self.exit_cmd("best", k)).pack(side="left")
            ttk.Button(bar, text="Авто", command=lambda k=kind: self.exit_cmd("auto", k)).pack(side="left", padx=3)
        row = ttk.Frame(f)
        row.pack(fill="x", pady=4)
        ttk.Button(row, text="Обновить список", command=self.refresh_servers).pack(side="left")
        ttk.Label(row, text="   Проверка пула Xray:").pack(side="left")
        self.vars["probe"] = tk.StringVar(value="2m")
        ttk.Combobox(row, textvariable=self.vars["probe"], width=5, values=("30s", "1m", "2m", "3m", "5m", "10m")).pack(side="left", padx=3)
        ttk.Label(row, text="Проверка порта 1081, с:").pack(side="left", padx=(8, 0))
        self.vars["check"] = tk.StringVar(value="10")
        ttk.Combobox(row, textvariable=self.vars["check"], width=4, values=("5", "10", "15", "20", "30", "60")).pack(side="left", padx=3)
        ttk.Button(row, text="Применить", command=self.apply_intervals).pack(side="left", padx=6)
        ttk.Label(f, text="Реже проверки - меньше нагрузка на виртуальную машину (действует в автоматическом режиме).",
                  foreground="#555").pack(anchor="w")
        self.servers_info = tk.StringVar(value="")
        ttk.Label(f, textvariable=self.servers_info).pack(anchor="w", pady=2)

    def refresh_servers(self):
        self.log("» список серверов с замером времени соединения (3-5 с)…")

        def work():
            self.set_status("Замер…")
            a = self.r.run("pw2-exit nodes", timeout=90)
            b = self.r.run("pw2-exit status", timeout=30)
            return a, b

        def done(res):
            (rc, out), (rc2, st) = res
            self.status_var.set("Готово")
            for tv in self.trees.values():
                tv.delete(*tv.get_children())
            if rc != 0:
                self.log(out or "Нет связи с роутером.")
                return
            for line in out.splitlines():
                p = line.split("|")
                if len(p) < 8 or p[0] not in self.trees:
                    continue
                kind, n, nid, name, addr, port, ms, pin = p[:8]
                alive = ms.strip() not in ("", "-1")
                tags = []
                if pin == "1":
                    tags.append("pinned")
                if not alive:
                    tags.append("dead")
                self.trees[kind].insert("", "end", iid=nid, values=(n, name, "%s:%s" % (addr, port), ms if alive else "—", "●" if pin == "1" else ""), tags=tags)
            self.servers_info.set(st.replace("\n", "   |   "))
            m1 = re.search(r"пул Xray - каждые (\d+[smh])", st)
            m2 = re.search(r"автопереключение 1081 - каждые (\d+)", st)
            if m1:
                self.vars["probe"].set(m1.group(1))
            if m2:
                self.vars["check"].set(m2.group(1))
        self.bg(work, done)

    def pin_selected(self, kind):
        sel = self.trees[kind].selection()
        if not sel:
            messagebox.showinfo(APP, "Выберите сервер в списке.")
            return
        self.exit_cmd("set", kind, sel[0])

    def exit_cmd(self, action, kind, arg=""):
        cmd = "pw2-exit %s %s %s" % (action, kind, arg)
        self.run_cmd(cmd.strip(), title="Применяю (перезапуск PassWall2, ~10 с)…", after=self.refresh_servers, timeout=120)

    def apply_intervals(self):
        probe, check = self.vars["probe"].get().strip(), self.vars["check"].get().strip()
        if not re.match(r"^\d+[smh]$", probe) or not check.isdigit():
            messagebox.showerror(APP, "Проверка пула: число и s/m/h (например 2m); порт 1081: секунды числом.")
            return
        self.run_cmd("pw2-exit probe %s; pw2-exit check %s" % (probe, check), title="Меняю частоту проверок…", after=self.refresh_servers, timeout=180)

    # --- Маршруты
    def _tab_routes(self):
        f = ttk.Frame(self.nb, padding=8)
        self.nb.add(f, text="Маршруты")
        self.vars["ru"] = tk.StringVar(value="")
        self.vars["ali"] = tk.StringVar(value="")
        self.vars["ads"] = tk.StringVar(value="")
        self.vars["cn"] = tk.StringVar(value="")

        def group(title, var, items, command, note=""):
            lf = ttk.LabelFrame(f, text=title, padding=6)
            lf.pack(fill="x", pady=4)
            for text, val in items:
                ttk.Radiobutton(lf, text=text, value=val, variable=self.vars[var], command=lambda v=val: command(v)).pack(side="left", padx=8)
            if note:
                ttk.Label(lf, text=note, foreground="#555").pack(side="left", padx=8)
        group("Российские ресурсы (сайты .ru/.su/.рф и IP России)", "ru",
              (("Напрямую", "direct"), ("Всё через пул", "proxy"), ("Через цепочку пул → российский сервер", "chain")),
              lambda v: self.run_cmd("pw2-ru-mode " + v, title="Российские ресурсы: " + v, after=self.refresh_routes, timeout=180),
              "«Через пул» и «цепочка» нужны, если оператор режет российские адреса (белые списки)")
        group("AliExpress / Alibaba", "ali", (("Напрямую", "direct"), ("Через пул", "pool")),
              lambda v: self.run_cmd("pw2-ali-mode " + v, title="AliExpress: " + v, after=self.refresh_routes, timeout=180))
        group("Китай", "cn", (("Авто", "auto"), ("Напрямую", "direct"), ("Через пул", "proxy")),
              lambda v: self.run_cmd("pw2-cn-mode " + v, title="Китай: " + v, after=self.refresh_routes, timeout=180))
        lf = ttk.LabelFrame(f, text="Блокировка рекламы и трекеров", padding=6)
        lf.pack(fill="x", pady=4)
        ttk.Radiobutton(lf, text="Включена", value="on", variable=self.vars["ads"],
                        command=lambda: self.run_cmd("pw2-ads on", title="Реклама: включить", after=self.refresh_routes, timeout=180)).pack(side="left", padx=8)
        ttk.Radiobutton(lf, text="Выключена", value="off", variable=self.vars["ads"],
                        command=lambda: self.run_cmd("pw2-ads off", title="Реклама: выключить", after=self.refresh_routes, timeout=180)).pack(side="left", padx=8)
        ttk.Button(lf, text="Обновить базы из интернета", command=lambda: self.stream_cmd("pw2-ads update", "Обновление баз рекламы…", after=self.refresh_routes)).pack(side="left", padx=8)
        ttk.Button(lf, text="Разблокировать домен…", command=self.ads_allow).pack(side="left")
        ttk.Label(f, text="Каждое изменение перезапускает PassWall2 (~10-60 с): текущие соединения на миг оборвутся.", foreground="#555").pack(anchor="w", pady=6)

    def ads_allow(self):
        d = simpledialog.askstring(APP, "Домен, который нужно разблокировать (например example.com):")
        if d and re.match(r"^[A-Za-z0-9._-]+$", d.strip()):
            self.run_cmd("pw2-ads allow " + d.strip(), title="Разблокирую " + d.strip(), timeout=180)

    def refresh_routes(self):
        cmd = ("echo RU=$(pw2-ru-mode status | head -1); echo ALI=$(pw2-ali-mode status | head -1);"
               " echo ADS=$(pw2-ads status | head -1); echo CN=$(pw2-cn-mode status 2>/dev/null | grep '^CN_MODE' | head -1)")

        def work():
            return self.r.run(cmd, timeout=40)

        def done(res):
            rc, out = res
            d = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
            ru = d.get("RU", "")
            self.vars["ru"].set("chain" if "цепоч" in ru else "proxy" if "через пул" in ru else "direct" if "напрямую" in ru else "")
            ali = d.get("ALI", "")
            self.vars["ali"].set("pool" if "через пул" in ali else "direct" if "напрямую" in ali else "")
            self.vars["ads"].set("on" if "ВКЛ" in d.get("ADS", "") else "off" if "ВЫКЛ" in d.get("ADS", "") else "")
            m = re.search(r"CN_MODE:\s*(\w+)", d.get("CN", "")) or re.search(r"CN_MODE=(\w+)", d.get("CN", ""))
            self.vars["cn"].set(m.group(1) if m else "")
        self.bg(work, done)

    # --- Устройства
    def _tab_devices(self):
        f = ttk.Frame(self.nb, padding=8)
        self.nb.add(f, text="Устройства и сеть")
        lf = ttk.LabelFrame(f, text="Свой выход для отдельных устройств (pw2-device)", padding=6)
        lf.pack(fill="both", expand=True)
        self.dev_state = tk.StringVar(value="")
        ttk.Label(lf, textvariable=self.dev_state).pack(anchor="w")
        cols = ("name", "src", "mode", "on")
        self.dev_tree = ttk.Treeview(lf, columns=cols, show="headings", height=6, selectmode="browse")
        for c, t, w in (("name", "Имя", 140), ("src", "Источник", 260), ("mode", "Выход", 160), ("on", "Вкл", 50)):
            self.dev_tree.heading(c, text=t)
            self.dev_tree.column(c, width=w)
        self.dev_tree.pack(fill="x", pady=4)
        bar = ttk.Frame(lf)
        bar.pack(fill="x")
        ttk.Button(bar, text="Добавить…", command=self.dev_add).pack(side="left")
        ttk.Button(bar, text="Удалить", command=self.dev_del).pack(side="left", padx=4)
        ttk.Button(bar, text="Включить выбор по устройствам", command=lambda: self.run_cmd("pw2-device on", after=self.refresh_devices, timeout=180)).pack(side="left")
        ttk.Button(bar, text="Выключить", command=lambda: self.run_cmd("pw2-device off", after=self.refresh_devices, timeout=180)).pack(side="left", padx=4)
        ttk.Label(lf, text="Источник: IP, диапазон, подсеть, MAC или if:порт. Выход: pool - пул, work - рабочий сервер, direct - мимо прокси.", foreground="#555").pack(anchor="w", pady=3)

        nf = ttk.LabelFrame(f, text="Интернет роутера (WAN) и порты (LAN)", padding=6)
        nf.pack(fill="both", expand=True, pady=6)
        self.net_text = self._mono(nf, 8)
        self.net_text.pack(fill="both", expand=True)
        bar = ttk.Frame(nf)
        bar.pack(fill="x", pady=3)
        ttk.Button(bar, text="WAN: телефон по USB", command=lambda: self.run_cmd("pw2-wan usb", after=self.refresh_devices, timeout=60)).pack(side="left")
        ttk.Button(bar, text="WAN: сетевая карта", command=lambda: self.run_cmd("pw2-wan eth", after=self.refresh_devices, timeout=60)).pack(side="left", padx=4)
        ttk.Button(bar, text="Подключить порт…", command=self.lan_add).pack(side="left")
        ttk.Button(bar, text="Отключить порт…", command=self.lan_del).pack(side="left", padx=4)
        ttk.Button(bar, text="Обновить", command=self.refresh_devices).pack(side="left")

    def refresh_devices(self):
        def work():
            return self.r.run("pw2-device rules", timeout=30), self.r.run("pw2-wan status; echo; pw2-lan status", timeout=40)

        def done(res):
            (rc, out), (rc2, net) = res
            self.dev_tree.delete(*self.dev_tree.get_children())
            en = False
            for line in out.splitlines():
                if line.startswith("ENABLED="):
                    en = line.endswith("1")
                    continue
                p = line.split("|")
                if len(p) >= 5:
                    src = p[1] + ((" (интерфейс %s)" % p[2]) if p[2] else "")
                    mode = {"pool": "через пул", "work": "рабочий сервер", "direct": "напрямую"}.get(p[3], p[3])
                    self.dev_tree.insert("", "end", iid=p[0], values=(p[0], src, mode, "да" if p[4] == "1" else "нет"))
            self.dev_state.set("Выбор по устройствам: " + ("ВКЛ" if en else "ВЫКЛ") + "   (устройства без правила идут через пул)")
            self._set_text(self.net_text, net)
        self.bg(work, done)

    def dev_add(self):
        d = tk.Toplevel(self.root)
        d.title("Новое правило")
        d.transient(self.root)
        vals = {k: tk.StringVar() for k in ("name", "src")}
        mode = tk.StringVar(value="pool")
        for i, (k, t) in enumerate((("name", "Имя (например tv):"), ("src", "Источник (IP / диапазон / подсеть / MAC / if:порт):"))):
            ttk.Label(d, text=t).grid(row=i, column=0, sticky="w", padx=8, pady=4)
            ttk.Entry(d, textvariable=vals[k], width=30).grid(row=i, column=1, padx=8)
        fr = ttk.Frame(d)
        fr.grid(row=2, column=0, columnspan=2, pady=4)
        for t, v in (("Через пул", "pool"), ("Рабочий сервер", "work"), ("Напрямую", "direct")):
            ttk.Radiobutton(fr, text=t, value=v, variable=mode).pack(side="left", padx=6)

        def ok():
            n, s = vals["name"].get().strip(), vals["src"].get().strip()
            if not n or not s or not re.match(r"^[\w.-]+$", n) or re.search(r"[;&|$`'\"\\\s]", s):
                messagebox.showerror(APP, "Заполните имя (буквы, цифры, - _ .) и источник без пробелов и спецсимволов.", parent=d)
                return
            d.destroy()
            self.run_cmd("pw2-device set %s %s %s" % (n, s, mode.get()), title="Добавляю правило…", after=self.refresh_devices, timeout=180)
        ttk.Button(d, text="Добавить", command=ok).grid(row=3, column=0, columnspan=2, pady=8)

    def dev_del(self):
        sel = self.dev_tree.selection()
        if sel and messagebox.askyesno(APP, "Удалить правило «%s»?" % sel[0]):
            self.run_cmd("pw2-device del " + sel[0], after=self.refresh_devices, timeout=180)

    def lan_add(self):
        port = simpledialog.askstring(APP, "Сетевой порт роутера (например eth2):")
        if not port or not re.match(r"^[\w.-]+$", port.strip()):
            return
        addr = simpledialog.askstring(APP, "Адрес роутера в сети порта.\nПусто - сеть 10.99.88.0/24 с автоматической выдачей адресов (DHCP).\nИли, например, 192.168.100.1/24 для устройств со статическими адресами:") or ""
        if addr and not re.match(r"^[0-9./]+$", addr.strip()):
            messagebox.showerror(APP, "Адрес в формате 192.168.100.1/24.")
            return
        self.run_cmd("pw2-lan add %s %s" % (port.strip(), addr.strip()), after=self.refresh_devices, timeout=60)

    def lan_del(self):
        port = simpledialog.askstring(APP, "Какой порт отключить (например eth2):")
        if port and re.match(r"^[\w.-]+$", port.strip()):
            self.run_cmd("pw2-lan del " + port.strip(), after=self.refresh_devices, timeout=60)

    # --- Настройка
    def _tab_setup(self):
        f = ttk.Frame(self.nb, padding=8)
        self.nb.add(f, text="Настройка и обновление")
        lf = ttk.LabelFrame(f, text="Подписка и ваш сервер", padding=6)
        lf.pack(fill="x")
        self.vars["sub"], self.vars["work"], self.vars["extra"] = tk.StringVar(), tk.StringVar(), tk.StringVar()
        for i, (k, t) in enumerate((("sub", "Адрес подписки (https://…):"), ("work", "Ссылка vless:// рабочего сервера:"), ("extra", "Ещё одна ссылка vless:// (необязательно):"))):
            ttk.Label(lf, text=t).grid(row=i, column=0, sticky="w", pady=3)
            ttk.Entry(lf, textvariable=self.vars[k], width=70, show="*" if k == "sub" else "").grid(row=i, column=1, padx=6)
        ttk.Label(lf, text="Пустое поле оставляет прежнее значение. Данные уходят только на ваш роутер и в журнале не показываются.", foreground="#555").grid(row=3, column=0, columnspan=2, sticky="w")
        bar = ttk.Frame(lf)
        bar.grid(row=4, column=0, columnspan=2, sticky="w", pady=4)
        ttk.Button(bar, text="Применить (pw2-setup)", command=lambda: self.do_setup(False)).pack(side="left")
        ttk.Button(bar, text="С чистого листа (pw2-setup reset)", command=lambda: self.do_setup(True)).pack(side="left", padx=6)
        ttk.Button(bar, text="Загрузить файл secrets.env…", command=self.upload_secrets).pack(side="left")

        uf = ttk.LabelFrame(f, text="Скрипты на роутере", padding=6)
        uf.pack(fill="x", pady=8)
        self.vars["dir"] = tk.StringVar(value=self.cfg.get("tools_dir") or find_dir("router", "openwrt"))
        ttk.Label(uf, text="Папка со скриптами роутера (tools/router):").grid(row=0, column=0, sticky="w")
        ttk.Entry(uf, textvariable=self.vars["dir"], width=60).grid(row=0, column=1, padx=6)
        ttk.Button(uf, text="Выбрать…", command=self.pick_dir).grid(row=0, column=2)
        bar = ttk.Frame(uf)
        bar.grid(row=1, column=0, columnspan=3, sticky="w", pady=6)
        ttk.Button(bar, text="Загрузить скрипты на роутер", command=self.do_upload).pack(side="left")
        ttk.Button(bar, text="Обновить скрипты на роутере (pw2-update)", command=lambda: self.stream_cmd("sh /usr/share/pw2/pw2-update", "pw2-update…", after=self.refresh_status)).pack(side="left", padx=6)
        ttk.Button(bar, text="Что будет обновлено", command=lambda: self.run_cmd("pw2-update status", timeout=40)).pack(side="left")
        ttk.Button(bar, text="Обновить подписку и пул", command=lambda: self.stream_cmd("pw2-pool-sync; tail -6 /root/pw2-pool-sync.log", "Обновление подписки…", after=self.refresh_servers)).pack(side="left", padx=6)

    def pick_dir(self):
        d = filedialog.askdirectory(title="Папка tools/router со скриптами роутера", initialdir=self.vars["dir"].get() or None)
        if d:
            self.vars["dir"].set(d)
            self.cfg["tools_dir"] = d
            save_cfg(self.cfg)

    def do_upload(self):
        d = self.vars["dir"].get().strip()
        if not d:
            self.pick_dir()
            d = self.vars["dir"].get().strip()
        if not d:
            return
        self.log("» загрузка скриптов из " + d)

        def work():
            self.set_status("Загрузка…")
            return self.r.upload(d, self.qlog)

        def done(_ok):
            self.status_var.set("Готово")
        self.bg(work, done)

    def do_setup(self, reset):
        vals = [self.vars[k].get().strip() for k in ("sub", "work", "extra")]
        if any("'" in v or "\n" in v for v in vals):
            messagebox.showerror(APP, "В значениях не должно быть одинарной кавычки или переносов строк.")
            return
        if reset and not messagebox.askyesno(APP, "Будут удалены ВСЕ узлы и подписки на роутере (копия настроек сохранится в /root) и созданы заново. Продолжить?"):
            return

        def work():
            rc, out = self.r.run("test -f /etc/pw2-passwd.done && echo yes || echo no", timeout=20)
            return out.strip()

        def done(flag):
            if flag != "yes":
                messagebox.showinfo(APP, "На роутере ещё не задан пароль root. Выполните один раз в терминале:\n\n    ssh -t %s pw2-setup\n\nи вернитесь сюда." % self.r.host)
                return
            data = ("\n".join(vals) + "\n").encode("utf-8")
            self.stream_cmd("pw2-setup reset" if reset else "pw2-setup", "Настройка роутера (1-3 минуты)…", after=self.refresh_status, data=data)
        self.bg(work, done)

    def upload_secrets(self):
        p = filedialog.askopenfilename(title="Файл secrets.env", filetypes=[("secrets.env", "*.env"), ("Все файлы", "*.*")])
        if not p:
            return
        with open(p, "rb") as f:
            data = f.read().replace(b"\r\n", b"\n")
        self.run_cmd("cat > /root/secrets.env; chmod 600 /root/secrets.env; echo файл загружен", data=data, title="Загружаю secrets.env")
        if messagebox.askyesno(APP, "Применить настройки сейчас (pw2-setup apply)?"):
            self.stream_cmd("pw2-setup apply", "pw2-setup apply (1-3 минуты)…", after=self.refresh_status)

    # --- Windows
    def _tab_windows(self):
        f = ttk.Frame(self.nb, padding=8)
        self.nb.add(f, text="Windows")
        ttk.Label(f, text="Шлюз Windows направляет весь трафик этого компьютера через роутер. Команды запускаются от администратора (появится запрос UAC).", wraplength=860).pack(anchor="w")
        self.vars["wdir"] = tk.StringVar(value=find_dir("windows", "win-gateway"))
        row = ttk.Frame(f)
        row.pack(fill="x", pady=6)
        ttk.Label(row, text="Папка tools/windows:").pack(side="left")
        ttk.Entry(row, textvariable=self.vars["wdir"], width=60).pack(side="left", padx=6)
        ttk.Button(row, text="Выбрать…", command=lambda: self.vars["wdir"].set(filedialog.askdirectory() or self.vars["wdir"].get())).pack(side="left")
        for text, script, args in (("Включить шлюз", "gateway-on.ps1", ""), ("Выключить шлюз", "gateway-off.ps1", ""),
                                   ("Установить сторожа (автозапуск роутера)", "install-watchdog-task.ps1", ""),
                                   ("Подключить проводной порт к роутеру (lan-port)", "lan-port.ps1", "")):
            ttk.Button(f, text=text, command=lambda s=script, a=args: self.win_script(s, a)).pack(anchor="w", pady=3)
        ttk.Button(f, text="Показать состояние шлюза", command=self.win_gateway_state).pack(anchor="w", pady=3)

    def win_script(self, script, args):
        p = os.path.join(self.vars["wdir"].get(), script)
        if not os.path.isfile(p):
            messagebox.showerror(APP, "Не найден %s. Укажите папку tools/windows." % p)
            return
        ps = "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%s\" %s'" % (p, args)
        subprocess.Popen(["powershell", "-NoProfile", "-Command", ps], creationflags=NO_WINDOW)
        self.log("» %s запущен в отдельном окне (подтвердите запрос администратора)." % script)

    def win_gateway_state(self):
        try:
            out = subprocess.run(["route", "print", "10.99.77.1"], capture_output=True, creationflags=NO_WINDOW).stdout.decode("cp866", "replace")
        except Exception as e:  # noqa: BLE001
            out = str(e)
        on = "10.99.77.1" in out and "128.0.0.0" in out
        self.log("Шлюз Windows: " + ("ВКЛЮЧЁН (маршруты через 10.99.77.1 есть)" if on else "выключен (маршрутов через 10.99.77.1 нет)"))

    # ---------- подключение ----------
    def connect(self):
        h = self.host_var.get().strip()
        if not h or re.search(r"[\s;&|$`'\"\\]", h):
            messagebox.showerror(APP, "Укажите имя из ~/.ssh/config или root@адрес без пробелов.")
            return
        self.cfg["host"] = h
        save_cfg(self.cfg)
        self.r = Router(h)
        self.log("» подключаюсь к %s…" % h)
        self.refresh_all()

    def refresh_all(self):
        self.refresh_status()
        self.refresh_routes()

    def _tab_changed(self, _e=None):
        t = self.nb.tab(self.nb.select(), "text")
        if t == "Серверы" and not self.trees["pool"].get_children():
            self.refresh_servers()
        elif t == "Устройства и сеть":
            self.refresh_devices()
        elif t == "Маршруты":
            self.refresh_routes()

    def setup_key(self):
        host = self.host_var.get().strip()
        ps = os.path.join(find_dir("windows", "win-gateway") or "", "router-ssh-setup.ps1")
        if IS_WIN and os.path.isfile(ps):
            subprocess.Popen(["powershell", "-NoProfile", "-Command",
                              "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%s\"'" % ps])
            self.log("» открыто окно настройки входа по ключу (спросит пароль root роутера один раз).")
            return
        cmd = ('[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519; '
               'cat ~/.ssh/id_ed25519.pub | ssh %s "cat >> /etc/dropbear/authorized_keys"' % (host if "@" in host else "root@" + host))
        messagebox.showinfo(APP, "Выполните в терминале (пароль root роутера спросят один раз):\n\n" + cmd)

    def _bootstrap(self):
        self.refresh_all()

    def run(self):
        self.root.after(300, self._bootstrap)
        self.root.mainloop()

    # ---------- самопроверка без окна ----------
    def self_test(self):
        results = []

        def step(name, fn):
            try:
                results.append((name, True, fn()))
            except Exception as e:  # noqa: BLE001
                results.append((name, False, repr(e)))
        step("ssh: связь", lambda: self.r.run("echo ok", timeout=20))
        step("состояние", lambda: self.r.run("pw2-exit status", timeout=30)[1].splitlines()[0])
        step("серверы (nodes)", lambda: len(self.r.run("pw2-exit nodes", timeout=90)[1].splitlines()))
        step("устройства (rules)", lambda: self.r.run("pw2-device rules", timeout=30)[1].splitlines()[0])
        step("маршруты", lambda: self.r.run("pw2-ru-mode status | head -1", timeout=30)[1])
        return results


def main():
    if "--self-test" in sys.argv:
        app = App(test=True)
        rows = app.self_test()
        bad = 0
        for name, ok, info in rows:
            print(("OK   " if ok else "FAIL ") + name + ": " + str(info))
            bad += 0 if ok else 1
        app.root.destroy()
        sys.exit(1 if bad else 0)
    App().run()


if __name__ == "__main__":
    main()
