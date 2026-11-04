#!/usr/bin/env python3
"""Mede o QP com que cada frame REALMENTE saiu, depois do encode pronto.

A passada 1 do x265 grava, por frame, os bits gastos e o QP usado; disso sai a
complexidade (bits x qscale), que e independente do QP. A passada 2 nao grava
nada disso — mas o tamanho de cada frame no arquivo final diz quanto ela gastou.
Com a complexidade da passada 1 e os bits da passada 2:

    qscale_real = complexidade / bits_da_passada_2
    QP_real     = 12 + 6 x log2(qscale_real / 0.85)

E com isso da para responder, com numero: quanto do filme saiu pior que o piso
de qualidade (`qpmax`), e onde.

E um QP *efetivo*, derivado, nao o QP exato que o x265 anotou: o tamanho do
frame no container inclui cabecalhos, e a complexidade veio de uma passada 1 de
analise reduzida. Serve para dizer "esta cena saiu bem pior que o piso", nao
para discutir decimos de QP. Para o numero exato, o x265 precisaria ter rodado
com `--csv <arquivo> --csv-log-level 2`.

Uso:
    python3 qpreal.py --stats <x265.stats> --video <final.mkv> [--floor 18] [--fps 24]
"""
import argparse
import json
import math
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import x265stats

FFPROBE = next((p for p in ("/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe")
                if os.path.exists(p)), "ffprobe")


def qscale_to_qp(q):
    return 12.0 + 6.0 * math.log2(q / 0.85)


def packet_sizes(video):
    """Bytes de cada frame de video, em ordem de exibicao.

    O ffprobe entrega os pacotes em ordem de decodificacao; ordenar por pts
    devolve a ordem de exibicao, que e a mesma do `in:` das estatisticas.
    """
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0",
         "-show_entries", "packet=pts,size", "-of", "csv=p=0", video],
        capture_output=True, text=True, check=True).stdout
    pkts = []
    for line in out.splitlines():
        parts = line.split(",")
        if len(parts) < 2:
            continue
        pts, size = parts[0], parts[1]
        if size.strip().isdigit():
            pkts.append((float(pts) if pts not in ("N/A", "") else len(pkts),
                         int(size)))
    pkts.sort(key=lambda p: p[0])
    return [s for _pts, s in pkts]


def measure(stats, video, floor_qp, fps):
    frames, complete = x265stats.read(stats)
    if not complete:
        print("aviso: a passada 1 ainda estava gravando quando li o stats", file=sys.stderr)
    sizes = packet_sizes(video)
    n = min(len(frames), len(sizes))
    if n < 2:
        raise SystemExit("nada para comparar: %d frames no stats, %d no video"
                         % (len(frames), len(sizes)))
    rows = []
    for i in range(n):
        bits = sizes[i] * 8
        comp = frames[i][1]
        if bits <= 0 or comp <= 0:
            continue
        rows.append((i, qscale_to_qp(comp / bits), bits * fps / 1e6))
    qps = [q for _i, q, _m in rows]
    pior = [r for r in rows if r[1] > floor_qp]
    qps_ord = sorted(qps)
    def pct(p):
        return qps_ord[min(len(qps_ord) - 1, int(len(qps_ord) * p))]
    # viés medido num encode 2-pass de controle (testsrc2, qpmax=18): o QP
    # derivado saiu entre +0,2 e +1,0 acima do teto real. A causa é a passada 1
    # de análise reduzida superestimar a complexidade — a passada 2 entrega a
    # mesma qualidade com menos bits. Por isso só contamos como "claramente
    # pior" o que passa do piso por mais de 1,5 QP.
    claro = [r for r in rows if r[1] > floor_qp + 1.5]
    return {
        "frames": len(rows),
        "frames_no_stats": len(frames),
        "frames_no_video": len(sizes),
        "qp_medio": sum(qps) / len(qps),
        "qp_mediana": pct(0.5),
        "qp_p95": pct(0.95),
        "qp_pior": max(qps),
        "piso": floor_qp,
        "piores_que_o_piso": len(pior),
        "pct_pior_que_o_piso": 100.0 * len(pior) / len(rows),
        "claramente_pior": len(claro),
        "pct_claramente_pior": 100.0 * len(claro) / len(rows),
        "mbps_medio": sum(m for _i, _q, m in rows) / len(rows),
        "trechos": piores_trechos(pior, fps),
    }


def piores_trechos(pior, fps, limite=10):
    """Junta frames vizinhos que sairam pior que o piso num trecho so."""
    trechos, atual = [], None
    for i, qp, _m in pior:
        if atual and i - atual["fim"] <= 12:
            atual["fim"] = i
            atual["qp"] = max(atual["qp"], qp)
            atual["n"] += 1
        else:
            if atual:
                trechos.append(atual)
            atual = {"inicio": i, "fim": i, "qp": qp, "n": 1}
    if atual:
        trechos.append(atual)
    trechos.sort(key=lambda t: t["qp"], reverse=True)
    for t in trechos:
        s = t["inicio"] / fps
        t["tc"] = "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)
        t["segundos"] = round(t["n"] / fps, 1)
    return trechos[:limite]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stats", required=True)
    ap.add_argument("--video", required=True)
    ap.add_argument("--floor", type=int, default=18)
    ap.add_argument("--fps", type=float, default=24.0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    r = measure(a.stats, a.video, a.floor, a.fps)
    if a.json:
        print(json.dumps(r, indent=1, ensure_ascii=False))
        return
    print("Frames comparados: %d  (stats %d · vídeo %d)"
          % (r["frames"], r["frames_no_stats"], r["frames_no_video"]))
    print("Bitrate médio medido: %.1f Mbps" % r["mbps_medio"])
    print("QP efetivo — médio %.1f · mediana %.1f · 95%% em %.1f · pior %.1f"
          % (r["qp_medio"], r["qp_mediana"], r["qp_p95"], r["qp_pior"]))
    print("Piso pedido: QP %d" % r["piso"])
    print("Saiu pior que o piso: %d frames (%.1f%%) — margem de 1,5 QP incluída: %d (%.1f%%)"
          % (r["piores_que_o_piso"], r["pct_pior_que_o_piso"],
             r["claramente_pior"], r["pct_claramente_pior"]))
    print("O QP aqui é derivado e puxa ~+0,2 a +1,0 para cima (a passada 1 mede com\n"
          "análise reduzida): confie no segundo número, não no primeiro.")
    if r["trechos"]:
        print("\nPiores trechos:")
        for t in r["trechos"]:
            print("  %-9s %5.1f s   QP %.1f" % (t["tc"], t["segundos"], t["qp"]))


if __name__ == "__main__":
    main()
