import { useEffect, useRef, useState } from 'react';
import { check, Update } from '@tauri-apps/plugin-updater';

export function useUpdates(automatic: boolean) {
  const [visible, setVisible] = useState(false);
  const [phase, setPhase] = useState<'idle' | 'checking' | 'available' | 'downloading' | 'ready' | 'installing' | 'current' | 'error'>('idle');
  const [update, setUpdate] = useState<Update | null>(null);
  const [error, setError] = useState('');
  const [progress, setProgress] = useState({ downloaded: 0, total: 0 });
  const busy = useRef(false);
  const pending = useRef<Update | null>(null);
  const mounted = useRef(true);
  async function checkNow(background = false) {
    if (busy.current) { if (!background) setVisible(true); return; }
    if (pending.current) { setVisible(true); return; }
    busy.current = true; setPhase('checking'); setError('');
    if (!background) setVisible(true);
    try {
      const next = await check({ timeout: 15000 });
      if (!mounted.current) { await next?.close(); return; }
      pending.current = next; setUpdate(next); setPhase(next ? 'available' : 'current');
      if (next) setVisible(true);
    } catch (error) { if (mounted.current) { setError(String(error)); setPhase('error'); } }
    finally { busy.current = false; }
  }
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; void pending.current?.close().catch(() => {}); };
  }, []);
  useEffect(() => { if (automatic) { const timer = window.setTimeout(() => void checkNow(true), 1500); return () => window.clearTimeout(timer); } }, [automatic]);
  async function download() {
    if (!update || busy.current) return;
    busy.current = true; setPhase('downloading'); setError(''); setProgress({ downloaded: 0, total: 0 });
    try {
      await update.download(event => {
        if (event.event === 'Started') setProgress({ downloaded: 0, total: event.data.contentLength || 0 });
        if (event.event === 'Progress') setProgress(value => ({ ...value, downloaded: value.downloaded + event.data.chunkLength }));
      }, { timeout: 300000 });
      setPhase('ready');
    } catch (error) { setError(`下载或签名校验失败：${String(error)}`); setPhase('available'); }
    finally { busy.current = false; }
  }
  async function install() {
    if (!update || busy.current || phase !== 'ready') return;
    busy.current = true; setPhase('installing'); setError('');
    try { await update.install({ restartAfterInstall: true }); }
    catch (error) { setError(`安装失败：${String(error)}`); setPhase('ready'); busy.current = false; }
  }
  return { visible, phase, update, error, progress, checkNow, download, install, close: () => setVisible(false) };
}

export function UpdateDialog({ updates }: { updates: ReturnType<typeof useUpdates> }) {
  const { visible, phase, update, error, progress } = updates;
  if (!visible) return null;
  const busy = ['checking', 'downloading', 'installing'].includes(phase);
  return <div className="scrim"><section className="dialog" role="dialog" aria-label="软件更新"><h2>软件更新</h2>
    {phase === 'checking' && <p role="status">正在检查更新…</p>}
    {phase === 'current' && <p role="status">当前已是最新版本。</p>}
    {update && <><p>{update.currentVersion} → {update.version}</p><pre className="update-notes">{update.body || '此版本未提供更新说明。'}</pre></>}
    {phase === 'downloading' && <><progress aria-label="更新下载进度" max={progress.total || undefined} value={progress.total ? progress.downloaded : undefined} /><p role="status">已下载 {(progress.downloaded / 1024 / 1024).toFixed(1)} MB{progress.total ? ` / ${(progress.total / 1024 / 1024).toFixed(1)} MB` : ''}</p></>}
    {phase === 'ready' && <p role="status">下载完成，签名验证通过。安装将关闭所有终端会话并重启应用，请先完成正在执行的命令和文件传输、保存编辑内容。连接配置、凭据和设置会保留。</p>}
    {phase === 'installing' && <p role="status">正在启动安装程序，完成后将自动重启…</p>}
    {error && <p className="error" role="alert">{error}</p>}
    <div className="dialog-actions"><button disabled={busy} onClick={updates.close}>稍后</button>{phase === 'available' && <button className="primary" onClick={() => void updates.download()}>下载更新</button>}{phase === 'ready' && <button className="primary" onClick={() => void updates.install()}>安装并重启</button>}{phase === 'error' && <button onClick={() => void updates.checkNow()}>重试检查</button>}</div>
  </section></div>;
}
