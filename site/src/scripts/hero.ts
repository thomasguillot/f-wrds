import { byId } from './dom';
import { bind, reduced, sleep, typeInto, type Snippet } from './engine';

const headline = (() => {
  const T = byId('hT');
  const N = byId('hN');
  const nouns: Record<string, string> = {
    ';sig': 'signature',
    ';date': 'date',
    ';omw': 'reply',
    ';ty': 'thank-you',
    ';oops': 'apology',
  };
  const G = '#@!%&*$?';
  let run = 0;
  const swap = async (el: HTMLElement, to: string, id: number): Promise<void> => {
    const from = el.textContent ?? '';
    if (reduced || from === to) {
      el.textContent = to;
      return;
    }
    const n = 8;
    for (let i = 1; i <= n; i++) {
      if (id !== run) return;
      const len = Math.round(from.length + ((to.length - from.length) * i) / n);
      el.textContent = [...Array(len)]
        .map((_, k) => (k < (len * i) / n - 1 && to[k] ? to[k] : G[(Math.random() * G.length) | 0]))
        .join('');
      await sleep(30);
    }
    if (id === run) el.textContent = to;
  };
  const set = (t: string): void => {
    if (!nouns[t]) return;
    const id = ++run;
    swap(T, t, id);
    swap(N, nouns[t], id);
  };
  const order = [';sig', ';date', ';omw', ';oops', ';ty'];
  let i = 0;
  let timer: ReturnType<typeof setInterval> | null = null;
  let visible = true;
  let manual = false;
  const tick = (): void => {
    if (manual || !visible || document.hidden) return;
    i = (i + 1) % order.length;
    set(order[i]);
  };
  if (!reduced) {
    timer = setInterval(tick, 4000);
    const h1 = T.closest('h1');
    if ('IntersectionObserver' in window && h1) {
      new IntersectionObserver((es) => {
        visible = es[0].isIntersecting;
      }).observe(h1);
    }
  }
  return (t: string): void => {
    manual = true;
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    set(t);
  };
})();

const d = byId<HTMLTextAreaElement>('d');
const ln = byId('ln');
const st = byId('st');
const lines = (): void => {
  const n = Math.max(6, d.value.split('\n').length);
  ln.textContent = Array.from({ length: n }, (_, i) => i + 1).join('\n');
};
const G = '#@!%&*$?{}<>/\\|';
const scramble = async (start: number, out: string): Promise<void> => {
  if (reduced) return;
  const keep = d.value.slice(0, start);
  for (let i = 0; i < 10; i++) {
    d.value =
      keep +
      [...out]
        .map((ch, k) => (ch === '\n' || ch === ' ' || k < (i * out.length) / 10 ? ch : G[(Math.random() * G.length) | 0]))
        .join('');
    await sleep(28);
  }
  d.value = keep + out;
};

bind(d, {
  onExpand: async (m: Snippet, out: string) => {
    headline(m.t);
    const start = d.value.length - out.length;
    d.classList.remove('glitch');
    void d.offsetWidth;
    d.classList.add('glitch');
    st.textContent = m.t + ' expanded. Backspace undoes it_';
    lines();
    await scramble(start, out);
    lines();
  },
  onInput: lines,
  onUndo: () => {
    st.textContent = "undone. Trigger's back_";
    lines();
  },
});
d.addEventListener('input', lines);
document.querySelectorAll<HTMLButtonElement>('.chip[data-t]').forEach((b) => {
  b.onclick = () => {
    if (d.value && !d.value.endsWith('\n')) d.value += '\n';
    typeInto(d, b.dataset.t ?? '');
  };
});
