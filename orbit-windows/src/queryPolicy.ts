export function autoLimit(sql: string, limit: number, enabled: boolean): string {
  if (!enabled || limit < 1 || !/^select\s/i.test(sql.trim())) return sql;
  const tokens: string[] = [];
  let depth = 0, index = 0, end = sql.length;
  while (index < sql.length) {
    const rest = sql.slice(index), character = sql[index];
    if (/^\s/.test(character)) { index++; continue; }
    if (rest.startsWith('--') || rest.startsWith('#')) { const newline = sql.indexOf('\n', index); index = newline < 0 ? sql.length : newline + 1; continue; }
    if (rest.startsWith('/*')) { const close = sql.indexOf('*/', index + 2); if (close < 0) return sql; index = close + 2; continue; }
    if (end !== sql.length && character !== ';') return sql;
    const dollar = rest.match(/^\$(?:[a-zA-Z_][a-zA-Z0-9_]*)?\$/)?.[0];
    if (dollar) { const close = sql.indexOf(dollar, index + dollar.length); if (close < 0) return sql; index = close + dollar.length; continue; }
    if (['\'', '"', '`', '['].includes(character)) {
      const quote = character === '[' ? ']' : character; let closed = false; index++;
      while (index < sql.length) {
        if (sql[index] === '\\') { index += 2; continue; }
        if (sql[index++] === quote) { if (sql[index] === quote) index++; else { closed = true; break; } }
      }
      if (!closed) return sql;
      continue;
    }
    if (character === '(') depth++;
    else if (character === ')') { if (--depth < 0) return sql; }
    else if (depth === 0 && character === ';') { if (end === sql.length) end = index; }
    else {
      const word = rest.match(/^[a-zA-Z_][a-zA-Z0-9_]*/)?.[0];
      if (end !== sql.length) return sql;
      if (word) { if (!depth) tokens.push(word.toLowerCase()); index += word.length; continue; }
    }
    index++;
  }
  if (depth || tokens.some(token => ['limit', 'into', 'fetch'].includes(token)) || tokens.some((token, index) => token === 'for' && ['update', 'share'].includes(tokens[index + 1]))) return sql;
  return `${sql.slice(0, end).trimEnd()}\nLIMIT ${Math.floor(limit)}`;
}

export function tableQuery(name: string, engine: string, limit: number): string {
  const quote = engine === 'mysql' ? '`' : '"';
  const identifier = quote + name.replaceAll(quote, quote + quote) + quote;
  return `SELECT * FROM ${identifier}\nLIMIT ${Math.max(1, Math.floor(limit))}`;
}
