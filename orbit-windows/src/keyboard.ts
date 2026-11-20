export const keyActions = {
  quickConnect: ['快速连接', 'Ctrl+K'], commandPalette: ['命令面板', 'Ctrl+Shift+P'], settings: ['设置', 'Ctrl+,'],
  newTerminal: ['本地终端', 'Ctrl+Shift+T'], toggleSftp: ['文件管理', 'Ctrl+Alt+F'], findInTerminal: ['搜索终端', 'Ctrl+Shift+F'],
  clearScreen: ['清屏', 'Ctrl+Shift+L'], reconnect: ['重新连接', 'Ctrl+Shift+R'], splitHorizontal: ['左右分屏', 'Ctrl+Shift+D'],
  splitVertical: ['上下分屏', 'Ctrl+Alt+D'], closePane: ['关闭面板', 'Ctrl+Shift+W'], navPrevPane: ['上一个面板', 'Ctrl+Alt+ArrowLeft'],
  navNextPane: ['下一个面板', 'Ctrl+Alt+ArrowRight'], growPane: ['扩大面板', 'Ctrl+Shift+ArrowRight'], shrinkPane: ['缩小面板', 'Ctrl+Shift+ArrowLeft'],
} as const;
export type KeyAction = keyof typeof keyActions;
export function chord(event: Pick<KeyboardEvent, 'key' | 'ctrlKey' | 'shiftKey' | 'altKey' | 'metaKey'>) {
  if (['Control', 'Shift', 'Alt', 'Meta'].includes(event.key)) return '';
  const key = event.key.length === 1 ? event.key.toUpperCase() : event.key;
  return [event.ctrlKey && 'Ctrl', event.altKey && 'Alt', event.shiftKey && 'Shift', event.metaKey && 'Meta', key === ' ' ? 'Space' : key].filter(Boolean).join('+');
}
export function actionFor(event: KeyboardEvent, bindings: Record<string, string>): KeyAction | undefined {
  const pressed = chord(event).toLowerCase();
  return (Object.keys(keyActions) as KeyAction[]).find(action => (bindings[action] ?? keyActions[action][1]).toLowerCase() === pressed);
}
