import React, { useEffect, useRef, useState } from 'react';

export type PaletteAction = { id: string; name: string; detail?: string; disabled?: boolean; run: () => void };

export function CommandPalette({ actions, close }: { actions: PaletteAction[]; close: () => void }) {
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState(0);
  const list = useRef<HTMLDivElement>(null);
  const matches = actions.filter(action => `${action.name} ${action.detail || ''}`.toLowerCase().includes(query.trim().toLowerCase()));
  useEffect(() => { list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' }); }, [selected]);
  function run(index: number) { const action = matches[index]; if (action && !action.disabled) { close(); action.run(); } }
  return <div className="scrim" onMouseDown={event => { if (event.target === event.currentTarget) close(); }}><section className="dialog command-palette" role="dialog" aria-label="命令面板" onKeyDown={event => {
    if (event.key === 'Escape') { event.preventDefault(); close(); }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); setSelected(value => matches.length ? (value + (event.key === 'ArrowDown' ? 1 : matches.length - 1)) % matches.length : 0); }
    if (event.key === 'Enter') { event.preventDefault(); run(selected); }
  }}><div className="dialog-heading"><h2>命令面板</h2><button onClick={close}>关闭</button></div><input autoFocus role="combobox" aria-expanded="true" aria-controls="palette-results" aria-activedescendant={matches[selected] ? `palette-${matches[selected].id}` : undefined} aria-label="搜索命令和服务器" placeholder="搜索命令片段、操作或服务器…" value={query} onChange={event => { setQuery(event.target.value); setSelected(0); }} /><div ref={list} id="palette-results" role="listbox">{matches.map((action, index) => <button id={`palette-${action.id}`} key={action.id} role="option" aria-selected={index === selected} disabled={action.disabled} onMouseEnter={() => setSelected(index)} onClick={() => run(index)}><span>{action.name}<small>{action.detail}</small></span></button>)}{!matches.length && <p className="muted">没有匹配的命令</p>}</div><small className="muted">↑↓ 选择 · Enter 执行 · Esc 关闭</small></section></div>;
}
