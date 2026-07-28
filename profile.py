#!/usr/bin/env python3
"""Profile l'app Pépito en cours d'exécution : sample(1) → classement des points chauds + flamegraph.

    ./profile.py [secondes]      # défaut : 10 s

Écrit `.build/profile-<horodatage>.svg` et imprime le classement sur stdout (c'est le classement
qui sert à décider — le SVG sert à explorer). L'app doit tourner : `./build-app.sh; open .build/Pepito.app`.

Pourquoi pas Instruments : `xctrace` exige un .trace à ouvrir dans l'UI, illisible en ligne de
commande. `sample` donne le même arbre d'appels en texte, sans droits particuliers.
"""
import colorsys, html, os, random, re, subprocess, sys, time

SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 10
ROOT = os.path.dirname(os.path.abspath(__file__))

# ponytail: liste en dur des symboles « thread qui ne travaille pas ». sample(1) échantillonne *tous*
# les threads, endormis compris — sans ce filtre un pool inactif pèse autant que le thread principal
# saturé et le classement ment. À compléter si un thread manifestement idle remonte en tête.
# `start_wqthread` en feuille = thread de workqueue attrapé pendant sa création, pile incomplète :
# ce n'est pas du travail, et sans lui un pic de création de threads (réponses XPC) passe en tête.
BLOCKED = (
    '__workq_kernreturn', 'mach_msg2_trap', '__psynch_cvwait', 'kevent', 'kevent_id',
    'semaphore_wait_trap', 'semaphore_timedwait_trap', 'semaphore_wait_signal_trap',
    '__select', '__ulock_wait', 'poll', 'read', '__accept', 'thread_switch', 'swtch_pri',
    'start_wqthread',
)

LINE = re.compile(r'^(?P<pre>[ +!:|]*?)(?P<n>\d+) (?P<sym>.*)$')


def find_pid():
    out = subprocess.run(['pgrep', '-f', 'Pepito.app/Contents/MacOS/Pepito'],
                         capture_output=True, text=True).stdout.split()
    if not out:
        sys.exit("Pepito ne tourne pas. Lance : ./build-app.sh && open .build/Pepito.app")
    if len(out) > 1:
        sys.exit(f"Plusieurs processus Pepito ({', '.join(out)}) — tue les doublons d'abord.")
    return int(out[0])


def parse(path):
    """sample(1) → {(thread, frame, …): self_samples}. La profondeur vient de l'indentation."""
    stacks, stack = {}, []
    for raw in open(path, errors='replace'):
        if raw.startswith('Binary Images'):
            break
        m = LINE.match(raw.rstrip('\n'))
        if not m or not raw.startswith('    '):
            continue
        depth, n = (len(m.group('pre')) - 4) // 2, int(m.group('n'))
        sym = re.sub(r'\s*\+ \d+.*$', '', m.group('sym'))      # « + 1234  [0x…] »
        sym = re.sub(r'\s*\[0x.*$', '', sym).strip() or '??'
        del stack[depth:]
        stack.append(sym)
        key = tuple(stack)
        stacks[key] = stacks.get(key, 0) + n
        if depth:                                              # le temps d'un enfant n'est pas du self
            parent = tuple(stack[:-1])
            stacks[parent] = stacks.get(parent, 0) - n
    return stacks


def tree(stacks):
    root = {'name': 'all', 'value': 0, 'children': {}}
    for frames, self_n in stacks.items():
        if self_n <= 0:
            continue
        node = root
        for f in frames:
            node = node['children'].setdefault(f, {'name': f, 'value': 0, 'children': {}})
            node['value'] += self_n
        root['value'] += self_n
    return root


def svg(root, path, subtitle):
    W, H = 1400, 17
    rows = []

    def walk(node, x, depth):
        for child in sorted(node['children'].values(), key=lambda c: -c['value']):
            w = child['value'] / root['value'] * W
            if w > 0.25:
                rows.append((x, depth, w, child['name'], child['value']))
                walk(child, x, depth + 1)
            x += w

    walk(root, 0, 0)
    if not rows:
        return
    height = (max(r[1] for r in rows) + 1) * H + 60

    def color(name):
        random.seed(name)
        hue = 0.02 if '(in Pepito)' in name else (0.09 if re.search(r'SwiftUI|QuartzCore|CoreText', name) else 0.13)
        r, g, b = colorsys.hsv_to_rgb(hue + random.random() * .03, .62 + random.random() * .2, .92)
        return '#%02x%02x%02x' % (int(r * 255), int(g * 255), int(b * 255))

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" '
             f'font-family="ui-monospace,Menlo,monospace" font-size="11">',
             f'<rect width="{W}" height="{height}" fill="#12141a"/>',
             f'<text x="{W/2}" y="22" fill="#e6e6e6" text-anchor="middle" font-size="15">'
             f'{html.escape(subtitle)}</text>']
    for x, d, w, name, v in rows:
        y, pct = height - (d + 1) * H, v / root['value'] * 100
        label = name if len(name) * 6.2 < w else (name[:int(w / 6.2) - 2] + '…' if w > 30 else '')
        parts.append(f'<g><title>{html.escape(name)} — {v} ({pct:.1f}%)</title>'
                     f'<rect x="{x:.1f}" y="{y}" width="{max(w-.6,.3):.1f}" height="{H-1}" '
                     f'fill="{color(name)}" rx="1"/>'
                     f'<text x="{x+3:.1f}" y="{y+H-5}" fill="#101014">{html.escape(label)}</text></g>')
    parts.append('</svg>')
    open(path, 'w').write('\n'.join(parts))


def main():
    pid = find_pid()
    # top -l 2 : la 1re passe est une moyenne depuis le lancement, la 2e une mesure instantanée.
    top = subprocess.run(['top', '-l', '2', '-pid', str(pid), '-stats', 'cpu'],
                         capture_output=True, text=True).stdout.split()
    cpu = top[-1] if top else '?'
    print(f"PID {pid} — {cpu} % CPU instantané — échantillonnage {SECONDS} s…")

    os.makedirs(f'{ROOT}/.build', exist_ok=True)
    stamp = time.strftime('%Y%m%d-%H%M%S')
    raw = f'{ROOT}/.build/profile-{stamp}.txt'
    subprocess.run(['sample', str(pid), str(SECONDS), '1', '-f', raw],
                   check=True, stdout=subprocess.DEVNULL)

    stacks = parse(raw)

    # Par thread : actif = hors symboles bloquants. C'est « actif » qui approche le CPU réel.
    threads = {}
    for frames, n in stacks.items():
        if n <= 0:
            continue
        t = threads.setdefault(frames[0], [0, 0])
        t[0] += n
        if not frames[-1].split('  (in')[0].strip() in BLOCKED:
            t[1] += n

    print("\n  actif   total  thread")
    for name, (total, active) in sorted(threads.items(), key=lambda kv: -kv[1][1])[:8]:
        print(f"  {active:6d}  {total:6d}  {name[:78]}")

    busiest = max(threads, key=lambda k: threads[k][1])
    hot = {f: n for f, n in stacks.items() if f[0] == busiest}
    root = tree(hot)
    if not root['value']:
        sys.exit("Aucun échantillon exploitable.")

    out = f'{ROOT}/.build/profile-{stamp}.svg'
    svg(root, out, f'Pépito — {busiest[:60]} — {SECONDS} s @ 1 kHz ({root["value"]} échantillons)')

    # Self time : où le CPU part vraiment. Inclusif : où le chemin passe.
    self_t, incl = {}, {}
    for frames, n in hot.items():
        if n <= 0:
            continue
        self_t[frames[-1]] = self_t.get(frames[-1], 0) + n
        for f in set(frames[1:]):
            incl[f] = incl.get(f, 0) + n
    tot = root['value']

    def table(title, d, keep=lambda _: True):
        print(f"\n{title}")
        rows = [(v, k) for k, v in d.items() if keep(k)]
        for v, k in sorted(rows, reverse=True)[:12]:
            print(f"  {v/tot*100:5.1f}%  {k[:92]}")

    table("Self time (feuilles) — le CPU est ici :", self_t)
    table("Inclusif, code Pepito uniquement :", incl, lambda k: '(in Pepito)' in k)
    print(f"\nFlamegraph : {out}\nBrut       : {raw}")


if __name__ == '__main__':
    main()
