#!/usr/bin/env python3
"""Local end-to-end harness for brockman relay mode: ergo with a relay oper, a feed HTTP server, a watcher client.

usage (from the repo root):
  nix build .#default -o result
  python3 test/relay-harness.py smoke            # relay, extra channels, subscribers, commands, burst, reconnect
  python3 test/relay-harness.py memory DIR       # one bot per file in DIR (real feed bodies), prints RSS over time
                                                 # DIR: e.g. feed-import/bodies in brockman-infrastructure after its run.sh
Needs nix (pulls ergochat, mkpasswd, yq-go). Everything lives in /tmp/relaytest.
"""
import atexit, datetime, email.utils, functools, http.server, json, os, pathlib, re, shutil, socket, socketserver
import subprocess, sys, threading, time

T = pathlib.Path("/tmp/relaytest")
BROCKMAN = str(pathlib.Path("result/bin/brockman").resolve())
IRC_PORT, FEED_PORT, BODY_PORT = 16667, 18555, 18556
PASSWORD = "s3cr3t-ü-pass"


def spawn(*args, **kwargs):
    """Popen that is killed when the harness exits, also on a crash (a leftover ergo keeps the port)."""
    process = subprocess.Popen(*args, **kwargs)
    atexit.register(process.kill)
    return process


def nixbin(pkg, binary):
    out = subprocess.run(["nix", "build", f"nixpkgs#{pkg}", "--no-link", "--print-out-paths"], capture_output=True, text=True, check=True)
    return f"{out.stdout.split()[-1]}/bin/{binary}"


def setup_ergo():
    ergo, mkpasswd, yq = nixbin("ergochat", "ergo"), nixbin("mkpasswd", "mkpasswd"), nixbin("yq-go", "yq")
    shutil.rmtree(T, ignore_errors=True); T.mkdir()
    (T / "oper-password").write_text(PASSWORD + "\n")
    hash_ = subprocess.run([mkpasswd, "-m", "bcrypt", "--stdin"], input=PASSWORD, capture_output=True, text=True, check=True).stdout.strip()
    (T / "default.yaml").write_text(subprocess.run([ergo, "defaultconfig"], capture_output=True, text=True, check=True).stdout)
    patch = f'''
.server.listeners = {{"127.0.0.1:{IRC_PORT}": {{}}}} | .server.name = "test.local" | .datastore.path = "{T}/ircd.db" |
.server.relaymsg.separators = "/" | .languages.enabled = false | .history.enabled = false |
.["oper-classes"].relay = {{"title": "relay", "capabilities": ["relaymsg", "nofakelag"]}} |
.opers = {{"brockman": {{"class": "relay", "hidden": true, "password": "{hash_}"}}}}'''
    (T / "ircd.yaml").write_text(subprocess.run([yq, patch, str(T / "default.yaml")], capture_output=True, text=True, check=True).stdout)
    subprocess.run([ergo, "initdb", "--conf", str(T / "ircd.yaml"), "--quiet"], cwd=T, check=True)
    return lambda: spawn([ergo, "run", "--conf", str(T / "ircd.yaml")], stdout=open(T / "ergo.log", "a"), stderr=subprocess.STDOUT, cwd=T)


def serve(directory, port):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    socketserver.ThreadingTCPServer.allow_reuse_address = True  # back-to-back runs: the port is still in TIME_WAIT
    s = socketserver.ThreadingTCPServer(("127.0.0.1", port), functools.partial(Quiet, directory=str(directory)))
    s.daemon_threads = True; s.request_queue_size = 1024
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


class Watcher:
    def __init__(self, channels="#all,#x"):
        self.lines, self.channels = [], channels
        self.sock = socket.create_connection(("127.0.0.1", IRC_PORT)); self.f = self.sock.makefile("rb")
        self.send("NICK watcher"); self.send("USER w 0 * :w")
        threading.Thread(target=self.loop, daemon=True).start()

    def send(self, line): self.sock.sendall((line + "\r\n").encode())

    def loop(self):
        for raw in self.f:
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith("PING"): self.send("PONG" + line[4:]); continue
            self.lines.append((time.time(), line))
            if " 001 " in line: self.send(f"JOIN {self.channels}")

    def grep(self, pattern, since=0): return [l for t, l in self.lines if t >= since and re.search(pattern, l)]


def brockman_config(bots, **extra):
    c = {"channel": "#all", "irc": {"host": "127.0.0.1", "port": IRC_PORT, "oper": {"name": "brockman", "passwordFile": str(T / "oper-password")}},
         "controller": {"nick": "brockman", "extraChannels": ["#x"]}, "relaySuffix": "/rss", "maxStartDelay": 1,
         "statePath": str(T / "state.json"), "bots": bots}
    c.update(extra)
    (T / "config.json").write_text(json.dumps(c))
    return spawn([BROCKMAN, str(T / "config.json")], stdout=open(T / "brockman.log", "a"), stderr=subprocess.STDOUT)


def logcount(pattern): return int(subprocess.run(["grep", "-c", pattern, str(T / "brockman.log")], capture_output=True, text=True).stdout.strip() or 0)


def smoke():
    start_ergo = setup_ergo(); ergo = start_ergo(); time.sleep(2)
    feeds = T / "feeds"; feeds.mkdir(); items = {"one": [], "two": []}

    def add(name, *titles):
        items[name].extend(titles); now = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
        body = "".join(f"<item><title>{t}</title><link>http://example.org/{name}/{i}</link><pubDate>{now}</pubDate></item>" for i, t in reversed(list(enumerate(items[name]))))
        (feeds / f"{name}.xml").write_text(f'<?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>{name}</title><link>http://example.org</link><description>d</description>{body}</channel></rss>')

    add("one", "seed one"); add("two", "seed two"); serve(feeds, FEED_PORT)
    w = Watcher(); time.sleep(1)
    url = f"http://127.0.0.1:{FEED_PORT}"
    b = brockman_config({"one": {"feed": f"{url}/one.xml", "delay": 3}, "two": {"feed": f"{url}/two.xml", "delay": 3, "extraChannels": ["#x", "watcher"]},
                         "dead": {"feed": f"{url}/missing.xml", "delay": 3}})
    time.sleep(6); assert logcount("opered") == 1, "no OPER"
    t0 = time.time(); add("one", "hello wörld ✓", "ä" * 400); add("two", "two-news"); time.sleep(7)
    for l in w.grep(r"PRIVMSG|NOTICE", t0): print(len(l.encode()), l[:150])
    t1 = time.time(); add("two", *[f"burst {i}" for i in range(60)]); time.sleep(8)
    print("burst in #all:", len(w.grep(r"PRIVMSG #all :.*burst", t1)))
    t2 = time.time()
    for c in ["help", "info two/rss", "tick one 4", "set-url dead " + url + "/one.xml", "invite one", "remove nosuchbot", "remove dead"]:
        w.send(f"PRIVMSG #x :brockman: {c}"); time.sleep(0.4)
    time.sleep(2)
    for l in w.grep(r"^:brockman!\S+ PRIVMSG #x ", t2)[-8:]: print(l[:150])
    ergo.terminate(); ergo.wait(); add("two", "during downtime"); time.sleep(8)
    ergo = start_ergo(); time.sleep(1.5); w = Watcher(); t4 = time.time(); time.sleep(25)
    print("re-opered:", logcount("opered") == 2, "| delivered after reconnect:", len(w.grep(r"during downtime", t4)))
    b.kill(); ergo.kill()


def memory(directory):
    start_ergo = setup_ergo(); ergo = start_ergo(); time.sleep(2); serve(directory, BODY_PORT)
    names = os.listdir(directory)
    b = brockman_config({f"r{i}": {"feed": f"http://127.0.0.1:{BODY_PORT}/{n}"} for i, n in enumerate(names)}, maxStartDelay=60, fetchConcurrency=64)
    peak, t0 = 0, time.time()
    while time.time() - t0 < 1200 and b.poll() is None:
        time.sleep(30)
        rss = int(subprocess.run(["ps", "-o", "rss=", "-p", str(b.pid)], capture_output=True, text=True).stdout or 0) // 1024; peak = max(peak, rss)
        fetched = logcount("tick ")
        print(int(time.time() - t0), f"rss={rss}M peak={peak}M fetched={fetched}/{len(names)}", flush=True)
        if fetched >= len(names) - 200: break
    b.kill(); ergo.kill()


if __name__ == "__main__":
    {"smoke": lambda: smoke(), "memory": lambda: memory(sys.argv[2])}[sys.argv[1]]()
