import * as FX from './fx';

document.querySelectorAll<HTMLElement>('#tag .gx').forEach((g) => {
  FX.view(g, () => FX.scr(g, 800), 0.6);
  g.addEventListener('mouseenter', () => FX.scr(g, 480));
});

const slab = document.querySelector<HTMLElement>('.slab');
const button = slab?.querySelector<HTMLElement>('.btn');
const note = slab?.querySelector<HTMLElement>('.note-last');
const arrow = slab?.querySelector<SVGSVGElement>('.long-arrow');

const drawArrow = (): void => {
  if (!slab || !button || !note || !arrow) return;
  const s = slab.getBoundingClientRect();
  const b = button.getBoundingClientRect();
  const n = note.getBoundingClientRect();
  if (getComputedStyle(note).display === 'none') return;
  const tipX = b.right - s.left + 40;
  const tipY = b.top + b.height / 2 - s.top;
  const startX = n.right - s.left - n.width * 0.1;
  const startY = n.top - s.top - 4;
  const dx = startX - tipX;
  const dy = startY - tipY;
  arrow
    .querySelector('.shaft')
    ?.setAttribute('d', `M${startX} ${startY}C${startX + 6} ${startY - dy * 0.75} ${tipX + dx * 0.35} ${tipY} ${tipX} ${tipY}`);
  arrow.querySelector('.head')?.setAttribute('d', `M${tipX + 8} ${tipY - 6}L${tipX} ${tipY}l8 6`);
};

drawArrow();
addEventListener('resize', drawArrow);
document.fonts?.ready.then(drawArrow);
