import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  await page.route('http://127.0.0.1:1420/', route => route.fulfill({ contentType: 'text/html; charset=utf-8', body: `
    <html><head><meta charset="UTF-8"></head><body><div id="root"></div><script type="module">
    import RefreshRuntime from '/@react-refresh';
    RefreshRuntime.injectIntoGlobalHook(window);
    window.$RefreshReg$ = () => {};
    window.$RefreshSig$ = () => (type) => type;
    window.__vite_plugin_react_preamble_installed__ = true;
    import { mockIPC } from '/node_modules/@tauri-apps/api/mocks.js';
    import { emit } from '/node_modules/@tauri-apps/api/event.js';
    window.calls = [];
    let inventory = [{id:'server-1',name:'开发服务器',host:'10.0.0.10',port:22,username:'dev',auth_type:'password',jump_server_id:''}];
    window.hostKey = () => emit('host-key', {id:'key-1',host:'10.0.0.10',port:22,role:'target',algorithm:'Ed25519',fingerprint:'SHA256:test-fingerprint',previous_fingerprint:null});
    mockIPC(async (command,args) => {
      window.calls.push({command,args:JSON.parse(JSON.stringify(args ?? {}))});
      if(command === 'servers') return inventory;
      if(command === 'ai_config') return {endpoint:'https://model.example.test/v1',model:'test-model',has_key:true};
      if(command === 'ai_chat') { const fence=String.fromCharCode(96).repeat(3); const result='建议命令：\\n'+fence+'execute\\nwhoami\\n'+fence; args.output.onmessage(result); return result; }
      if(command === 'request') {
        if(args.action === 'database.list') return [{id:'db-1',name:'测试数据库',engine:'mysql',host:'localhost',port:3306,username:'test',database_name:'test'}];
        if(args.action === 'database.history') return [];
        if(args.action === 'database.query') return {columns:['value'],rows:[['中文结果']],affected_rows:0,elapsed_ms:2,message:'OK'};
        if(args.action === 'sftp.read') return 'original file content';
        if(args.action === 'exec') return 'test-user';
      }
      if(command === 'add_server') { inventory.push({...args.input,id:'server-2'}); return 'server-2'; }
      if(command === 'connect') {
        args.output.onmessage({kind:'data',bytes:Array.from(new TextEncoder().encode('Welcome to Orbit\\r\\n中文终端已就绪\\r\\n$ '))});
        return args.token;
      }
      if(command === 'files') return [{name:'projects',path:'/home/dev/projects',is_dir:true,size:0,permissions:'755'}];
      return null;
    }, {shouldMockEvents:true});
    await import('/src/main.tsx');
    </script></body></html>` }));
  await page.goto('/');
});

test('connection lifecycle keeps inactive sessions and releases closed tabs', async ({ page }) => {
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await expect(page.getByText('已连接', { exact: true })).toBeVisible();
  await expect.poll(() => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'acknowledge').length)).toBeGreaterThan(0);
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await expect(page.getByRole('tab')).toHaveCount(2);
  await page.getByRole('tab').first().click();
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'connect').length)).toBe(2);
  await page.getByRole('button', { name: '关闭 开发服务器' }).first().click();
  await expect(page.getByRole('tab')).toHaveCount(1);
  await expect.poll(() => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'disconnect').length)).toBe(1);
  await page.screenshot({ path: '/tmp/orbit-windows-terminal.png' });
});

test('server creation persists through the backend and exposes validation', async ({ page }) => {
  await page.getByLabel('新增', { exact: true }).click();
  await page.locator('.new-menu').getByRole('button', { name: '添加服务器', exact: true }).click();
  await page.getByLabel('名称', { exact: true }).fill('测试主机');
  await page.getByLabel('主机地址').fill('10.0.0.20');
  await page.getByLabel('用户名', { exact: true }).fill('test');
  await page.getByLabel('密码', { exact: true }).fill('test-only');
  await page.getByRole('button', { name: '保存服务器' }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('button', { name: '测试主机 test@10.0.0.20' })).toBeVisible();
});

test('host trust requires explicit action and file panel lists remote data', async ({ page }) => {
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await page.evaluate(() => (window as any).hostKey());
  await expect(page.getByRole('dialog')).toContainText('SHA256:test-fingerprint');
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'resolve_host_key').length)).toBe(0);
  await page.getByRole('button', { name: '拒绝', exact: true }).click();
  const call = await page.evaluate(() => (window as any).calls.find((call: any) => call.command === 'resolve_host_key'));
  expect(call.args.trust).toBe(false);
  await page.getByRole('button', { name: '文件', exact: true }).click();
  await expect(page.getByRole('button', { name: '▸ projects 目录' })).toBeVisible();
});

test('directory loading cannot overwrite a path being edited', async ({ page }) => {
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__;
    const original = internals.invoke;
    internals.invoke = (command: string, args: unknown, options: unknown) => command === 'files'
      ? new Promise(resolve => { (window as any).releaseFiles = () => { internals.invoke = original; resolve(original(command, args, options)); }; })
      : original(command, args, options);
  });
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await page.getByRole('button', { name: '文件', exact: true }).click();
  await expect(page.getByLabel('远程目录')).toBeDisabled();
  await page.evaluate(() => (window as any).releaseFiles());
  await expect(page.getByLabel('远程目录')).toBeEnabled();
  await page.getByLabel('远程目录').fill('/projects');
  await page.getByRole('button', { name: '前往', exact: true }).click();
  await expect.poll(() => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'files').at(-1).args.path)).toBe('/projects');
});

test('local terminal, split panes, search and settings preserve live sessions', async ({ page }) => {
  await page.getByRole('button', { name: '本地终端', exact: true }).click();
  await expect(page.getByRole('tab', { name: 'PowerShell' })).toBeVisible();
  const call = await page.evaluate(() => (window as any).calls.find((call: any) => call.command === 'connect'));
  expect(call.args.serverId).toBe('__local__');
  await page.getByLabel('工作区操作').click();
  await page.getByRole('button', { name: '左右分屏' }).click();
  await page.getByLabel('工作区操作').click();
  await expect(page.locator('.terminal-pane.active')).toHaveCount(2);
  await page.getByRole('separator', { name: '调整分屏' }).press('ArrowRight');
  await expect(page.getByRole('separator', { name: '调整分屏' })).toHaveAttribute('aria-valuenow', '55');
  await page.getByRole('button', { name: '搜索', exact: true }).first().click();
  await page.getByLabel('搜索终端文本').fill('Orbit');
  await page.getByRole('button', { name: '设置', exact: true }).click();
  await page.getByLabel('终端主题').selectOption('nord');
  await page.getByRole('button', { name: '保存设置' }).click();
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('orbit-settings')!).theme)).toBe('nord');
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'connect').length)).toBe(2);
  await page.getByRole('button', { name: '合并视图' }).click();
  await expect(page.locator('.terminal-pane.active')).toHaveCount(1);
});

test('server editing sends null secrets so stored credentials are retained', async ({ page }) => {
  await page.getByRole('button', { name: '资产与凭据管理' }).click();
  await page.getByLabel('管理服务器').selectOption('server-1');
  await page.getByRole('button', { name: '编辑连接' }).click();
  await page.getByLabel('名称', { exact: true }).fill('改名服务器');
  await page.getByRole('button', { name: '保存服务器' }).click();
  const call = await page.evaluate(() => (window as any).calls.find((call: any) => call.command === 'request' && call.args.action === 'server.update'));
  expect(call.args.args.input.password).toBeNull();
  expect(call.args.args.input.name).toBe('改名服务器');
});

test('temporary connections do not persist assets before explicit save', async ({ page }) => {
  await page.getByLabel('新增', { exact: true }).click();
  await page.getByRole('button', { name: '临时连接', exact: true }).click();
  await page.getByLabel('名称', { exact: true }).fill('临时主机');
  await page.getByLabel('主机地址').fill('10.0.0.30');
  await page.getByLabel('用户名', { exact: true }).fill('tester');
  await page.getByLabel('密码', { exact: true }).fill('temporary-test');
  await page.getByRole('dialog').getByRole('button', { name: '临时连接', exact: true }).click();
  await expect(page.getByRole('tab', { name: '临时主机' })).toBeVisible();
  const calls = await page.evaluate(() => (window as any).calls);
  expect(calls.some((call: any) => call.command === 'add_server')).toBe(false);
  expect(calls.find((call: any) => call.command === 'connect').args.temporary.password).toBe('temporary-test');
  await page.getByRole('button', { name: '关闭 临时主机' }).click();
  await expect(page.getByRole('tab')).toHaveCount(0);
});

test('database writes require confirmation while read-only queries return rows', async ({ page }) => {
  await page.getByRole('button', { name: '管理数据库', exact: true }).click();
  await page.locator('.database-panel:visible').getByLabel('数据库连接', { exact: true }).selectOption('db-1');
  await page.locator('.database-panel:visible').getByLabel('SQL', { exact: true }).fill('SELECT 1');
  await page.getByRole('button', { name: '执行 SQL' }).click();
  await expect(page.getByRole('cell', { name: '中文结果' })).toBeVisible();
  let calls = await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'request' && call.args.action === 'database.query'));
  expect(calls[0].args.args.input.read_only).toBe(true);
  await page.locator('.database-panel:visible').getByLabel('只读模式').uncheck();
  await page.locator('.database-panel:visible').getByLabel('SQL', { exact: true }).fill('DELETE FROM test');
  page.once('dialog', dialog => dialog.dismiss());
  await page.getByRole('button', { name: '执行 SQL' }).click();
  calls = await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'request' && call.args.action === 'database.query'));
  expect(calls).toHaveLength(1);
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: '执行 SQL' }).click();
  await expect.poll(() => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'request' && call.args.action === 'database.query').length)).toBe(2);
});

test('AI suggestions cannot execute without server selection and confirmation', async ({ page }) => {
  await page.getByRole('button', { name: 'AI', exact: true }).click();
  await page.getByLabel('AI 服务器上下文').selectOption('server-1');
  await page.getByLabel('Agent 模式（执行前确认）').check();
  await page.getByLabel('AI 消息').fill('查询当前用户');
  await page.getByRole('button', { name: '发送', exact: true }).click();
  await expect(page.getByRole('button', { name: '确认执行并继续' })).toBeVisible();
  const executions = () => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'request' && call.args.action === 'exec').length);
  expect(await executions()).toBe(0);
  page.once('dialog', dialog => dialog.dismiss());
  await page.getByRole('button', { name: '确认执行并继续' }).click();
  expect(await executions()).toBe(0);
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: '确认执行并继续' }).click();
  await expect.poll(executions).toBe(1);
  await expect(page.getByRole('button', { name: '确认执行并继续' })).toBeVisible();
  expect(await executions()).toBe(1);
});


test('workspace matches native layout and quick connection retains sessions', async ({ page }) => {
  const toolbar = await page.locator('.global-toolbar').boundingBox();
  const sidebar = await page.locator('.sidebar').boundingBox();
  const dock = await page.getByLabel('会话工具').boundingBox();
  expect(toolbar?.height).toBe(40);
  expect(sidebar?.width).toBe(245);
  expect(sidebar?.y).toBe(40);
  expect(dock?.width).toBe(52);
  expect(dock?.x).toBe(1228);
  await expect(page.locator('.tabbar').getByRole('button', { name: '数据库' })).toHaveCount(0);
  await page.getByLabel('快速连接').fill('开发');
  await page.locator('.quick-results').getByRole('button', { name: /开发服务器/ }).click();
  await expect(page.getByRole('tab', { name: '开发服务器' })).toBeVisible();
  await page.getByRole('button', { name: '文件', exact: true }).click();
  await expect(page.getByRole('button', { name: '关闭文件面板' })).toBeVisible();
  await page.getByRole('button', { name: '关闭文件面板' }).click();
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'connect').length)).toBe(1);
});


test('quick address entry opens temporary connection and settings use native categories', async ({ page }) => {
  await page.getByLabel('快速连接').fill('dev@example.test:2222');
  await page.getByLabel('快速连接').press('Enter');
  await expect(page.getByLabel('主机地址')).toHaveValue('example.test');
  await expect(page.getByLabel('端口', { exact: true })).toHaveValue('2222');
  await expect(page.getByLabel('用户名', { exact: true })).toHaveValue('dev');
  await page.getByRole('button', { name: '取消', exact: true }).click();
  await page.getByRole('button', { name: '设置', exact: true }).click();
  await expect(page.getByRole('button', { name: '选择主题 nord', exact: true })).toBeVisible();
  await page.getByRole('button', { name: '终端', exact: true }).click();
  await expect(page.getByLabel('终端字体')).toBeVisible();
  await expect(page.getByLabel('终端主题')).not.toBeVisible();
  await page.getByRole('button', { name: '连接', exact: true }).click();
  await expect(page.getByLabel('连接超时（秒）')).toBeVisible();
  await page.getByRole('button', { name: '关闭', exact: true }).click();
  await page.screenshot({ path: '/tmp/orbit-windows-home-aligned.png' });
});

test('nested split layout belongs to its tab and closes only the focused pane', async ({ page }) => {
  await page.getByRole('button', { name: '本地终端', exact: true }).click();
  await page.keyboard.press('Control+Shift+D');
  await page.keyboard.press('Control+Alt+D');
  await expect(page.locator('.terminal-pane.active')).toHaveCount(3);
  await expect(page.getByRole('tab')).toHaveCount(1);
  await expect(page.getByRole('separator')).toHaveCount(2);
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await expect(page.locator('.terminal-pane.active')).toHaveCount(1);
  await page.getByRole('tab', { name: 'PowerShell' }).click();
  await expect(page.locator('.terminal-pane.active')).toHaveCount(3);
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'connect').length)).toBe(4);
  await page.keyboard.press('Control+Shift+W');
  await expect(page.locator('.terminal-pane.active')).toHaveCount(2);
  await expect.poll(() => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'disconnect').length)).toBe(1);
});

test('AI sessions survive closing the drawer and stay separate between terminal tabs', async ({ page }) => {
  await page.getByRole('button', { name: '本地终端', exact: true }).click();
  await page.getByRole('button', { name: 'AI', exact: true }).click();
  await page.getByLabel('AI 消息').fill('保留这条对话');
  await page.getByRole('button', { name: '发送', exact: true }).click();
  await expect(page.locator('.chat-message.user')).toContainText('保留这条对话');
  await page.getByRole('button', { name: '关闭', exact: true }).click();
  await page.getByRole('button', { name: 'AI', exact: true }).click();
  await expect(page.locator('.chat-message.user')).toContainText('保留这条对话');
  await page.getByRole('button', { name: '新对话', exact: true }).click();
  await expect(page.locator('.chat-message')).toHaveCount(0);
  await page.getByLabel('AI 会话').selectOption({ label: '保留这条对话' });
  await expect(page.locator('.chat-message.user')).toContainText('保留这条对话');
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await page.getByRole('button', { name: 'AI', exact: true }).click();
  await expect(page.locator('.ai-panel:visible .chat-message')).toHaveCount(0);
  await page.getByRole('tab', { name: 'PowerShell' }).click();
  await expect(page.locator('.ai-panel:visible .chat-message.user')).toContainText('保留这条对话');
});

test('database query and results survive returning to the terminal', async ({ page }) => {
  await page.getByRole('button', { name: '管理数据库', exact: true }).click();
  await page.locator('.database-panel:visible').getByLabel('数据库连接', { exact: true }).selectOption('db-1');
  await page.locator('.database-panel:visible').getByLabel('SQL', { exact: true }).fill('SELECT 1');
  await page.getByRole('button', { name: '执行 SQL' }).click();
  await expect(page.getByRole('cell', { name: '中文结果' })).toBeVisible();
  const call = await page.evaluate(() => (window as any).calls.find((call: any) => call.command === 'request' && call.args.action === 'database.query'));
  expect(call.args.args.input.sql).toBe('SELECT 1\nLIMIT 200');
  await page.getByRole('button', { name: '返回终端', exact: true }).click();
  await page.getByRole('tab', { name: '测试数据库', exact: true }).click();
  await expect(page.locator('.database-panel:visible').getByLabel('SQL', { exact: true })).toHaveValue('SELECT 1');
  await expect(page.getByRole('cell', { name: '中文结果' })).toBeVisible();
  await page.screenshot({ path: '/tmp/orbit-windows-database-aligned.png' });
});

test('auto limit preserves quoted tokens, nested selects and write statement boundaries', async ({ page }) => {
  const values = await page.evaluate(async () => {
    const { autoLimit } = await import('/src/queryPolicy.ts' as string);
    return [
      autoLimit("SELECT 'limit', (SELECT 1 LIMIT 1)", 20, true),
      autoLimit('SELECT * FROM t LIMIT 5', 20, true),
      autoLimit('SELECT * FROM t FOR UPDATE', 20, true),
      autoLimit('SELECT 1; DELETE FROM t', 20, true),
      autoLimit('SELECT 1 -- limit', 20, true),
      autoLimit('SELECT 1; -- note', 20, true),
      autoLimit('SELECT $$limit;$$', 20, true),
      autoLimit('SELECT 1', 20, false),
    ];
  });
  expect(values).toEqual(["SELECT 'limit', (SELECT 1 LIMIT 1)\nLIMIT 20", 'SELECT * FROM t LIMIT 5', 'SELECT * FROM t FOR UPDATE', 'SELECT 1; DELETE FROM t', 'SELECT 1 -- limit\nLIMIT 20', 'SELECT 1\nLIMIT 20', 'SELECT $$limit;$$\nLIMIT 20', 'SELECT 1']);
});

test('batch cancellation stops active jobs and never starts queued hosts', async ({ page }) => {
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__, original = internals.invoke;
    let cancelled = false;
    internals.invoke = async (command: string, args: any, options: unknown) => {
      if (command === 'command_start') { (window as any).batchStarted = ((window as any).batchStarted || 0) + 1; return 'job-1'; }
      if (command === 'command_cancel') { cancelled = true; return; }
      if (command === 'command_poll') return { status: { status: cancelled ? 'cancelled' : 'running', exitCode: null }, output: { chunk: '', nextCursor: 0 } };
      if (command === 'command_release') { (window as any).batchReleased = true; return; }
      return original(command, args, options);
    };
  });
  await page.getByLabel('新增', { exact: true }).click();
  await page.locator('.new-menu').getByRole('button', { name: '添加服务器', exact: true }).click();
  await page.getByLabel('名称', { exact: true }).fill('第二台');
  await page.getByLabel('主机地址').fill('10.0.0.20');
  await page.getByLabel('用户名', { exact: true }).fill('test');
  await page.getByLabel('密码', { exact: true }).fill('test-only');
  await page.getByRole('button', { name: '保存服务器' }).click();
  await page.getByLabel('工作区操作').click();
  await page.getByRole('button', { name: '批量执行', exact: true }).click();
  await page.getByLabel('工作区操作').click();
  await page.getByRole('button', { name: '全选', exact: true }).click();
  await page.getByLabel('最大并发').fill('1');
  await page.getByLabel('批量命令').fill('sleep 10');
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: '确认并执行' }).click();
  await expect.poll(() => page.evaluate(() => (window as any).batchStarted)).toBe(1);
  await page.getByRole('button', { name: '取消执行' }).click();
  await expect(page.getByRole('heading', { name: '第二台 · 已取消' })).toBeVisible();
  expect(await page.evaluate(() => (window as any).batchStarted)).toBe(1);
  expect(await page.evaluate(() => (window as any).batchReleased)).toBe(true);
});

test('SFTP uploads queue multiple files and continue when the drawer is hidden', async ({ page }) => {
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__, original = internals.invoke;
    let count = 0;
    (window as any).transfers = [];
    internals.invoke = async (command: string, args: any, options: unknown) => {
      if (command === 'plugin:dialog|open') return ['C:\\fixtures\\first.txt', 'C:\\fixtures\\second.txt'];
      if (command === 'reserve_transfer') return `transfer-${++count}`;
      if (command === 'transfer') return new Promise(resolve => { (window as any).transfers.push(args.request); (window as any).finishTransfer = () => resolve(null); });
      return original(command, args, options);
    };
  });
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await page.getByRole('button', { name: '文件', exact: true }).click();
  await page.getByRole('button', { name: '上传文件', exact: true }).click();
  await expect.poll(() => page.evaluate(() => (window as any).transfers.length)).toBe(1);
  await expect(page.locator('.transfer-queue')).toContainText('second.txt');
  await page.getByRole('button', { name: '关闭文件面板' }).click();
  await page.evaluate(() => (window as any).finishTransfer());
  await expect.poll(() => page.evaluate(() => (window as any).transfers.length)).toBe(2);
  await page.evaluate(() => (window as any).finishTransfer());
  await page.getByRole('button', { name: '文件', exact: true }).click();
  await expect(page.locator('.transfer-queue summary')).toHaveText('传输队列 · 2/2');
  expect(await page.evaluate(() => (window as any).transfers.map((item: any) => item.remote_path))).toEqual(['./first.txt', './second.txt']);
});

test('database tabs retain independent SQL without rerunning queries', async ({ page }) => {
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__, original = internals.invoke;
    internals.invoke = async (command: string, args: any, options: unknown) => {
      if (command === 'request' && args.action === 'database.list') return [{ id: 'db-1', name: '第一库', engine: 'mysql', database_name: 'first' }, { id: 'db-2', name: '第二库', engine: 'postgres' }];
      return original(command, args, options);
    };
  });
  await page.getByRole('button', { name: '管理数据库', exact: true }).click();
  await page.locator('.database-panel:visible').getByLabel('数据库连接', { exact: true }).selectOption('db-1');
  await page.locator('.database-panel:visible').getByLabel('SQL', { exact: true }).fill('SELECT 111');
  await page.getByRole('button', { name: '执行 SQL' }).click();
  await expect(page.getByRole('cell', { name: '中文结果' })).toBeVisible();
  await page.locator('.database-panel:visible').getByLabel('数据库连接', { exact: true }).selectOption('db-2');
  await expect(page.getByRole('tab')).toHaveCount(2);
  await expect(page.locator('.database-panel:visible').getByLabel('SQL', { exact: true })).toHaveValue('');
  await page.locator('.database-panel:visible').getByLabel('SQL', { exact: true }).fill('SELECT 222');
  await page.getByRole('tab', { name: '第一库' }).click();
  await expect(page.locator('.database-panel:visible').getByLabel('SQL', { exact: true })).toHaveValue('SELECT 111');
  await expect(page.getByRole('cell', { name: '中文结果' })).toBeVisible();
  await page.getByRole('tab', { name: '第二库' }).click();
  await expect(page.locator('.database-panel:visible').getByLabel('SQL', { exact: true })).toHaveValue('SELECT 222');
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'request' && call.args.action === 'database.query').length)).toBe(1);
});

test('custom shortcuts are saved and control the workspace', async ({ page }) => {
  await page.getByRole('button', { name: '设置', exact: true }).click();
  await page.getByRole('button', { name: '快捷键', exact: true }).click();
  await page.getByLabel('本地终端快捷键').press('Control+Alt+N');
  await page.getByRole('button', { name: '保存设置' }).click();
  await page.keyboard.press('Control+Alt+N');
  await expect(page.getByRole('tab', { name: 'PowerShell' })).toBeVisible();
});


test('MySQL instance switches databases and table clicks fetch 200 rows read-only', async ({ page }) => {
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__;
    const original = internals.invoke;
    internals.invoke = (command: string, args: any, options: unknown) => {
      if (command === 'request' && args.action === 'database.list') return [{ id: 'instance', name: 'MySQL 实例', engine: 'mysql', database_name: '' }];
      if (command === 'request' && args.action === 'database.catalogs') return ['first', 'second'];
      if (command === 'request' && ['database.schema', 'database.backup'].includes(args.action)) {
        (window as any).calls.push({command, args});
        return args.action === 'database.schema' ? { tables: [{ name: args.args.database_name + '_table', columns: [] }] } : { message: '备份完成', warnings: [] };
      }
      return original(command, args, options);
    };
  });
  await page.getByRole('button', { name: '管理数据库', exact: true }).click();
  let panel = page.locator('.database-panel:visible');
  await panel.getByLabel('数据库连接', { exact: true }).selectOption('instance');
  await expect(panel.getByRole('button', { name: '执行 SQL' })).toBeDisabled();
  await panel.getByLabel('当前数据库').selectOption('first');
  await panel.getByLabel('SQL', { exact: true }).fill('SELECT custom_draft');
  await panel.locator('summary').filter({ hasText: 'first_table' }).click();
  await expect(panel.getByText('中文结果', { exact: true })).toBeVisible();
  const query = await page.evaluate(() => (window as any).calls.filter((call: any) => call.args?.action === 'database.query').at(-1));
  expect(query.args.args.database_name).toBe('first');
  expect(query.args.args.input.sql).toBe('SELECT * FROM `first_table`\nLIMIT 200');
  expect(query.args.args.input.read_only).toBe(true);
  await panel.getByRole('button', { name: 'SQL 查询', exact: true }).click();
  await expect(panel.getByLabel('SQL', { exact: true })).toHaveValue('SELECT custom_draft');
  await panel.getByLabel('当前数据库').selectOption('second');
  await expect(panel.getByText('中文结果', { exact: true })).toHaveCount(0);
  await expect(panel.getByLabel('SQL', { exact: true })).toHaveValue('');
  await expect(panel.locator('summary').filter({ hasText: 'second_table' })).toBeVisible();
  await panel.getByRole('button', { name: '加载结构', exact: true }).click();
  await panel.getByRole('button', { name: '备份数据库', exact: true }).click();
  for (const action of ['database.schema', 'database.backup']) {
    const call = await page.evaluate(action => (window as any).calls.filter((call: any) => call.args?.action === action).at(-1), action);
    expect(call.args.args.database_name).toBe('second');
  }
  await panel.getByLabel('当前数据库').selectOption('first');
  await expect(panel.getByLabel('SQL', { exact: true })).toHaveValue('SELECT custom_draft');
});

test('MySQL database is optional in connection form and fixed connections have no switcher', async ({ page }) => {
  await page.getByRole('button', { name: '管理数据库', exact: true }).click();
  const panel = page.locator('.database-panel:visible');
  await panel.getByRole('button', { name: '添加数据库', exact: true }).click();
  await page.getByLabel('引擎').selectOption('mysql');
  await expect(page.locator('input[name="database_name"]')).not.toHaveAttribute('required');
  await page.getByLabel('引擎').selectOption('postgres');
  await expect(page.locator('input[name="database_name"]')).toHaveAttribute('required');
  await page.getByRole('button', { name: '取消', exact: true }).click();
  await panel.getByLabel('数据库连接', { exact: true }).selectOption('db-1');
  await expect(panel.getByText('数据库：test（固定）')).toBeVisible();
  await expect(panel.getByLabel('当前数据库')).toHaveCount(0);
});

test('command palette supports keyboard navigation and inserts snippets without executing', async ({ page }) => {
  await page.getByRole('button', { name: '本地终端', exact: true }).click();
  await page.evaluate(() => localStorage.setItem('orbit-snippets', JSON.stringify([{ id: 'example', name: '查看身份', group: '诊断', command: 'whoami' }])));
  await page.getByRole('button', { name: 'Ctrl Shift P 命令面板' }).click();
  const search = page.getByRole('combobox', { name: '搜索命令和服务器' });
  await search.press('ArrowDown');
  await expect(page.getByRole('option').nth(1)).toHaveAttribute('aria-selected', 'true');
  await search.fill('查看身份');
  await search.press('Enter');
  await expect(page.getByRole('dialog', { name: '命令面板' })).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'terminal_write').length)).toBeGreaterThan(0);
  const text = await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'terminal_write').map((call: any) => new TextDecoder().decode(new Uint8Array(call.args.bytes))).join(''));
  expect(text).toBe('whoami');
});

test('asset context menu edits the selected server and prevents deleting active connections', async ({ page }) => {
  const server = page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' });
  await server.click({ button: 'right' });
  await page.getByRole('menuitem', { name: '编辑连接' }).click();
  await expect(page.getByLabel('名称', { exact: true })).toHaveValue('开发服务器');
  await page.getByRole('button', { name: '取消', exact: true }).click();
  await server.click();
  await server.click({ button: 'right' });
  await expect(page.getByRole('menuitem', { name: '删除服务器' })).toBeDisabled();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('menu')).toHaveCount(0);
});

test('native file drop only uploads inside the visible SFTP panel', async ({ page }) => {
  await page.evaluate(() => {
    const internals = (window as any).__TAURI_INTERNALS__, original = internals.invoke;
    internals.invoke = async (command: string, args: any, options: unknown) => {
      if (command === 'reserve_transfer') return 'drop-transfer';
      return original(command, args, options);
    };
  });
  await page.getByRole('button', { name: '开发服务器 dev@10.0.0.10' }).click();
  await page.getByRole('button', { name: '文件', exact: true }).click();
  await expect(page.getByLabel('远程目录')).toBeEnabled();
  const box = await page.locator('aside.files').boundingBox();
  const drop = async (x: number, y: number) => page.evaluate(async ({ x, y }) => {
    const { emit } = await import('/node_modules/@tauri-apps/api/event.js');
    await emit('tauri://drag-drop', { paths: ['C:\\fixtures\\拖放.txt'], position: { x: x * devicePixelRatio, y: y * devicePixelRatio } });
  }, { x, y });
  await drop(0, 0);
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'transfer').length)).toBe(0);
  await drop(box!.x + 20, box!.y + 20);
  await expect.poll(() => page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'transfer').length)).toBe(1);
  await page.getByRole('button', { name: '关闭文件面板' }).click();
  await drop(box!.x + 20, box!.y + 20);
  expect(await page.evaluate(() => (window as any).calls.filter((call: any) => call.command === 'transfer').length)).toBe(1);
});

test('snippet descriptions and tags persist and are searchable', async ({ page }) => {
  await page.getByRole('button', { name: '管理命令片段', exact: true }).click();
  await page.getByLabel('片段名称').fill('环境检查');
  await page.getByLabel('描述（可选）').fill('查看当前执行身份');
  await page.getByLabel('标签（逗号分隔）').fill('诊断, 身份');
  await page.getByLabel('片段命令').fill('whoami');
  await page.getByRole('button', { name: '保存片段' }).click();
  await page.getByLabel('搜索片段').fill('身份');
  await expect(page.getByText('查看当前执行身份', { exact: true })).toBeVisible();
  const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('orbit-snippets') || '[]'));
  expect(saved[0].tags).toEqual(['诊断', '身份']);
  await page.getByLabel('搜索片段').fill('不存在的标签');
  await expect(page.getByText('查看当前执行身份', { exact: true })).toHaveCount(0);
});

test('bundled terminal fonts load offline and preserve custom font preferences', async ({ page }) => {
  await expect(page.getByRole('button', { name: '设置', exact: true })).toBeVisible();
  const fonts = await page.evaluate(async () => {
    const faces = await Promise.all([400, 700].flatMap(weight => ['normal', 'italic'].map(style => document.fonts.load(`${style} ${weight} 14px "Maple Mono Normal"`))));
    return faces.map(result => result.map(face => face.status));
  });
  expect(fonts).toEqual([['loaded'], ['loaded'], ['loaded'], ['loaded']]);
  await page.evaluate(() => localStorage.setItem('orbit-settings', JSON.stringify({ fontFamily: 'My Custom Mono' })));
  await page.reload();
  await page.getByRole('button', { name: '设置', exact: true }).click();
  await page.getByRole('button', { name: '终端', exact: true }).click();
  await expect(page.getByLabel('终端字体', { exact: true })).toHaveValue('My Custom Mono');
});

test('updater separates download and install confirmation and reports failures', async ({ page }) => {
  await expect(page.getByRole('button', { name: '设置', exact: true })).toBeVisible();
  await page.evaluate(async () => {
    const { mockIPC } = await import('/node_modules/@tauri-apps/api/mocks.js' as string);
    (window as any).updateCalls = [];
    mockIPC(async (command: string) => {
      (window as any).updateCalls.push(command);
      if (command === 'plugin:updater|check') return { rid: 88, currentVersion: '0.1.1', version: '0.1.2', body: '验证新版', rawJson: {} };
      if (command === 'plugin:updater|download') return 89;
      if (command === 'plugin:updater|install') throw '安装程序无法启动';
      return null;
    });
  });
  await page.getByRole('button', { name: '设置', exact: true }).click();
  await page.getByRole('button', { name: '关于', exact: true }).click();
  await page.getByRole('button', { name: '检查更新', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: '软件更新' });
  await expect(dialog.getByText('验证新版')).toBeVisible();
  await expect(dialog.getByRole('button', { name: '安装并重启' })).toHaveCount(0);
  await dialog.getByRole('button', { name: '下载更新' }).click();
  await expect(dialog.getByText(/签名验证通过/)).toBeVisible();
  expect(await page.evaluate(() => (window as any).updateCalls.includes('plugin:updater|install'))).toBe(false);
  await dialog.getByRole('button', { name: '稍后' }).click();
  await page.getByRole('button', { name: '检查更新', exact: true }).click();
  await dialog.getByRole('button', { name: '安装并重启' }).click();
  await expect(dialog.getByRole('alert')).toContainText('安装程序无法启动');
  await expect(dialog.getByRole('button', { name: '安装并重启' })).toBeEnabled();
});

test('automatic update preference is persisted', async ({ page }) => {
  await page.getByRole('button', { name: '设置', exact: true }).click();
  await page.getByRole('button', { name: '关于', exact: true }).click();
  await page.getByLabel('启动时自动检查更新').uncheck();
  await page.getByRole('button', { name: '保存设置' }).click();
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('orbit-settings')!).autoUpdate)).toBe(false);
});
