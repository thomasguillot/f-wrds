import { byId } from './dom';

const tabs = [...document.querySelectorAll<HTMLElement>('.tab')];
const panes = ['pn1', 'pn2', 'pn3'].map((id) => byId(id));
const go = (i: number): void => {
  tabs.forEach((t, k) => {
    t.setAttribute('aria-selected', String(k === i));
    t.tabIndex = k === i ? 0 : -1;
    panes[k].hidden = k !== i;
  });
};
const step: Record<string, number> = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
const jump: Record<string, number> = { Home: 0, End: 2 };
tabs.forEach((t, i) => {
  t.onclick = () => go(i);
  t.onkeydown = (e: KeyboardEvent) => {
    const k = step[e.key];
    const j = jump[e.key];
    if (k || j !== undefined) {
      e.preventDefault();
      const n = j ?? (i + k + 3) % 3;
      go(n);
      tabs[n].focus();
    }
  };
});
