export const gl = (el: HTMLElement): void => {
  el.classList.remove('gl');
  void el.offsetWidth;
  el.classList.add('gl');
};
