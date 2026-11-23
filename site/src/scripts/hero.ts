import { byId } from './dom';
import { bind, reduced, sleep, typeInto, type Snippet } from './engine';

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
