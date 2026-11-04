#!/usr/bin/env python3
"""Monitor dos jobs do BROS-MUX.

Serve uma pagina de widgets em http://localhost:8787 com, para cada job rodando:
fps instantaneo e medio, progresso, tempo restante estimado e o tempo decorrido
em cada etapa (ler metadata, passada 1, passada 2, mux). Nao toca em nada do
render: so le `ps` e o log do job.
"""
import json
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.expanduser("~/.bros-mux-monitor")
PORT = int(os.environ.get("BROS_MUX_MONITOR_PORT", "8787"))

FRAME_RE = re.compile(r"frame ([\d,]+) of ([\d,]+)")
FPS_RE = re.compile(r"([\d.]+) fps")
PCT_RE = re.compile(r"(\d+)\s*%\s*$")
PASS_RE = re.compile(r"Pass (\d+) of (\d+)")
OUT_RE = re.compile(r"-o (.+?) --")
SCRIPT_RE = re.compile(r"^script (?:-\w+ )*(\S+\.log)\b")


def sh(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def num(s):
    return int(s.replace(",", ""))


def ps_rows():
    rows = []
    for line in sh(["ps", "-Ao", "pid=,ppid=,pcpu=,args="]).splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        try:
            rows.append((int(parts[0]), int(parts[1]), float(parts[2]), parts[3]))
        except ValueError:
            continue
    return rows


def started_at(pid):
    out = sh(["ps", "-o", "lstart=", "-p", str(pid)]).strip()
    if not out:
        return None
    try:
        return time.mktime(time.strptime(out))
    except ValueError:
        return None


def find_processes():
    rows = ps_rows()
    logs = {}
    for pid, _ppid, _cpu, args in rows:
        m = SCRIPT_RE.match(args)
        if m:
            logs[pid] = m.group(1)
    jobs, apps = [], []
    binary = re.compile(r"^\S*BROS-MUX\.app/Contents/MacOS/BROS-MUX\b")
    for pid, ppid, cpu, args in rows:
        if not binary.match(args):
            continue
        if "--job" in args:
            out = OUT_RE.search(args)
            jobs.append({
                "pid": pid,
                "cpu": cpu,
                "args": args,
                "log": logs.get(ppid),
                "output": out.group(1).strip() if out else None,
            })
        elif args.endswith("MacOS/BROS-MUX"):
            apps.append({"pid": pid, "cpu": cpu})
    # ffmpeg/x265 por job
    for j in jobs:
        j["cpu_encoder"] = sum(c for _p, pp, c, a in rows if pp == j["pid"] and "ffmpeg" in a)
        enc = next((a for _p, pp, _c, a in rows if pp == j["pid"] and "ffmpeg" in a), "")
        # x265 roda a passada 1 com analise reduzida (slow-firstpass=0): a
        # passada 2, no preset cheio, e bem mais lenta que a 1.
        j["fast_first_pass"] = "slow-firstpass=0" in enc
    return jobs, apps


CTRL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


def stage_of(line):
    s = CTRL_RE.sub("", line)
    s = PCT_RE.sub("", s).strip()
    s = s.lstrip("…•·✓✗-* ").strip()
    if ": frame" in s:
        s = s.split(": frame")[0]
    return s.strip(" ·•")


def read_log(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 400_000))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return [], None
    lines = [l.strip() for l in data.replace("\r", "\n").split("\n") if l.strip()]
    return lines, size


def log_curve(lines, stage, now):
    """Curva de fps da etapa atual, tirada do proprio log.

    Cada linha de progresso traz `frame N of M` e o fps medio acumulado: o
    tempo decorrido na etapa e frame/fps_medio. Dai sai o fps instantaneo
    entre duas linhas, desde o comeco da etapa.
    """
    pts = []
    for l in lines:
        l = CTRL_RE.sub("", l)
        if stage_of(l) != stage:
            continue
        mf, mr = FRAME_RE.search(l), FPS_RE.search(l)
        if not (mf and mr):
            continue
        frame, avg = num(mf.group(1)), float(mr.group(1))
        if avg > 0:
            pts.append((frame / avg, frame))
    if len(pts) < 2:
        return [], None
    start = now - pts[-1][0]
    hist, prev = [], pts[0]
    for el, frame in pts[1:]:
        if el - prev[0] < 55 and (el, frame) != pts[-1]:
            continue
        if el > prev[0] and frame > prev[1]:
            hist.append({"t": start + el, "fps": (frame - prev[1]) / (el - prev[0])})
        prev = (el, frame)
    return hist, start


def samples_path(pid):
    os.makedirs(STATE, exist_ok=True)
    return os.path.join(STATE, "samples-%d.jsonl" % pid)


def load_samples(pid):
    out = []
    try:
        with open(samples_path(pid)) as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def save_sample(pid, sample, samples):
    if samples and sample["t"] - samples[-1]["t"] < 2:
        return samples
    if samples and samples[-1].get("frame") == sample.get("frame") \
            and samples[-1].get("stage") == sample.get("stage") \
            and sample["t"] - samples[-1]["t"] < 15:
        return samples
    with open(samples_path(pid), "a") as f:
        f.write(json.dumps(sample) + "\n")
    samples.append(sample)
    return samples


def fps_window(samples, stage, window=90):
    pts = [s for s in samples if s.get("stage") == stage and s.get("frame")]
    if len(pts) < 2:
        return None
    last = pts[-1]
    base = None
    for s in reversed(pts[:-1]):
        base = s
        if last["t"] - s["t"] >= window:
            break
    if not base or last["t"] - base["t"] < 45 or last["frame"] <= base["frame"]:
        return None  # janela curta demais para um numero estavel
    return (last["frame"] - base["frame"]) / (last["t"] - base["t"])


def partial_output(output):
    if not output:
        return None
    outdir = os.path.dirname(output)
    try:
        for name in os.listdir(outdir):
            if not name.startswith(".BROS-MUX-tmp"):
                continue
            d = os.path.join(outdir, name)
            if not os.path.isdir(d):
                continue
            best = None
            for f in os.listdir(d):
                p = os.path.join(d, f)
                try:
                    sz = os.path.getsize(p)
                except OSError:
                    continue
                if os.path.splitext(f)[1].lower() not in (".hevc", ".mkv", ".mp4", ".mov"):
                    continue
                if best is None or sz > best[1]:
                    best = (f, sz)
            if best:
                return {"name": best[0], "bytes": best[1]}
    except OSError:
        pass
    return None


def build_job(proc, now):
    job = {
        "pid": proc["pid"],
        "output": proc["output"],
        "title": os.path.basename(proc["output"]) if proc["output"] else "BROS-MUX job",
        "log": proc["log"],
        "cpu": proc["cpu"] + proc.get("cpu_encoder", 0.0),
        "started": started_at(proc["pid"]),
        "stage": None,
        "stages": [],
        "fps_now": None,
        "fps_avg": None,
        "frame": None,
        "frames": None,
        "pct_stage": None,
        "pct_total": None,
        "eta_stage": None,
        "eta_total": None,
        "pass_no": None,
        "pass_of": None,
        "fps_history": [],
        "partial": partial_output(proc["output"]),
        "fast_first_pass": proc.get("fast_first_pass", False),
        "eta_total_max": None,
    }
    if job["started"]:
        job["elapsed"] = now - job["started"]
    lines, _size = read_log(proc["log"]) if proc["log"] else ([], None)
    if not lines:
        job["stage"] = "sem log para acompanhar"
        return job

    last = next((l for l in reversed(lines) if PCT_RE.search(CTRL_RE.sub("", l))), lines[-1])
    stage = stage_of(last)
    job["stage"] = stage
    m = FRAME_RE.search(last)
    if m:
        job["frame"], job["frames"] = num(m.group(1)), num(m.group(2))
    m = FPS_RE.search(last)
    if m:
        job["fps_avg"] = float(m.group(1))
    m = PCT_RE.search(last)
    if m:
        job["pct_stage"] = int(m.group(1))
    m = PASS_RE.search(stage)
    if m:
        job["pass_no"], job["pass_of"] = int(m.group(1)), int(m.group(2))

    samples = load_samples(proc["pid"])
    samples = save_sample(proc["pid"], {"t": now, "stage": stage, "frame": job["frame"]}, samples)
    job["fps_now"] = fps_window(samples, stage)

    curve, stage_start_from_log = log_curve(lines, stage, now)
    job["fps_history"] = curve[-60:]
    if job["fps_now"] is None and curve:
        job["fps_now"] = curve[-1]["fps"]
    # fps tipico: mediana dos ultimos 20 min, que e o ritmo real do filme
    recent = sorted(h["fps"] for h in curve if now - h["t"] <= 1200) or \
             sorted(h["fps"] for h in curve[-12:])
    job["fps_typical"] = recent[len(recent) // 2] if recent else None

    # etapas: ordem de aparicao no log + duracao
    order, seen = [], set()
    for l in lines:
        if not PCT_RE.search(CTRL_RE.sub("", l)):
            continue
        st = stage_of(l)
        if st and st not in seen:
            seen.add(st)
            order.append(st)
    first_seen = {}
    for s in samples:
        st = s.get("stage")
        if st and st not in first_seen:
            first_seen[st] = s["t"]

    rate = job["fps_typical"] or job["fps_now"] or job["fps_avg"]
    starts = {}
    for st in order:
        if st in first_seen:
            starts[st] = first_seen[st]
    # etapa atual com contador de frames: deduz o inicio pelo fps medio
    if stage_start_from_log or (job["frame"] and job["fps_avg"]):
        est = stage_start_from_log if stage_start_from_log \
            else now - job["frame"] / job["fps_avg"]
        if stage not in starts or starts[stage] > est:
            starts[stage] = est
    if order and order[0] not in starts and job["started"]:
        starts[order[0]] = job["started"]

    for i, st in enumerate(order):
        nxt = order[i + 1] if i + 1 < len(order) else None
        start = starts.get(st)
        end = starts.get(nxt) if nxt else None
        current = st == stage
        dur = None
        if start is not None:
            dur = (end if end is not None else now) - start
        job["stages"].append({
            "name": st,
            "start": start,
            "elapsed": dur,
            "state": "atual" if current else ("feita" if nxt else "atual"),
            "estimated": st not in first_seen,
        })

    if job["frame"] and job["frames"] and rate:
        left_stage = (job["frames"] - job["frame"]) / rate
        job["eta_stage"] = left_stage
        total = total_max = left_stage
        if job["pass_no"] and job["pass_of"] and job["pass_of"] > job["pass_no"]:
            rest = (job["pass_of"] - job["pass_no"]) * job["frames"] / rate
            lo, hi = (2.0, 3.5) if job["fast_first_pass"] else (1.0, 1.15)
            total += rest * lo + 240      # 240 s = mux + injecao do RPU
            total_max += rest * hi + 240
        job["eta_total"] = total
        job["eta_total_max"] = total_max if total_max > total * 1.02 else None
        if job["pass_no"] and job["pass_of"]:
            done = (job["pass_no"] - 1 + job["frame"] / job["frames"]) / job["pass_of"]
            job["pct_total"] = round(done * 100, 1)
        else:
            job["pct_total"] = round(job["frame"] / job["frames"] * 100, 1)
    return job


def status():
    now = time.time()
    procs, apps = find_processes()
    jobs = [build_job(p, now) for p in procs]
    load = os.getloadavg()
    return {
        "now": now,
        "host": sh(["scutil", "--get", "ComputerName"]).strip() or os.uname().nodename,
        "chip": sh(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
        "cores": os.cpu_count(),
        "load": [round(x, 2) for x in load],
        "jobs": jobs,
        "apps": apps,
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            self.send_file(os.path.join(HERE, "index.html"), "text/html; charset=utf-8")
        elif path == "/status.json":
            body = json.dumps(status()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def send_file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("BROS-MUX render monitor em http://localhost:%d" % PORT, flush=True)
    srv.serve_forever()
