import * as FX from './fx';

document.querySelectorAll<HTMLElement>('#tag .gx').forEach((g) => {
  FX.view(g, () => FX.scr(g, 800), 0.6);
  g.addEventListener('mouseenter', () => FX.scr(g, 480));
});
