import { reduced } from './engine';

const G = '#@!%&*$?{}<>/|';

export const scr = (el: HTMLElement, ms = 560): void => {
  if (reduced) return;
  const t = el.dataset.t || (el.dataset.t = el.textContent ?? '');
  const n = 14;
  let i = 0;
  const id = setInterval(() => {
    i++;
    el.textContent = [...t].map((c, k) => (c === ' ' || k < (i * t.length) / n ? c : G[(Math.random() * G.length) | 0])).join('');
    if (i >= n) {
      clearInterval(id);
      el.textContent = t;
    }
  }, ms / n);
};

export const view = (el: HTMLElement, cb: (el: HTMLElement) => void, th = 0.35): void => {
  if (!('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver(
    (es) =>
      es.forEach((e) => {
        if (e.isIntersecting) {
          cb(e.target as HTMLElement);
          io.unobserve(e.target);
        }
      }),
    { threshold: th },
  );
  io.observe(el);
};

export const gl = (el: HTMLElement): void => {
  el.classList.remove('gl');
  void el.offsetWidth;
  el.classList.add('gl');
};
