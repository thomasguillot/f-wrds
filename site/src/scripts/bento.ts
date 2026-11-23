import { byId } from './dom';
import { typeInto } from './engine';
import * as FX from './fx';

const clk = byId('clk');
const clock = (): void => {
  const d = new Date();
  clk.innerHTML =
    'It is <em>' +
    d.toLocaleTimeString('en-US') +
    '</em> on ' +
    d.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' }) +
    '.';
};
clock();
setInterval(clock, 1000);

const cs = byId<HTMLInputElement>('cs');
const csst = byId('csst');
const OMW = 'on my way! Be there in 10 minutes.';
const caseOut = (t: string): string =>
  t === t.toUpperCase() ? OMW.toUpperCase() : t[0] === t[0].toUpperCase() ? OMW[0].toUpperCase() + OMW.slice(1) : OMW;
cs.addEventListener('input', () => {
  const m = cs.value.match(/;(omw)$/i);
  if (!m) return;
  const trig = m[1];
  cs.value = cs.value.slice(0, -4) + caseOut(trig);
  csst.textContent =
    ';' + trig + (trig === trig.toUpperCase() ? ' in capitals' : trig[0] === trig[0].toUpperCase() ? ' with a capital' : ' in lowercase') + '_';
  FX.gl(cs);
});
document.querySelectorAll<HTMLButtonElement>('[data-c]').forEach((b) => {
  b.onclick = () => {
    cs.value = '';
    typeInto(cs, b.dataset.c ?? '');
  };
});

const mbs = byId('mbs');
const mb = byId('mb');
const mbt = byId('mbt');
mbs.onclick = () => {
  const on = mbs.getAttribute('aria-checked') !== 'true';
  mbs.setAttribute('aria-checked', String(on));
  mb.classList.toggle('off', on);
  mbt.textContent = on ? 'Paused in Mail' : 'Expanding in Mail';
};

const kb = byId('kb');
const tk = byId('tk');
kb.onclick = () => {
  const shut = tk.classList.toggle('shut');
  kb.setAttribute('aria-expanded', String(!shut));
  kb.classList.add('on');
  setTimeout(() => kb.classList.remove('on'), 140);
};

const AP = ['Mail', 'Notes', 'Slack', 'Terminal', 'Safari'];
const sel = new Set(['Mail', 'Notes']);
let mode = 'only';
const apps = byId('apps');
const rd = (): void => {
  apps.innerHTML = '';
  AP.forEach((a) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'app';
    const inn = sel.has(a);
    const ok = mode === 'only' ? inn : !inn;
    b.setAttribute('aria-pressed', String(inn));
    b.classList.toggle('ok', ok);
    b.innerHTML = '<span></span><small></small>';
    b.children[0].textContent = a;
    b.children[1].textContent = ok ? 'expands' : 'skipped';
    b.onclick = () => {
      if (sel.has(a)) sel.delete(a);
      else sel.add(a);
      rd();
      apps.querySelectorAll<HTMLElement>('.app')[AP.indexOf(a)].focus();
    };
    apps.appendChild(b);
  });
};
document.querySelectorAll<HTMLInputElement>('[name=mode]').forEach((r) => {
  r.onchange = () => {
    mode = r.value;
    rd();
  };
});
rd();
