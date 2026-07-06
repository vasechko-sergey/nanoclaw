import { describe, it, expect } from 'vitest';
import { splitPrefixedLines } from './container-log-sink.js';

const P = '[svc:abc123]';

describe('splitPrefixedLines', () => {
  it('prefixes a single complete line and leaves no remainder', () => {
    expect(splitPrefixedLines(P, '', 'hello\n')).toEqual({ out: `${P} hello\n`, rest: '' });
  });

  it('holds an incomplete trailing line as rest, emits nothing', () => {
    expect(splitPrefixedLines(P, '', 'partial')).toEqual({ out: '', rest: 'partial' });
  });

  it('carries pending across chunks and completes the line', () => {
    expect(splitPrefixedLines(P, 'par', 'tial\ndone\n')).toEqual({
      out: `${P} partial\n${P} done\n`,
      rest: '',
    });
  });

  it('prefixes every complete line in a multi-line chunk', () => {
    expect(splitPrefixedLines(P, '', 'a\nb\nc\n')).toEqual({
      out: `${P} a\n${P} b\n${P} c\n`,
      rest: '',
    });
  });

  it('emits complete lines and keeps the trailing partial as rest', () => {
    expect(splitPrefixedLines(P, '', 'a\nb\npar')).toEqual({ out: `${P} a\n${P} b\n`, rest: 'par' });
  });

  it('skips blank lines (no bare-prefix noise)', () => {
    expect(splitPrefixedLines(P, '', 'a\n\nb\n')).toEqual({ out: `${P} a\n${P} b\n`, rest: '' });
  });

  it('a lone newline produces nothing', () => {
    expect(splitPrefixedLines(P, '', '\n')).toEqual({ out: '', rest: '' });
  });
});
