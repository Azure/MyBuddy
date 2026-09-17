import { createHash, randomBytes, randomUUID } from 'node:crypto';

export const scanSources = ['ado', 'github', 'email', 'teams', 'documents'];
const officeSources = ['email', 'teams', 'documents'];
const day = 86400000;
const terminal = new Set(['complete', 'partial', 'failed']);
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const iso = value => new Date(value).toISOString();
const fail = (message, status = 409) => { const error = new Error(message); error.status = status; throw error; };

export function scanWindow(through, until) {
  const end = Date.parse(until), previous = Date.parse(through || '');
  if (!Number.isFinite(end)) fail('Invalid scan time.', 400);
  const floor = end - 7 * day;
  return {
    since: iso(Number.isFinite(previous) ? Math.max(floor, Math.min(previous, end)) : floor),
    until: iso(end), gap: Number.isFinite(previous) && previous < floor,
    bootstrap: !Number.isFinite(previous)
  };
}

export function createScanCoordinator({ state, mutate: serialize, persist, adapter, upsert, normalize, prItems, now = () => new Date() }) {
  state.scanLedger ||= { version: 1, checkpoints: {}, caches: {}, receipts: {}, runs: [] };
  const ledger = state.scanLedger;
  const mutate = work => serialize(async () => {
    const before = structuredClone({ ledger, items: state.items, coverage: state.coverage, conversations: state.conversations });
    try { return await work(); }
    catch (error) {
      for (const key of Object.keys(ledger)) delete ledger[key];
      Object.assign(ledger, before.ledger);
      state.items = before.items; state.coverage = before.coverage; state.conversations = before.conversations;
      throw error;
    }
  });
  const operations = new Set();
  const stamp = () => now().toISOString();
  const active = () => ledger.runs.find(run => !terminal.has(run.status));
  const assertSource = source => { if (!scanSources.includes(source)) fail('Unknown scan source.', 400); };
  const scopes = config => {
    return Object.fromEntries(scanSources.map(source => [source, digest({
      source, filters: config.briefingFilters, scope: source === 'ado' ? config.azureDevOps
        : source === 'github' ? config.github : source === 'documents'
          ? { documents: config.documents, email: config.email } : config[source]
    })]));
  };
  const publicRun = run => {
    if (!run) return null;
    const { worker, ...rest } = run;
    return { ...rest, worker: { status: worker.status, claimedAt: worker.claimedAt, expiresAt: worker.expiresAt } };
  };
  const findRun = id => {
    const run = ledger.runs.find(entry => entry.id === id);
    if (!run) fail('Scan no longer exists.');
    return run;
  };
  function finish(run) {
    if (Object.values(run.sources).every(entry => terminal.has(entry.status))) {
      run.status = Object.values(run.sources).every(entry => entry.status === 'complete') ? 'complete'
        : Object.values(run.sources).every(entry => entry.status === 'failed') ? 'failed' : 'partial';
      run.finishedAt = stamp();
    }
  }
  function applyCoverage(run, source, result, checkpointSafe) {
    const entry = run.sources[source];
    entry.status = result.status;
    entry.finishedAt = stamp();
    entry.note = result.note || '';
    entry.updated = result.updated || 0;
    entry.skippedUnchanged = result.skippedUnchanged || 0;
    entry.checkpointAdvanced = checkpointSafe;
    ledger.checkpoints[source] = {
      ...ledger.checkpoints[source], scopeKey: entry.scopeKey, lastAttemptAt: entry.finishedAt,
      lastScanAt: result.status !== 'failed' ? entry.finishedAt : ledger.checkpoints[source]?.lastScanAt,
      ...(checkpointSafe ? { through: entry.until, lastSuccessfulAt: entry.finishedAt } : {})
    };
    state.coverage[source] = {
      ...state.coverage[source], status: result.status, note: entry.note, since: entry.since,
      attemptedAt: entry.finishedAt, asOf: result.status === 'failed' ? state.coverage[source]?.asOf : entry.until,
      scanId: run.id, checkpoint: ledger.checkpoints[source].through || null, previousItemsRetained: true,
      inspected: result.inspected, skippedUnchanged: entry.skippedUnchanged
    };
    finish(run);
  }
  async function expire() {
    return mutate(async () => {
      const run = active();
      if (!run || Date.parse(run.worker.expiresAt) > now().getTime()) return;
      for (const source of officeSources) {
        if (!terminal.has(run.sources[source].status)) applyCoverage(run, source, {
          status: 'failed', note: 'Scout did not finish within its scan lease. Previous items and checkpoint retained.'
        }, false);
      }
      run.worker.status = 'expired';
      await persist();
    });
  }
  async function collect(run, source) {
    operations.add(`${run.id}:${source}`);
    const entry = run.sources[source];
    try {
      const reader = source === 'ado' ? adapter.collect : adapter.collectGitHub;
      if (!reader) fail('This PR collector is unavailable.', 503);
      const snapshot = await reader({ asOf: entry.until, since: entry.since, cache: ledger.caches[source] });
      const items = prItems(snapshot, source);
      const coverage = snapshot.coverage;
      if (!coverage || !['complete', 'complete-within-declared-scope', 'partial', 'unavailable', 'failed'].includes(coverage.status)) {
        fail('Collector returned invalid coverage.', 502);
      }
      const failed = ['failed', 'unavailable'].includes(coverage.status);
      const safe = !failed && (coverage.checkpointSafe === true ||
        coverage.checkpointSafe === undefined && ['complete', 'complete-within-declared-scope'].includes(coverage.status));
      const status = failed ? 'failed' : safe && coverage.status !== 'partial' ? 'complete' : 'partial';
      const note = [
        ...(coverage.errors || []).map(error => `${error.operation}: ${error.error}`),
        ...(coverage.limitations || []),
        entry.gap ? 'More than seven days elapsed; older activity was not scanned. Stored work is retained.' : ''
      ].filter(Boolean).join(' ').slice(0, 6000);
      await mutate(async () => {
        if (!terminal.has(entry.status)) {
          if (!failed) upsert(items, [source], false);
          if (snapshot.cache && typeof snapshot.cache === 'object') ledger.caches[source] = snapshot.cache;
          applyCoverage(run, source, { status, note, updated: items.length,
            inspected: coverage.inspectedPullRequests, skippedUnchanged: coverage.skippedUnchangedPullRequests }, safe);
          await persist();
        }
      });
    } catch (error) {
      await mutate(async () => {
        applyCoverage(run, source, { status: 'failed', note: error.message }, false);
        await persist();
      });
    } finally { operations.delete(`${run.id}:${source}`); }
  }
  return {
    summary() {
      return { active: publicRun(active()), last: publicRun(ledger.runs[0]), checkpoints: ledger.checkpoints,
        history: ledger.runs.slice(0, 10).map(publicRun) };
    },
    async request() {
      await expire();
      const config = await adapter.scanConfig?.() || {};
      const scopeKeys = scopes(config);
      const result = await mutate(async () => {
        const existing = active();
        if (existing) return { run: existing, reused: true };
        const recent = ledger.runs[0];
        if (recent && now().getTime() - Date.parse(recent.requestedAt) < 60000 &&
          scanSources.every(source => recent.sources[source].scopeKey === scopeKeys[source])) {
          return { run: recent, reused: true, cooldown: true };
        }
        const until = stamp();
        const run = { id: randomUUID(), requestedAt: until, status: 'running',
          policy: { email: { pageSize: 50, scanAllPages: true },
            documents: { mode: config.documents?.mode || 'changed-documents',
              skipKnown: config.documents?.skipKnownDocuments === true } },
          worker: { status: 'queued', expiresAt: iso(now().getTime() + 60 * 60000) }, sources: {} };
        for (const source of scanSources) {
          if (!ledger.runs.length && !ledger.checkpoints[source] && state.coverage[source]?.status === 'complete' &&
            Number.isFinite(Date.parse(state.coverage[source].asOf)) && Date.parse(state.coverage[source].asOf) <= Date.parse(until)) {
            ledger.checkpoints[source] = { through: state.coverage[source].asOf, scopeKey: scopeKeys[source],
              lastSuccessfulAt: state.coverage[source].asOf, migrated: true };
          }
          const checkpoint = ledger.checkpoints[source];
          if (checkpoint && checkpoint.scopeKey !== scopeKeys[source]) {
            delete ledger.caches[source]; delete ledger.receipts[source]; delete ledger.checkpoints[source];
          }
          // Legacy coverage is not proof of an exhaustive incremental scan; bootstrap once.
          run.sources[source] = { ...scanWindow(ledger.checkpoints[source]?.through, until),
            scopeKey: scopeKeys[source], status: officeSources.includes(source) ? 'queued' : 'running' };
        }
        ledger.runs.unshift(run);
        ledger.runs = ledger.runs.slice(0, 50);
        if (config.github?.enabled === false) {
          run.sources.github.disabled = true;
          applyCoverage(run, 'github', { status: 'complete', inspected: 0,
            note: 'GitHub is disabled in configuration; no GitHub reads were made. Existing work is retained.' }, false);
        }
        try { await persist(); }
        catch (error) { ledger.runs = ledger.runs.filter(entry => entry.id !== run.id); throw error; }
        return { run, reused: false };
      });
      if (!result.reused) {
        // Independent provider reads; a failed source never blocks the other sources.
        void collect(result.run, 'ado');
        if (!result.run.sources.github.disabled) void collect(result.run, 'github');
      }
      return { scan: publicRun(result.run), reused: result.reused, cooldown: !!result.cooldown };
    },
    async pending() {
      await expire();
      const run = active();
      return run?.worker.status === 'queued' ? { available: true, scanId: run.id } : { available: false };
    },
    async dispatch(id) {
      return mutate(async () => {
        const run = findRun(id);
        if (run.worker.status !== 'queued' || terminal.has(run.status)) return { available: false };
        run.worker.status = 'dispatched';
        run.worker.dispatchToken = randomBytes(32).toString('hex');
        await persist();
        return { available: true, scanId: id, dispatchToken: run.worker.dispatchToken };
      });
    },
    async failDispatch(id, token, message) {
      return mutate(async () => {
        const run = findRun(id);
        if (run.worker.status !== 'dispatched' || token !== run.worker.dispatchToken) fail('Invalid scan dispatch.');
        for (const source of officeSources) applyCoverage(run, source, { status: 'failed', note: String(message).slice(0, 3000) }, false);
        run.worker.status = 'failed';
        await persist();
        return { recorded: true };
      });
    },
    async claim() {
      await expire();
      return mutate(async () => {
        const run = active();
        if (!run || !['queued', 'dispatched'].includes(run.worker.status)) return { available: false };
        run.worker.status = 'running'; run.worker.claimedAt = stamp();
        run.worker.expiresAt = iso(now().getTime() + 60 * 60000);
        run.worker.claimToken = randomBytes(32).toString('hex');
        for (const source of officeSources) run.sources[source].status = 'running';
        await persist();
        return { available: true, scanId: run.id, claimToken: run.worker.claimToken,
          policy: run.policy || {},
          sources: Object.fromEntries(officeSources.map(source => [source, run.sources[source]])),
          receipts: Object.fromEntries(officeSources.map(source => [source, ledger.receipts[source] || {}])),
          knownItems: state.items.filter(item => officeSources.includes(item.source)).map(item => ({
            id: item.id, source: item.source, sourceKey: item.sourceKey, url: item.url,
            title: item.title, status: state.feedback?.[item.id]?.status || 'open'
          })) };
      });
    },
    async commit(data) {
      const run = findRun(data.scanId);
      const source = data.source;
      assertSource(source);
      if (!officeSources.includes(source)) fail('Only Scout sources can be committed here.', 400);
      const part = run.sources[source];
      if (data.claimToken !== run.worker.claimToken || !data.claimToken) fail('Invalid scan claim.');
      const payloadHash = digest({ source, items: data.items, coverage: data.coverage, receipts: data.receipts });
      if (part.commitHash) {
        if (part.commitHash !== payloadHash) fail('Source already committed with different results.');
        return { recorded: true, duplicate: true };
      }
      if (run.worker.status !== 'running' || Date.parse(run.worker.expiresAt) <= now().getTime()) fail('Scan claim expired; results not applied.');
      const coverage = data.coverage;
      if (!coverage || !['complete', 'partial', 'failed'].includes(coverage.status) ||
        typeof coverage.note !== 'string' || coverage.note.length > 6000) fail('Provide honest bounded source coverage.', 400);
      if (!Array.isArray(data.items) || data.items.length > 300) fail('Invalid scan items.', 400);
      const items = data.items.map(normalize).filter(Boolean);
      if (items.some(item => item.source !== source) || coverage.status === 'failed' && items.length) fail('Items outside successful source coverage.', 400);
      const receipts = data.receipts || [];
      if (!Array.isArray(receipts) || receipts.length > 3000) fail('Too many processed item receipts.', 400);
      for (const receipt of receipts) {
        if (!receipt || !/^[a-f0-9]{64}$/i.test(receipt.key) || !/^[a-f0-9]{64}$/i.test(receipt.version)) {
          fail('Receipts must contain only SHA-256 identity/version hashes.', 400);
        }
      }
      return mutate(async () => {
        if (part.commitHash) {
          if (part.commitHash !== payloadHash) fail('Concurrent source result conflict.');
          return { recorded: true, duplicate: true };
        }
        if (run.worker.status !== 'running' || Date.parse(run.worker.expiresAt) <= now().getTime()) fail('Scan claim expired.');
        const knownDocumentIds = new Set(state.items.filter(item => item.source === 'documents').map(item => item.id));
        const accepted = source === 'documents' && run.policy?.documents?.skipKnown
          ? items.filter(item => !knownDocumentIds.has(item.id)) : items;
        const skippedKnown = items.length - accepted.length;
        upsert(accepted, [source], false);
        ledger.receipts[source] ||= {};
        for (const receipt of receipts) ledger.receipts[source][receipt.key] = { version: receipt.version, at: part.until };
        for (const [key, receipt] of Object.entries(ledger.receipts[source])) {
          if (Date.parse(receipt.at) < now().getTime() - 8 * day) delete ledger.receipts[source][key];
        }
        const status = coverage.status === 'complete' && coverage.checkpointSafe !== true ? 'partial' : coverage.status;
        applyCoverage(run, source, { status, note: coverage.note, updated: accepted.length, skippedUnchanged: skippedKnown },
          coverage.status === 'complete' && coverage.checkpointSafe === true);
        part.commitHash = payloadHash;
        if (officeSources.every(name => terminal.has(run.sources[name].status))) run.worker.status = 'finished';
        await persist();
        return { recorded: true, imported: accepted.length, skippedKnown, through: ledger.checkpoints[source]?.through || null };
      });
    },
    async recover() {
      const run = active();
      if (run) {
        for (const source of ['ado', 'github']) {
          if (run.sources[source].status === 'running') applyCoverage(run, source, {
            status: 'failed', note: 'Portal restarted during PR collection. Checkpoint retained; retry on the next scan.'
          }, false);
        }
        await persist();
      }
      await expire();
    },
    operations
  };
}
