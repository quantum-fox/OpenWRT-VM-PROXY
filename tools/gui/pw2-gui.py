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
import datetime
import json
import os
import queue
import re
import subprocess
import sys
import threading
import webbrowser
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

APP = "pw2 — управление роутером"
IS_WIN = sys.platform.startswith("win")
NO_WINDOW = 0x08000000 if IS_WIN else 0
# Справка: страница docs/gui.md (описание окна); пока репозиторий на GitHub; адрес можно переопределить в config.json (ключ "help_url"), позже здесь будет собственный git.
HELP_URL = "https://github.com/quantum-fox/OpenWRT-VM-PROXY/blob/main/docs/gui.md"
# Диагностика: команда pw2-diag есть в /usr/bin только после установки/обновления скриптов; если нет, запускаем копию из /usr/share/pw2.
DIAG_CMD = ("if command -v pw2-diag >/dev/null 2>&1; then pw2-diag; elif [ -f /usr/share/pw2/pw2-diag ]; then sh /usr/share/pw2/pw2-diag; "
            "else echo 'На роутере нет pw2-diag: скрипты старой версии. Вкладка «Настройка и обновление»: «Загрузить скрипты на роутер», затем «Обновить скрипты на роутере».'; fi")


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
        self.stale = self.find_stale(names, os.listdir(ddir) if os.path.isdir(ddir) else [])
        return True

    def find_stale(self, names, data_names):
        """Файлы проекта на роутере, которых нет в загруженной папке (остались от старых версий)."""
        keep = set(names)
        cmd = ("cd /usr/share/pw2 2>/dev/null || exit 0; for f in *; do [ -f \"$f\" ] && echo \"/usr/share/pw2/$f\"; done; "
               "for f in data/*; do [ -f \"$f\" ] && echo \"/usr/share/pw2/$f\"; done; "
               "for f in /usr/bin/pw2-*; do [ -f \"$f\" ] && echo \"$f\"; done")
        rc, out = self.run(cmd)
        stale = []
        for line in out.splitlines():
            line = line.strip()
            base = line.rsplit("/", 1)[-1]
            if line.startswith("/usr/share/pw2/data/"):
                if base not in data_names:
                    stale.append(line)
            elif line.startswith("/usr/share/pw2/"):
                if base not in keep:
                    stale.append(line)
            elif base not in keep and base not in ("pw2-routing-apply",):
                stale.append(line)
        return stale


class App:
    def __init__(self, test=False):
        self.cfg = load_cfg()
        self.r = Router(self.cfg["host"])
        self.q = queue.Queue()
        self.busy = False
        self.test = test
        self.root = tk.Tk()
        self.root.title(APP)
        self.root.geometry("1000x780")
        self.root.minsize(820, 560)
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
        ttk.Button(top, text="Справка ↗", command=self.open_help).pack(side="right")
        self.status_var = tk.StringVar(value="")
        ttk.Label(top, textvariable=self.status_var, foreground="#555").pack(side="right", padx=8)

        lf = ttk.LabelFrame(self.root, text="Журнал")
        lf.pack(side="bottom", fill="x", padx=6, pady=6)
        self.nb = ttk.Notebook(self.root)
        self.nb.pack(side="top", fill="both", expand=True, padx=6)
        self._tab_status()
        self._tab_servers()
        self._tab_routes()
        self._tab_devices()
        self._tab_setup()
        if IS_WIN:
            self._tab_windows()

        self.logbox = tk.Text(lf, height=7, wrap="word", state="disabled", font=("Consolas" if IS_WIN else "monospace", 9))
        sb = ttk.Scrollbar(lf, command=self.logbox.yview)
        self.logbox.configure(yscrollcommand=sb.set)
        self.logbox.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.nb.bind("<<NotebookTabChanged>>", self._tab_changed)

    def open_help(self):
        url = self.cfg.get("help_url") or HELP_URL
        try:
            webbrowser.open(url)
            self.log("» справка открыта в браузере: " + url)
        except Exception:  # noqa: BLE001
            messagebox.showinfo(APP, "Справка: " + url)

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
        ttk.Button(bar, text="Диагностика «нет интернета»", command=lambda: self.stream_cmd(DIAG_CMD, "Диагностика роутера…")).pack(side="left")
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
        f = self._scroll_tab("Серверы")
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
        wf = ttk.LabelFrame(f, text="Рабочий выход 1081 / 8081 (pw2-usa-mode)", padding=6)
        wf.pack(fill="x", pady=4)
        self.usa_var = tk.StringVar(value="Нажмите «Показать состояние»")
        ttk.Label(wf, textvariable=self.usa_var, justify="left").pack(anchor="w")
        bar = ttk.Frame(wf)
        bar.pack(fill="x", pady=3)
        ttk.Button(bar, text="Показать состояние", command=self.usa_show).pack(side="left")
        ttk.Button(bar, text="Основной (авто, при отказе - запасной)", command=lambda: self.usa_cmd("auto")).pack(side="left", padx=6)
        ttk.Button(bar, text="Закрепить запасной", command=lambda: self.usa_cmd("backup")).pack(side="left")
        bar = ttk.Frame(wf)
        bar.pack(fill="x", pady=3)
        ttk.Button(bar, text="Основной USA через первый хоп", command=lambda: self.usa_cmd("hop on")).pack(side="left")
        ttk.Button(bar, text="Основной USA напрямую (без хопа)", command=lambda: self.usa_cmd("hop off")).pack(side="left", padx=6)
        ttk.Label(wf, text="Хоп = промежуточный сервер из пула перед рабочим сервером (цепочка пул → USA). «Напрямую» - роутер подключается к рабочему серверу сам. Смена перезапускает PassWall2 (~10 с). "
                  "Нужна версия скриптов 1.11.3 или новее.", wraplength=900, foreground="#555").pack(anchor="w")

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

    def usa_show(self):
        def work():
            return self.r.run("pw2-usa-mode status", timeout=60)

        def done(res):
            self.usa_var.set((res[1] or "нет ответа (проверьте связь и версию скриптов)").strip())
        self.bg(work, done)

    def usa_cmd(self, arg):
        if arg == "backup" and not messagebox.askyesno(APP, "Закрепить запасной USA? Автопереключение будет отключено, пока не нажмёте «Основной (авто…)»."):
            return
        self.run_cmd("pw2-usa-mode " + arg, title="Применяю (перезапуск PassWall2, ~10 с)…", timeout=120, after=self.usa_show)

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
        f = self._scroll_tab("Маршруты")
        self.vars["ru"] = tk.StringVar(value="")
        self.vars["ali"] = tk.StringVar(value="")
        self.vars["ads"] = tk.StringVar(value="")
        self.vars["cn"] = tk.StringVar(value="")
        self.vars["fo"] = tk.StringVar(value="")

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
        group("Если ни один сервер пула не отвечает", "fo", (("Идти напрямую (интернет не пропадает)", "on"), ("Стоп (строгий режим)", "off")),
              lambda v: self.run_cmd("pw2-failopen " + v, title="Пул недоступен: " + ("напрямую" if v == "on" else "стоп"), after=self.refresh_routes, timeout=180),
              "Российские, китайские сайты и AliExpress идут по своим правилам в любом случае")
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
               " echo ADS=$(pw2-ads status | head -1); echo CN=$(pw2-cn-mode status 2>/dev/null | grep '^CN_MODE' | head -1);"
               " echo FO=$(pw2-failopen status 2>/dev/null | head -1)")

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
            fo = d.get("FO", "")
            self.vars["fo"].set("on" if "НАПРЯМУЮ" in fo else "off" if "СТОП" in fo else "")
        self.bg(work, done)

    # --- Устройства
    def _tab_devices(self):
        f = self._scroll_tab("Устройства и сеть")
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

        af = ttk.LabelFrame(f, text="Адрес роутера в локальной сети (LAN)", padding=6)
        af.pack(fill="x", pady=6)
        self.lanip_var = tk.StringVar(value="")
        ttk.Label(af, textvariable=self.lanip_var).pack(anchor="w")
        bar = ttk.Frame(af)
        bar.pack(fill="x", pady=3)
        self.vars["newip"] = tk.StringVar(value="10.99.77.1")
        ttk.Button(bar, text="Показать адрес", command=self.lanip_show).pack(side="left")
        ttk.Label(bar, text="  Новый адрес:").pack(side="left")
        ttk.Entry(bar, textvariable=self.vars["newip"], width=16).pack(side="left", padx=4)
        ttk.Button(bar, text="Сменить…", command=self.lanip_set).pack(side="left")
        ttk.Button(bar, text="Подтвердить новый адрес", command=self.lanip_keep).pack(side="left", padx=6)
        ttk.Label(af, text="После смены адрес применяется через 3 секунды, связь с роутером пропадёт. Обновите адрес на компьютере (отключите и подключите кабель/Wi-Fi), "
                  "в поле «Роутер» вверху окна уже будет новый адрес: нажмите «Подключиться», затем «Подтвердить новый адрес» в течение 3 минут, иначе роутер вернёт прежний.",
                  wraplength=900, foreground="#555").pack(anchor="w")


    # --- адрес роутера (pw2-lan-ip)
    def lanip_show(self):
        def work():
            return self.r.run("pw2-lan-ip status", timeout=30)

        def done(res):
            self.lanip_var.set((res[1] or "нет ответа (команда pw2-lan-ip есть с версии 1.11.2: обновите скрипты на роутере)").strip())
        self.bg(work, done)

    def lanip_set(self):
        new = self.vars["newip"].get().strip()
        if not re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", new):
            messagebox.showerror(APP, "Введите адрес вида 10.99.77.1.")
            return
        if not messagebox.askyesno(APP, "Сменить адрес роутера на %s?\n\nСвязь с роутером пропадёт. После смены обновите адрес на компьютере и нажмите "
                                   "«Подтвердить новый адрес» в течение 3 минут, иначе роутер вернёт прежний адрес.\n\n"
                                   "Для виртуального роутера на этом же компьютере (скрипты Windows ждут адрес 10.99.77.1) менять адрес не нужно." % new):
            return
        old_host = self.host_var.get().strip()
        user = old_host.split("@")[0] + "@" if "@" in old_host else "root@"
        self.run_cmd("pw2-lan-ip set %s" % new, title="Смена адреса…", timeout=30)
        self.host_var.set(user + new)
        self.log("» поле «Роутер» переключено на %s. Обновите адрес на компьютере, нажмите «Подключиться», затем «Подтвердить новый адрес»." % (user + new))

    def lanip_keep(self):
        self.connect()
        self.run_cmd("pw2-lan-ip keep", title="Подтверждение адреса…", timeout=30, after=self.lanip_show)

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
        f = self._scroll_tab("Настройка и обновление")
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
        ttk.Button(bar, text="Диагностика «нет интернета» (pw2-diag)", command=lambda: self.stream_cmd(DIAG_CMD, "Диагностика роутера…")).pack(side="left", padx=6)
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
            stale = getattr(self.r, "stale", None) or []
            if _ok and stale:
                if messagebox.askyesno(APP, "На роутере остались файлы проекта, которых нет в этой версии (остатки старых версий):\n\n%s\n\nУдалить их?" % ("\n".join(stale[:25]))):
                    self.run_cmd("rm -f " + " ".join("'%s'" % x for x in stale if re.match(r"^[\w./-]+$", x)) + "; echo удалено файлов: %d" % len(stale))
            elif _ok:
                self.log("» лишних файлов проекта на роутере нет.")
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
    def win_info(self):
        """Версия Windows и что на ней поддерживается: (метка, поддержка скриптов шлюза, пояснение)."""
        try:
            import platform
            ver = platform.win32_ver()[1] or ""
            parts = ver.split(".")
            major, minor = int(parts[0]), int(parts[1])
            build = int(parts[2]) if len(parts) > 2 else 0
        except Exception:  # noqa: BLE001
            return "Windows (версия не определена)", True, ""
        if major >= 10:
            name = "Windows 11" if build >= 22000 else "Windows 10"
            return name, True, "полная поддержка: окно, скрипты шлюза, VirtualBox 7.x"
        if (major, minor) == (6, 3):
            return "Windows 8.1", True, ("окно работает (нужны Python 3.8–3.11 и клиент ssh, например из Git for Windows); скрипты шлюза используют команды PowerShell "
                                         "из Windows 8 и должны работать, но не проверялись; VirtualBox 7 на Windows 8.1 не поддерживается (нужна 6.1)")
        if (major, minor) == (6, 2):
            return "Windows 8", True, "как Windows 8.1; не проверялось"
        if (major, minor) == (6, 1):
            return "Windows 7", False, ("окно управления роутером работает (Python 3.8, клиент ssh из Git for Windows или Win32-OpenSSH); скрипты шлюза Windows "
                                        "НЕ работают: в Windows 7 нет сетевых команд PowerShell (Get-NetAdapter и др.). Используйте физический роутер или ПК с Windows 10/11")
        return "Windows %d.%d" % (major, minor), False, "не поддерживается"

    def vbox_path(self):
        for base in (os.environ.get("VBOX_MSI_INSTALL_PATH", ""), os.environ.get("VBOX_INSTALL_PATH", ""),
                     os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Oracle", "VirtualBox")):
            p = os.path.join(base, "VBoxManage.exe") if base else ""
            if p and os.path.isfile(p):
                return p
        return ""

    def win_state(self):
        """Состояние на этом компьютере: VM, сторож, шлюз. Только чтение, права администратора не нужны."""
        lines = []
        vb = self.vbox_path()
        if not vb:
            lines.append("VirtualBox: не найден (если роутер физический, это нормально)")
            vm = None
        else:
            try:
                out = subprocess.run([vb, "list", "runningvms"], capture_output=True, creationflags=NO_WINDOW, timeout=20).stdout.decode("utf-8", "replace")
                vm = '"OpenWRT"' in out
                lines.append("VM «OpenWRT» (виртуальный роутер): " + ("ЗАПУЩЕНА" if vm else "выключена"))
            except Exception as e:  # noqa: BLE001
                vm = None
                lines.append("VM: не удалось узнать (%s)" % e)
        try:
            out = subprocess.run(["schtasks", "/Query", "/TN", "OpenWRT-Gateway-Watchdog", "/FO", "LIST"], capture_output=True,
                                 creationflags=NO_WINDOW, timeout=20)
            text = out.stdout.decode("cp866", "replace")
            if out.returncode != 0:
                lines.append("Сторож (задача OpenWRT-Gateway-Watchdog): не установлен")
            else:
                dis = re.search(r"(Отключен|Disabled)", text, re.I) is not None
                lines.append("Сторож (задача OpenWRT-Gateway-Watchdog): " + ("ОТКЛЮЧЁН (VM сама не запустится)" if dis else "включён (сам запускает VM и поддерживает шлюз)"))
        except Exception as e:  # noqa: BLE001
            lines.append("Сторож: не удалось узнать (%s)" % e)
        try:
            out = subprocess.run(["route", "print", "-4"], capture_output=True, creationflags=NO_WINDOW, timeout=20).stdout.decode("cp866", "replace")
            on = re.search(r"^\s*0\.0\.0\.0\s+128\.0\.0\.0\s+\S+", out, re.M) is not None and "10.99.77.1" in out
            lines.append("Шлюз Windows (весь трафик через роутер): " + ("ВКЛЮЧЁН" if on else "выключен"))
        except Exception as e:  # noqa: BLE001
            lines.append("Шлюз: не удалось узнать (%s)" % e)
        return lines

    def _scroll_tab(self, title):
        """Вкладка с вертикальной прокруткой: содержимое не раздувает окно и не уводит журнал за экран."""
        outer = ttk.Frame(self.nb)
        self.nb.add(outer, text=title)
        cv = tk.Canvas(outer, highlightthickness=0)
        sb = ttk.Scrollbar(outer, orient="vertical", command=cv.yview)
        inner = ttk.Frame(cv, padding=8)
        win = cv.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda e: cv.configure(scrollregion=cv.bbox("all")))
        cv.bind("<Configure>", lambda e: cv.itemconfigure(win, width=e.width))
        cv.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        cv.pack(side="left", fill="both", expand=True)

        def wheel(e):
            cv.yview_scroll(int(-1 * (e.delta / 120)) if e.delta else (1 if e.num == 5 else -1), "units")
        cv.bind("<Enter>", lambda e: (cv.bind_all("<MouseWheel>", wheel), cv.bind_all("<Button-4>", wheel), cv.bind_all("<Button-5>", wheel)))
        cv.bind("<Leave>", lambda e: (cv.unbind_all("<MouseWheel>"), cv.unbind_all("<Button-4>"), cv.unbind_all("<Button-5>")))
        return inner

    def _tab_windows(self):
        f = self._scroll_tab("Windows")
        name, ok, note = self.win_info()
        ttk.Label(f, text="Эта вкладка управляет самим компьютером с Windows. Команды запускаются от администратора (появится запрос UAC).", wraplength=900).pack(anchor="w")
        ttk.Label(f, text="Ваша система: %s. %s" % (name, note), wraplength=900, foreground="#555" if ok else "#a00").pack(anchor="w", pady=2)
        self.vars["wdir"] = tk.StringVar(value=find_dir("windows", "win-gateway"))
        row = ttk.Frame(f)
        row.pack(fill="x", pady=4)
        ttk.Label(row, text="Папка tools/windows:").pack(side="left")
        ttk.Entry(row, textvariable=self.vars["wdir"], width=60).pack(side="left", padx=6)
        ttk.Button(row, text="Выбрать…", command=lambda: self.vars["wdir"].set(filedialog.askdirectory() or self.vars["wdir"].get())).pack(side="left")

        st = ttk.LabelFrame(f, text="Что сейчас запущено на этом компьютере", padding=6)
        st.pack(fill="x", pady=4)
        self.win_state_var = tk.StringVar(value="Нажмите «Обновить»")
        ttk.Label(st, textvariable=self.win_state_var, justify="left").pack(anchor="w")
        ttk.Button(st, text="Обновить", command=self.refresh_win_state).pack(anchor="w", pady=3)

        vm = ttk.LabelFrame(f, text="Виртуальный роутер (VM) и сторож", padding=6)
        vm.pack(fill="x", pady=4)
        ttk.Label(vm, text="Если роутер нужен не сейчас (например, вы подключились к физическому роутеру), остановите VM вместе со сторожем: "
                  "иначе сторож через минуту запустит VM снова.", wraplength=900, foreground="#555").pack(anchor="w")
        bar = ttk.Frame(vm)
        bar.pack(fill="x", pady=3)
        ttk.Button(bar, text="Остановить VM и сторожа (vm-pause)", command=lambda: self.win_script("vm-pause.ps1", "", self.refresh_win_state)).pack(side="left")
        ttk.Button(bar, text="Запустить VM, сторожа и шлюз (vm-resume)", command=lambda: self.win_script("vm-resume.ps1", "", self.refresh_win_state)).pack(side="left", padx=6)
        bar = ttk.Frame(vm)
        bar.pack(fill="x", pady=3)
        ttk.Button(bar, text="Отключить только сторожа", command=lambda: self.win_admin("schtasks /Change /TN OpenWRT-Gateway-Watchdog /DISABLE", self.refresh_win_state)).pack(side="left")
        ttk.Button(bar, text="Включить сторожа", command=lambda: self.win_admin("schtasks /Change /TN OpenWRT-Gateway-Watchdog /ENABLE", self.refresh_win_state)).pack(side="left", padx=6)
        ttk.Button(bar, text="Выключить VM (мягко)", command=self.vm_poweroff).pack(side="left")
        ttk.Button(bar, text="Запустить VM без окна", command=self.vm_start).pack(side="left", padx=6)

        self._adapters_block(f)
        gw = ttk.LabelFrame(f, text="Шлюз Windows (весь трафик компьютера через роутер) и установка", padding=6)
        gw.pack(fill="x", pady=4)
        for text, script, args in (("Включить шлюз", "gateway-on.ps1", ""), ("Выключить шлюз", "gateway-off.ps1", ""),
                                   ("Установить сторожа (автозапуск роутера)", "install-watchdog-task.ps1", ""),
                                   ("Подключить проводной порт к роутеру (lan-port)", "lan-port.ps1", "")):
            ttk.Button(gw, text=text, command=lambda s=script, a=args: self.win_script(s, a)).pack(anchor="w", pady=2)
        self.root.after(300, self.refresh_win_state)

    # --- сетевые адаптеры этого компьютера + журнал адресов
    def iplog_path(self):
        return os.path.join(os.path.dirname(cfg_path()), "ip-log.json")

    def iplog_load(self):
        try:
            with open(self.iplog_path(), encoding="utf-8") as f:
                return json.load(f)
        except Exception:  # noqa: BLE001
            return []

    def iplog_save(self, items):
        os.makedirs(os.path.dirname(self.iplog_path()), exist_ok=True)
        with open(self.iplog_path(), "w", encoding="utf-8") as f:
            json.dump(items[-50:], f, ensure_ascii=False, indent=1)

    @staticmethod
    def prefix_to_mask(p):
        p = int(p)
        bits = (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF if p else 0
        return ".".join(str((bits >> sh) & 255) for sh in (24, 16, 8, 0))

    @staticmethod
    def mask_to_prefix(m):
        return sum(bin(int(x)).count("1") for x in m.split("."))

    def ps_encoded(self, script):
        return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", base64.b64encode(script.encode("utf-16-le")).decode()]

    def _adapters_block(self, parent):
        lf = ttk.LabelFrame(parent, text="Сетевые адаптеры этого компьютера (адрес, маска, шлюз, DNS)", padding=6)
        lf.pack(fill="x", pady=4)
        self.adapters = {}
        row = ttk.Frame(lf)
        row.pack(fill="x")
        ttk.Label(row, text="Адаптер:").pack(side="left")
        self.vars["ad"] = tk.StringVar()
        self.ad_combo = ttk.Combobox(row, textvariable=self.vars["ad"], width=46, state="readonly")
        self.ad_combo.pack(side="left", padx=4)
        self.ad_combo.bind("<<ComboboxSelected>>", self.ad_select)
        ttk.Button(row, text="Обновить список", command=self.ad_refresh).pack(side="left")
        self.ad_now = tk.StringVar(value="")
        ttk.Label(lf, textvariable=self.ad_now, foreground="#555").pack(anchor="w", pady=2)
        g = ttk.Frame(lf)
        g.pack(fill="x")
        for k in ("ip", "pfx", "gw", "dns"):
            self.vars["ad_" + k] = tk.StringVar()
        self.vars["ad_dhcp"] = tk.BooleanVar(value=False)
        for i, (t, k, w) in enumerate((("IP:", "ip", 15), ("Префикс (24) или маска:", "pfx", 15), ("Шлюз:", "gw", 15), ("DNS:", "dns", 15))):
            ttk.Label(g, text=t).grid(row=0, column=2 * i, sticky="e", padx=(6, 2))
            ttk.Entry(g, textvariable=self.vars["ad_" + k], width=w).grid(row=0, column=2 * i + 1)
        ttk.Checkbutton(lf, text="Получать автоматически (DHCP)", variable=self.vars["ad_dhcp"]).pack(anchor="w", pady=2)
        bar = ttk.Frame(lf)
        bar.pack(fill="x")
        ttk.Button(bar, text="Применить (администратор)", command=self.ad_apply).pack(side="left")
        ttk.Label(bar, text="  Прежние настройки сохраняются в журнал ниже.", foreground="#555").pack(side="left")
        ttk.Label(lf, text="Журнал прежних адресов (чтобы быстро вернуть, если ввели не то):").pack(anchor="w", pady=(6, 0))
        cols = ("when", "ad", "was")
        self.iplog_tree = ttk.Treeview(lf, columns=cols, show="headings", height=4, selectmode="extended")
        for c, t, w in (("when", "Когда", 130), ("ad", "Адаптер", 220), ("was", "Было", 380)):
            self.iplog_tree.heading(c, text=t)
            self.iplog_tree.column(c, width=w)
        self.iplog_tree.pack(fill="x")
        bar = ttk.Frame(lf)
        bar.pack(fill="x", pady=3)
        ttk.Button(bar, text="Вернуть выбранное", command=self.iplog_restore).pack(side="left")
        ttk.Button(bar, text="Удалить выбранные строки", command=self.iplog_delete).pack(side="left", padx=6)
        ttk.Button(bar, text="Очистить журнал", command=self.iplog_clear).pack(side="left")
        self.iplog_fill()
        self.root.after(500, self.ad_refresh)

    def ad_refresh(self):
        script = ('Get-WmiObject Win32_NetworkAdapter -Filter "NetConnectionID IS NOT NULL" | ForEach-Object { '
                  '$c = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter ("Index=" + $_.DeviceID); '
                  '$ip = @($c.IPAddress | Where-Object { $_ -match "^\\d+\\.\\d+\\.\\d+\\.\\d+$" })[0]; '
                  '$i = [array]::IndexOf(@($c.IPAddress), $ip); $mask = if ($i -ge 0) { @($c.IPSubnet)[$i] } else { "" }; '
                  '[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
                  '($_.NetConnectionID + "|" + $_.Name + "|" + $ip + "|" + $mask + "|" + @($c.DefaultIPGateway)[0] + "|" + $c.DHCPEnabled + "|" + (@($c.DNSServerSearchOrder) -join ",")) }')

        def work():
            try:
                p = subprocess.run(self.ps_encoded(script), capture_output=True, timeout=40, creationflags=NO_WINDOW)
                return p.stdout.decode("utf-8", "replace")
            except Exception as e:  # noqa: BLE001
                return ""

        def done(out):
            self.adapters = {}
            for line in (out or "").splitlines():
                p = line.strip().split("|")
                if len(p) >= 7 and p[0]:
                    self.adapters[p[0]] = {"name": p[0], "desc": p[1], "ip": p[2], "mask": p[3], "gw": p[4], "dhcp": p[5].lower() == "true", "dns": p[6]}
            names = sorted(self.adapters)
            self.ad_combo.configure(values=names)
            if names and self.vars["ad"].get() not in self.adapters:
                self.vars["ad"].set(names[0])
            self.ad_select()
        self.bg(work, done)

    def ad_text(self, a):
        if not a:
            return ""
        return "%s; IP %s/%s; шлюз %s; DNS %s" % ("DHCP" if a["dhcp"] else "статический", a["ip"] or "-", self.mask_to_prefix(a["mask"]) if a["mask"] else "-", a["gw"] or "-", a["dns"] or "-")

    def ad_select(self, _e=None):
        a = self.adapters.get(self.vars["ad"].get())
        if not a:
            self.ad_now.set("Адаптеры не найдены (нужен Windows; список берётся командой WMI)." if IS_WIN else "Только для Windows.")
            return
        self.ad_now.set("Сейчас: " + self.ad_text(a) + "   [" + a["desc"] + "]")
        self.vars["ad_ip"].set(a["ip"])
        self.vars["ad_pfx"].set(str(self.mask_to_prefix(a["mask"])) if a["mask"] else "24")
        self.vars["ad_gw"].set(a["gw"])
        self.vars["ad_dns"].set(a["dns"].split(",")[0] if a["dns"] else "")
        self.vars["ad_dhcp"].set(a["dhcp"])

    def netsh_lines(self, name, dhcp, ip, mask, gw, dns):
        n = '"%s"' % name
        if dhcp:
            return ["netsh interface ip set address name=%s source=dhcp" % n, "netsh interface ip set dns name=%s source=dhcp" % n]
        lines = ["netsh interface ip set address name=%s source=static addr=%s mask=%s%s" % (n, ip, mask, (" gateway=%s gwmetric=1" % gw) if gw else "")]
        lines.append(("netsh interface ip set dns name=%s source=static addr=%s validate=no" % (n, dns.split(",")[0])) if dns else "netsh interface ip set dns name=%s source=dhcp" % n)
        return lines

    def ad_run_admin(self, lines):
        import tempfile
        fd, path = tempfile.mkstemp(suffix=".cmd", prefix="pw2-ip-")
        with os.fdopen(fd, "w", encoding="oem" if IS_WIN else "utf-8") as f:
            f.write("@echo off\r\n" + "\r\n".join(lines) + "\r\necho.\r\necho Готово. Окно закроется через 5 секунд.\r\ntimeout /t 5 >nul\r\ndel \"%~f0\"\r\n")
        ps = "Start-Process cmd -Verb RunAs -ArgumentList '/c \"%s\"'" % path
        subprocess.Popen(["powershell", "-NoProfile", "-Command", ps], creationflags=NO_WINDOW)

    def ad_apply(self):
        name = self.vars["ad"].get()
        a = self.adapters.get(name)
        if not a:
            messagebox.showerror(APP, "Выберите адаптер.")
            return
        if '"' in name or "%" in name:
            messagebox.showerror(APP, "В имени адаптера есть недопустимый символ. Переименуйте адаптер в «Сетевых подключениях».")
            return
        dhcp = self.vars["ad_dhcp"].get()
        ip, gw, dns = (self.vars[k].get().strip() for k in ("ad_ip", "ad_gw", "ad_dns"))
        pfx = self.vars["ad_pfx"].get().strip()
        ipre = r"(\d{1,3}\.){3}\d{1,3}"
        mask = ""
        if not dhcp:
            if re.fullmatch(r"\d{1,2}", pfx) and 1 <= int(pfx) <= 32:
                mask = self.prefix_to_mask(pfx)
            elif re.fullmatch(ipre, pfx):
                mask = pfx
            if not re.fullmatch(ipre, ip) or not mask or (gw and not re.fullmatch(ipre, gw)) or (dns and not re.fullmatch(ipre, dns)):
                messagebox.showerror(APP, "Проверьте поля: IP вида 192.168.1.50, префикс 24 (или маска 255.255.255.0), шлюз и DNS - адреса или пусто.")
                return
        if not messagebox.askyesno(APP, "Изменить настройки адаптера «%s»?\n\nБыло: %s\nСтанет: %s\n\nЕсли через этот адаптер вы связаны с роутером или интернетом, связь может пропасть. Прежние настройки сохранятся в журнале." % (
                name, self.ad_text(a), "DHCP" if dhcp else "IP %s/%s, шлюз %s, DNS %s" % (ip, pfx, gw or "-", dns or "-"))):
            return
        items = self.iplog_load()
        items.append({"when": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), "ad": name, "dhcp": a["dhcp"], "ip": a["ip"], "mask": a["mask"], "gw": a["gw"], "dns": a["dns"]})
        self.iplog_save(items)
        self.iplog_fill()
        self.ad_run_admin(self.netsh_lines(name, dhcp, ip, mask, gw, dns))
        self.log("» настройки адаптера «%s» меняются в отдельном окне (подтвердите запрос администратора); затем нажмите «Обновить список»." % name)

    def iplog_fill(self):
        self.iplog_tree.delete(*self.iplog_tree.get_children())
        for i, it in enumerate(self.iplog_load()):
            was = "DHCP" if it.get("dhcp") else "IP %s/%s, шлюз %s, DNS %s" % (it.get("ip") or "-", self.mask_to_prefix(it["mask"]) if it.get("mask") else "-", it.get("gw") or "-", it.get("dns") or "-")
            self.iplog_tree.insert("", "end", iid=str(i), values=(it.get("when", ""), it.get("ad", ""), was))

    def iplog_restore(self):
        sel = self.iplog_tree.selection()
        items = self.iplog_load()
        if len(sel) != 1:
            messagebox.showinfo(APP, "Выберите одну строку журнала.")
            return
        it = items[int(sel[0])]
        if not messagebox.askyesno(APP, "Вернуть настройки адаптера «%s» к записанным (%s)?" % (it["ad"], it.get("when", ""))):
            return
        cur = self.adapters.get(it["ad"])
        if cur:
            items.append({"when": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), "ad": it["ad"], "dhcp": cur["dhcp"], "ip": cur["ip"], "mask": cur["mask"], "gw": cur["gw"], "dns": cur["dns"]})
            self.iplog_save(items)
            self.iplog_fill()
        self.ad_run_admin(self.netsh_lines(it["ad"], it.get("dhcp"), it.get("ip", ""), it.get("mask", ""), it.get("gw", ""), it.get("dns", "")))
        self.log("» возвращаются прежние настройки адаптера «%s»; затем нажмите «Обновить список»." % it["ad"])

    def iplog_delete(self):
        sel = {int(x) for x in self.iplog_tree.selection()}
        if not sel:
            return
        self.iplog_save([it for i, it in enumerate(self.iplog_load()) if i not in sel])
        self.iplog_fill()

    def iplog_clear(self):
        if messagebox.askyesno(APP, "Очистить весь журнал адресов?"):
            self.iplog_save([])
            self.iplog_fill()

    def refresh_win_state(self):
        def work():
            return "\n".join(self.win_state())

        def done(res):
            self.win_state_var.set(res[1] if isinstance(res, tuple) else res)
        self.bg(work, done)

    def win_script(self, script, args, after=None):
        p = os.path.join(self.vars["wdir"].get(), script)
        if not os.path.isfile(p):
            messagebox.showerror(APP, "Не найден %s. Укажите папку tools/windows." % p)
            return
        ps = "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%s\" %s'" % (p, args)
        subprocess.Popen(["powershell", "-NoProfile", "-Command", ps], creationflags=NO_WINDOW)
        self.log("» %s запущен в отдельном окне (подтвердите запрос администратора). Когда он закончит, нажмите «Обновить»." % script)

    def win_admin(self, cmdline, after=None):
        """Выполнить одну команду cmd/PowerShell с правами администратора (отдельное окно, запрос UAC)."""
        ps = "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -Command \"%s; Start-Sleep 3\"'" % cmdline.replace("'", "''")
        subprocess.Popen(["powershell", "-NoProfile", "-Command", ps], creationflags=NO_WINDOW)
        self.log("» выполняется с правами администратора: %s. Затем нажмите «Обновить»." % cmdline)

    def vm_poweroff(self):
        vb = self.vbox_path()
        if not vb:
            messagebox.showerror(APP, "VirtualBox не найден.")
            return
        if not messagebox.askyesno(APP, "Выключить VM «OpenWRT» (как кнопкой питания)?\nСторож при этом может запустить её снова через минуту, если не отключён."):
            return
        subprocess.Popen([vb, "controlvm", "OpenWRT", "acpipowerbutton"], creationflags=NO_WINDOW)
        self.log("» отправлена команда выключения VM; через ~30 секунд нажмите «Обновить».")

    def vm_start(self):
        vb = self.vbox_path()
        if not vb:
            messagebox.showerror(APP, "VirtualBox не найден.")
            return
        subprocess.Popen([vb, "startvm", "OpenWRT", "--type", "headless"], creationflags=NO_WINDOW)
        self.log("» VM «OpenWRT» запускается без окна (~1 минута); затем нажмите «Обновить».")

    def win_gateway_state(self):
        self.refresh_win_state()

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
