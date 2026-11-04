#!/usr/bin/env python3
"""Leitura do arquivo de estatisticas que a passada 1 do x265 escreve.

Cada frame vira uma linha com os bits gastos (tex+mv+misc), o QP e o tipo
(I/P/B). Dai sai o que a passada 2 vai fazer: onde ela vai por mais e menos
bitrate. A conta e a mesma do controle de taxa do x265:

    complexidade = bits_da_passada_1 x qscale_da_passada_1
    bits_na_passada_2 ~ complexidade ^ qcomp        (qcomp = 0.6, padrao)

normalizada para a media bater com o bitrate-alvo do job. E uma estimativa:
o VBV ainda corta os picos, e o x265 suaviza a complexidade entre frames
vizinhos. Mas acerta bem onde estao as cenas caras e as baratas.

A leitura e incremental: cada chamada so le o que o x265 escreveu desde a
anterior, entao acompanhar um filme de 86 mil frames custa quase nada.
"""
import os
import re
import threading

QCOMP = 0.6
LINE_RE = re.compile(
    r"in:(\d+) out:(\d+) type:(\w) q:([\d.-]+) .*?tex:(\d+) mv:(\d+) misc:(\d+)")

_cache = {}
last_error = None
_lock = threading.Lock()  # o servidor atende em varias threads


def qscale(q):
    return 0.85 * (2.0 ** ((q - 12.0) / 6.0))


def stats_file(path):
    """O x265 escreve em <stats>.temp enquanto roda e renomeia no fim."""
    for p in (path + ".temp", path):
        if p and os.path.exists(p):
            return p
    return None


def read(path):
    with _lock:
        return _read(path)


def _read(path):
    """Devolve (frames, complete). frames[i] = (bits, complexidade, tipo)."""
    f = stats_file(path)
    if not f:
        return [], False
    try:
        size = os.path.getsize(f)
    except OSError:
        return [], False
    st = _cache.get(path)
    if st is None or size < st["offset"] or st["file"] != f:
        st = {"offset": 0, "frames": [], "file": f, "tail": ""}
        _cache[path] = st
    if size > st["offset"]:
        global last_error
        try:
            with open(f, "r", errors="replace") as fh:
                fh.seek(st["offset"])
                chunk = fh.read()
            st["offset"] = size
            last_error = None
        except OSError as e:
            last_error = "%s ao ler %s" % (e, f)
            chunk = ""
        data = st["tail"] + chunk
        lines = data.split("\n")
        st["tail"] = lines.pop() if not data.endswith("\n") else ""
        for l in lines:
            m = LINE_RE.search(l)
            if not m:
                continue
            frame = int(m.group(1))
            typ = m.group(3)
            q = float(m.group(4))
            bits = int(m.group(5)) + int(m.group(6)) + int(m.group(7))
            while len(st["frames"]) <= frame:
                st["frames"].append(None)
            st["frames"][frame] = (bits, bits * qscale(q), typ)
    # o x265 grava em ordem de codificacao, entao o fim do arquivo tem buracos:
    # usa so o prefixo contiguo, para o indice da lista ser mesmo o numero do frame
    cut = len(st["frames"])
    for i, x in enumerate(st["frames"]):
        if x is None:
            cut = i
            break
    return st["frames"][:cut], not f.endswith(".temp")


def allocate(weights, total_bits, cap):
    """Reparte `total_bits` entre os frames na proporcao dos pesos, sem passar
    do teto por frame (vbv-maxrate). O que sobra dos frames no teto e
    redistribuido para os outros, como o x265 faz para fechar a media."""
    if not cap:
        k = total_bits / sum(weights)
        return [w * k for w in weights]
    lo, hi = 0.0, total_bits / max(1e-9, min(w for w in weights if w > 0) or 1)
    for _ in range(60):
        k = (lo + hi) / 2
        s = sum(min(w * k, cap) for w in weights)
        if s < total_bits:
            lo = k
        else:
            hi = k
    k = (lo + hi) / 2
    return [min(w * k, cap) for w in weights]


def profile(path, target_mbps, max_mbps, fps, buckets=420, current=None):
    """Perfil de bitrate estimado ao longo do filme.

    Devolve buckets ao longo dos frames ja medidos, as cenas (cortes nos
    frames I) e as mais pesadas e mais leves.
    """
    frames, complete = read(path)
    n = len(frames)
    if n < 2:
        return None
    target_bits = target_mbps * 1e6 / fps
    comps = [c for _b, c, _t in frames]
    powered = [c ** QCOMP if c > 0 else 0.0 for c in comps]
    mean_p = sum(powered) / n
    if mean_p <= 0:
        return None
    cap = max_mbps * 1e6 / fps if max_mbps else None
    est = allocate(powered, target_bits * n, cap)

    step = max(1, n // buckets)
    prof = []
    for i in range(0, n, step):
        part = est[i:i + step]
        prof.append({"f": i, "mbps": round(sum(part) / len(part) * fps / 1e6, 2)})

    # o x265 marca I (IDR) e i (keyframe de corte de cena): ambos abrem cena
    scenes, start = [], 0
    for i, (_b, _c, t) in enumerate(frames):
        if t in ("I", "i") and i > start:  # I = IDR, i = corte de cena
            scenes.append((start, i))
            start = i
    scenes.append((start, n))
    detail = []
    for a, b in scenes:
        if b - a < 2:
            continue
        part = est[a:b]
        detail.append({
            "start": a,
            "frames": b - a,
            "mbps": round(sum(part) / len(part) * fps / 1e6, 2),
        })
    ranked = sorted(detail, key=lambda s: s["mbps"])
    now_scene = None
    lag = 0
    if current is not None:
        lag = max(0, current - (n - 1))
        current = min(current, n - 1)
        for sc in detail:
            if sc["start"] <= current < sc["start"] + sc["frames"]:
                now_scene = dict(sc)
                now_scene["rank"] = sum(1 for x in detail if x["mbps"] > sc["mbps"]) + 1
                break
    return {
        "scene_now": now_scene,
        "lag_frames": lag,
        "frames_measured": n,
        "complete": complete,
        "buckets": prof,
        "scenes": len(detail),
        "target_mbps": target_mbps,
        "max_mbps": max_mbps,
        "avg_mbps": round(sum(est) / n * fps / 1e6, 2),
        "heaviest": list(reversed(ranked[-5:])),
        "lightest": ranked[:5],
        "cum_bits": None,
    }


_cum_cache = {}


def cumulative_bits(path, target_mbps, max_mbps, fps):
    """Bits acumulados previstos por frame — usado para saber em que frame a
    passada 2 esta, pelo tamanho do arquivo que ela ja escreveu."""
    f = stats_file(path)
    try:
        size = os.path.getsize(f) if f else 0
    except OSError:
        size = 0
    key = (path, size, target_mbps, max_mbps, fps)
    with _lock:                      # nao segurar o lock durante o read(): ele pega o mesmo
        if _cum_cache.get("key") == key:
            return _cum_cache["value"]
    frames, _c = read(path)
    n = len(frames)
    if n < 2:
        return None
    target_bits = target_mbps * 1e6 / fps
    powered = [(c ** QCOMP if c > 0 else 0.0) for _b, c, _t in frames]
    mean_p = sum(powered) / n
    if mean_p <= 0:
        return None
    cap = max_mbps * 1e6 / fps if max_mbps else None
    est = allocate(powered, target_bits * n, cap)
    out, run = [], 0.0
    for e in est:
        run += e
        out.append(run)
    with _lock:
        _cum_cache["key"], _cum_cache["value"] = key, out
    return out


def frame_from_bytes(cum, written_bytes):
    """Em que frame a passada 2 esta, dado o tamanho do .hevc ja escrito."""
    if not cum:
        return None
    bits = written_bytes * 8
    lo, hi = 0, len(cum) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cum[mid] < bits:
            lo = mid + 1
        else:
            hi = mid
    return lo
