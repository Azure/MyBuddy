import { access } from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';

export function receiveApprovedTask({ helper, stateDirectory, sessionId, operation }) {
  return new Promise((resolve, reject) => {
    const child = spawn('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', helper,
      '-Operation', operation, '-SessionId', sessionId, '-StateDirectory', stateDirectory],
    { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', part => { output += part; });
    child.stderr.resume(); // Do not echo protected request contents or environment into logs.
    child.on('error', reject);
    child.on('close', code => {
      if (code !== 0) return reject(new Error('Approved native request unavailable or already consumed. No resend attempted.'));
      try { resolve(JSON.parse(output)); } catch { reject(new Error('Invalid native launch receipt.')); }
    });
  });
}

export async function deliverApprovedTask(session, options, receive = receiveApprovedTask) {
  if (session.sessionId !== options.sessionId) throw new Error('Native foreground session changed; nothing submitted.');
  const request = await receive({ ...options, operation: 'claim' });
  if (request.sessionId !== session.sessionId || typeof request.prompt !== 'string' || !request.prompt.trim()) {
    throw new Error('Approved task identity mismatch; nothing submitted.');
  }
  try {
    // The extension joins the native TUI's existing foreground session; it never creates a client/runtime.
    await session.send({ prompt: request.prompt });
    await receive({ ...options, operation: 'submitted' });
  } catch {
    await receive({ ...options, operation: 'failed' }).catch(() => {});
    throw new Error('Native prompt delivery could not be confirmed. Inspect this session; no resend attempted.');
  }
}

export async function attachApprovedTask(options) {
  const sessionId = process.env.SESSION_ID;
  if (!/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(sessionId || '')) return;
  if (process.env.MY_BUDDY_NATIVE_SESSION !== sessionId) return;
  const folder = path.join(options.stateDirectory, 'native');
  try { await access(path.join(folder, `${sessionId}.dpapi`)); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  try { await access(path.join(folder, `${sessionId}.consumed.dpapi`)); return; }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const { joinSession } = await import('@github/copilot-sdk/extension');
  const session = await joinSession();
  try { await deliverApprovedTask(session, { ...options, sessionId }); }
  catch (error) { await session.log(error.message, { level: 'error' }); }
  // No dispose, shutdown, polling timeout or process kill: the native user session owns its lifecycle.
}
