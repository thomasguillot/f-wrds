const g = document.querySelector<HTMLElement>('.bento');

if (g) {
  const delays = [0, 50, 90, 140, 170, 210, 240, 280, 300, 330, 350, 370];
  g.querySelectorAll<HTMLElement>('.tile').forEach((t, i) => t.style.setProperty('--d', (delays[i] ?? 380) + 'ms'));
  const go = (): void => {
    g.classList.add('in');
  };
  if (!('IntersectionObserver' in window)) go();
  else {
    const io = new IntersectionObserver(
      (es) => {
        if (es.some((e) => e.isIntersecting)) {
          go();
          io.disconnect();
        }
      },
      { threshold: 0.12 },
    );
    io.observe(g);
  }
}
