export type Pane = string | { id: string; vertical: boolean; ratio: number; first: Pane; second: Pane };
export type Rect = { left: number; top: number; width: number; height: number };
export function leaves(node: Pane): string[] { return typeof node === 'string' ? [node] : [...leaves(node.first), ...leaves(node.second)]; }
export function splitPane(node: Pane, target: string, next: string, vertical: boolean): Pane {
  if (typeof node === 'string') return node === target ? { id: crypto.randomUUID(), vertical, ratio: 50, first: node, second: next } : node;
  return { ...node, first: splitPane(node.first, target, next, vertical), second: splitPane(node.second, target, next, vertical) };
}
export function removePane(node: Pane, target: string): Pane | null {
  if (typeof node === 'string') return node === target ? null : node;
  const first = removePane(node.first, target), second = removePane(node.second, target);
  return first && second ? { ...node, first, second } : first || second;
}
export function resizePane(node: Pane, id: string, ratio: number): Pane {
  if (typeof node === 'string') return node;
  return node.id === id ? { ...node, ratio: Math.min(90, Math.max(10, ratio)) } : { ...node, first: resizePane(node.first, id, ratio), second: resizePane(node.second, id, ratio) };
}
export function layout(node: Pane, rect: Rect = { left: 0, top: 0, width: 100, height: 100 }): { panes: { id: string; rect: Rect }[]; dividers: { node: Exclude<Pane, string>; rect: Rect }[] } {
  if (typeof node === 'string') return { panes: [{ id: node, rect }], dividers: [] };
  const a = { ...rect }, b = { ...rect };
  if (node.vertical) { a.height *= node.ratio / 100; b.top += a.height; b.height -= a.height; }
  else { a.width *= node.ratio / 100; b.left += a.width; b.width -= a.width; }
  const first = layout(node.first, a), second = layout(node.second, b);
  return { panes: [...first.panes, ...second.panes], dividers: [{ node, rect }, ...first.dividers, ...second.dividers] };
}
