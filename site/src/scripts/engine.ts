export interface Snippet {
  t: string;
  out: () => string;
  note: string;
}

export interface Match {
  t: string;
  out: () => string;
}

interface BindOptions {
  onExpand?: (m: Snippet, out: string, el: TextField) => void;
  onInput?: (value: string) => void;
  onUndo?: (el: TextField) => void;
}

interface SyntheticEvent extends Event {
  synthetic?: boolean;
}

export type TextField = HTMLInputElement | HTMLTextAreaElement;

export const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

export const today = (): string =>
  new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });

export const snips: Snippet[] = [
  { t: ';sig', out: () => 'Cheers,\nJordan Lee\nTyped once. Sent forever.', note: 'a signature' },
  { t: ';date', out: () => 'Today is ' + today() + '.', note: 'a live date variable' },
  { t: ';fwrds', out: () => 'F Wrds. #@!% typing the same $#!% twice.', note: 'a one-liner' },
  { t: ';omw', out: () => 'On my way! Be there in 10 minutes.', note: 'a quick reply' },
  { t: ';ty', out: () => 'Thank you so much! I really appreciate it.', note: 'manners' },
  { t: ';oops', out: () => 'Well, that went #@!%ing sideways. Let me fix it.', note: 'an apology' },
];

export const find = (s: string): Snippet | null => {
  let b: Snippet | null = null;
  for (const x of snips) {
    if (s.endsWith(x.t) && (!b || x.t.length > b.t.length)) b = x;
  }
  return b;
};

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export const fire = (el: TextField): void => {
  const e: SyntheticEvent = new Event('input', { bubbles: true });
  e.synthetic = true;
  el.dispatchEvent(e);
};

export const bind = (el: TextField, o: BindOptions = {}): void => {
  let last: { val: string; before: string; pos: number } | null = null;
  el.addEventListener('input', (e: SyntheticEvent) => {
    if (e.isTrusted || e.synthetic) {
      const v = el.value;
      const c = el.selectionStart ?? v.length;
      const head = v.slice(0, c);
      const m = find(head);
      if (m) {
        const out = m.out();
        const before = head.slice(0, head.length - m.t.length);
        el.value = before + out + v.slice(c);
        const p = (before + out).length;
        el.setSelectionRange(p, p);
        last = { val: el.value, before: before + m.t + v.slice(c), pos: (before + m.t).length };
        o.onExpand?.(m, out, el);
      } else last = null;
      o.onInput?.(el.value);
    }
  });
  el.addEventListener('keydown', (ev: Event) => {
    const e = ev as KeyboardEvent;
    if (e.key === 'Backspace' && last && el.value === last.val) {
      e.preventDefault();
      el.value = last.before;
      el.setSelectionRange(last.pos, last.pos);
      last = null;
      o.onUndo?.(el);
    }
  });
};

export const typeInto = async (el: TextField, str: string, gap = 55): Promise<void> => {
  el.focus({ preventScroll: true });
  for (const ch of str) {
    const c = el.selectionStart ?? el.value.length;
    el.value = el.value.slice(0, c) + ch + el.value.slice(c);
    el.setSelectionRange(c + 1, c + 1);
    fire(el);
    if (!reduced) await sleep(gap);
  }
};
