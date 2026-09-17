import http from 'node:http';
import { randomBytes, randomUUID, createHash, timingSafeEqual } from 'node:crypto';
import { readFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { stripVTControlCharacters } from 'node:util';
import { createScanCoordinator } from './scan.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.dirname(directory);
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const clone = value => structuredClone(value);
export const cleanError = value => stripVTControlCharacters(String(value)).trim();
const equal = (a, b) => typeof a === 'string' && /^[a-f0-9]{64}$/.test(a) && a.length === b.length &&
  timingSafeEqual(Buffer.from(a), Buffer.from(b));

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const requireValue = (condition, message, status = 400) => {
  if (!condition) throw new HttpError(status, message);
};
const text = (value, max = 4000) => {
  requireValue(typeof value === 'string' && value.length <= max, 'Invalid or oversized text.');
  return value;
};
const optionalText = (value, max) => value == null ? '' : text(value, max);
const safeUrl = value => {
  if (!value) return '';
  const url = new URL(text(value, 2000));
  requireValue(url.protocol === 'https:' && !url.username && !url.password, 'Source links must use HTTPS.');
  return url.href;
};
const sources = ['ado', 'github', 'email', 'teams', 'documents'];
const isPullRequest = item => ['ado', 'github'].includes(item.source);
const timestamp = value => {
  if (!value) return '';
  const result = text(value, 100);
  requireValue(Number.isFinite(Date.parse(result)), 'Invalid observation timestamp.');
  return new Date(result).toISOString();
};
export function documentTarget(value) {
  const url = new URL(safeUrl(value));
  const sourceDoc = [...url.searchParams].find(([key]) => key.toLowerCase() === 'sourcedoc')?.[1];
  const guid = sourceDoc?.replace(/[{}]/g, '').toLowerCase();
  const documentId = guid && /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(guid) ? guid : '';
  return { url: url.href, documentId, identity: documentId ? `${url.hostname}:${documentId}` : `${url.origin}${url.pathname}` };
}
export const documentItemId = value => `documents:${hash(documentTarget(value).identity)}`;
export function sourceReference(item) {
  if (isPullRequest(item)) return `${item.url}\nCommit: ${item.headCommit || 'must be verified by agent'}`;
  if (item.source !== 'documents') return `${item.source} source: ${item.url || item.id}`;
  const target = documentTarget(item.url);
  return [
    'OFFICE DOCUMENT TARGET - this exact file only:',
    target.url,
    `Expected identity: ${target.identity}`,
    'Use a grounded WorkIQ file read with this URL in fileUrls/--file-urls. Verify the resolved source URL and document identity before reading or summarizing.',
    'Search hits are not identity proof. Never substitute a different document, filename, source GUID, or local checkout file when this URL cannot be opened.',
    'If a tool returns another file or cannot prove identity, stop and report the mismatch/access blocker. Ask the user before changing targets.',
    'Do not download or parse cloud Office files to bypass protection. Report the verified target URL with findings.'
  ].join('\n');
}
function normalizeReadiness(value, headCommit) {
  if (!value) return null;
  requireValue(['blocked', 'unknown', 'not-open', 'merge-ready-candidate'].includes(value.status), 'Invalid PR readiness.');
  const strings = values => {
    requireValue(Array.isArray(values) && values.length <= 100, 'Invalid readiness evidence.');
    return values.map(entry => text(entry, 1000));
  };
  const result = {
    status: value.status, blockers: strings(value.blockers || []), unknowns: strings(value.unknowns || []),
    observedAt: timestamp(value.observedAt), conflicts: optionalText(value.conflicts, 40),
    openThreadCount: Number.isSafeInteger(value.openThreadCount) && value.openThreadCount >= 0 ? value.openThreadCount : null,
    threadCoverage: optionalText(value.threadCoverage, 50),
    requiresRevalidation: true, automaticMergeAllowed: false
  };
  for (const area of ['checks', 'policies', 'approvals']) {
    result[area] = { state: optionalText(value[area]?.state, 50) || 'unknown',
      coverage: optionalText(value[area]?.coverage, 50) || 'unavailable' };
  }
  if (result.status === 'merge-ready-candidate' && (!headCommit || value.headCommit !== headCommit ||
    !result.observedAt || result.conflicts !== 'clear' || result.openThreadCount !== 0 ||
    result.threadCoverage !== 'complete' || result.blockers.length || result.unknowns.length ||
    ['checks', 'policies', 'approvals'].some(area => result[area].state !== 'passed' || result[area].coverage !== 'complete'))) {
    result.status = 'unknown';
    result.unknowns.push('Complete, matching-head readiness evidence is required.');
  }
  return result;
}

export function normalizeItem(value) {
  requireValue(value && sources.includes(value.source), 'Unknown item source.');
  const title = text(value.title, 500);
  const evidence = optionalText(value.evidence, 6000);
  const icm = value.icmRelated === true || (!isPullRequest(value) &&
    /\bicm\b|microsofticm\.com|\bincident (assignment|transfer|notification|acknowledg|escalat)/i.test(title + ' ' + evidence));
  if (icm) return null;
  const item = {
    id: text(value.id, 500), source: value.source, title, evidence,
    url: safeUrl(value.url), action: optionalText(value.action, 3000),
    bucket: ['needs-you', 'waiting', 'carryover'].includes(value.bucket) ? value.bucket : 'needs-you',
    priority: ['high', 'normal', 'low'].includes(value.priority) ? value.priority : 'normal',
    repository: optionalText(value.repository, 200), headCommit: optionalText(value.headCommit, 100),
    pullRequestId: Number.isSafeInteger(value.pullRequestId) ? value.pullRequestId : null,
    provenance: optionalText(value.provenance, 200) || 'Scout briefing',
    deadline: optionalText(value.deadline, 200)
  };
  item.sourceKey = optionalText(value.sourceKey, 500);
  if (isPullRequest(item)) {
    item.readiness = normalizeReadiness(value.readiness, item.headCommit);
    item.ownership = optionalText(value.ownership, 500);
    item.sourceStatus = optionalText(value.sourceStatus, 50);
  }
  if (item.source === 'documents') {
    requireValue(item.url, 'Document items need an observed document URL.');
    requireValue(['word', 'powerpoint', 'excel'].includes(value.documentType), 'Specify the Office document type.');
    requireValue(['authored', 'coauthored', 'review-requested', 'mentioned', 'input-requested'].includes(value.relationship), 'Provide evidence of the document relationship.');
    requireValue(['comment', 'review', 'input'].includes(value.attentionKind), 'Specify the document attention type.');
    requireValue(['active', 'unknown', 'not-applicable', 'resolved'].includes(value.commentStatus), 'Specify the observed comment status.');
    item.id = documentItemId(item.url);
    Object.assign(item, {
      documentType: value.documentType, relationship: value.relationship,
      attentionKind: value.attentionKind, commentStatus: value.commentStatus,
      lastActivityAt: timestamp(value.lastActivityAt), statusVerifiedAt: timestamp(value.statusVerifiedAt),
      notificationUrl: safeUrl(value.notificationUrl), coverageNote: optionalText(value.coverageNote, 2000)
    });
    requireValue(!['active', 'resolved'].includes(item.commentStatus) || item.statusVerifiedAt,
      'Active/resolved comments need a current document-state observation, not just an email notification.');
  }
  requireValue(item.id.length > 0 && item.title.length > 0, 'Item needs an ID and title.');
  item.version = hash(item);
  return item;
}
export function itemIdentity(item) {
  if (isPullRequest(item) && item.repository && item.pullRequestId) return `${item.source}:${item.repository.toLowerCase()}:${item.pullRequestId}`;
  if (item.source === 'documents' && item.url) return documentItemId(item.url);
  return item.sourceKey ? `${item.source}:${item.sourceKey}` : item.id;
}

export function prItems(snapshot, source) {
  requireValue(Array.isArray(snapshot.items) && snapshot.coverage, 'Invalid collector response.', 502);
  requireValue(['ado', 'github'].includes(source), 'Invalid PR provider.', 502);
  return snapshot.items.map(pr => {
    const needsReview = pr.reviewDecisionCandidate || pr.reReviewCandidate;
    const feedback = pr.authoredFeedbackCandidate;
    const owned = pr.authoredByUser || pr.delegatedToUser || pr.trackedByUser || pr.userIsAssignee;
    const inactive = pr.status && !['active', 'open', 'OPEN'].includes(pr.status);
    if (!needsReview && !feedback && !owned) return null;
    const readiness = normalizeReadiness(pr.readiness, pr.headCommit);
    const ready = readiness?.status === 'merge-ready-candidate';
    const attention = needsReview || feedback || owned && (ready || readiness?.blockers.length || readiness?.unknowns.length);
    const ownership = pr.delegatedToUser ? 'Verified agency-created on your behalf'
      : pr.trackedByUser ? 'Explicitly tracked for you'
      : pr.authoredByUser ? 'Authored by you' : pr.userIsAssignee ? 'Assigned to you' : 'Your review is requested';
    const readinessEvidence = readiness
      ? ` Merge readiness: ${readiness.status}. ${[...readiness.blockers, ...readiness.unknowns].join(' ')}`
      : ' Merge readiness has not been checked.';
    return normalizeItem({
      id: pr.id, source, title: pr.title, url: pr.url, repository: pr.repository,
      headCommit: pr.headCommit, pullRequestId: pr.pullRequestId, readiness: pr.readiness, ownership, sourceStatus: pr.status,
      bucket: inactive ? 'waiting' : !pr.inWindowEvidence ? 'carryover' : attention ? 'needs-you' : 'waiting',
      action: inactive ? `PR is ${pr.status}. Mark this work done if no follow-up remains.`
        : needsReview ? 'Assess whether this PR needs your review.'
        : ready ? 'Review the merge candidate; revalidate the latest head and requirements before separately approving merge.'
        : feedback ? 'Assess incoming PR feedback and whether changes are needed.'
        : 'Review outstanding merge requirements and decide the next step.',
      evidence: `${ownership}. ` + (needsReview
        ? `Your review state: ${pr.userReviewState}. This is a candidate, not a completed code review.`
        : `${pr.recentIncomingCommentCount || 0} recent incoming comments; ${pr.openIncomingCommentCount || 0} comments in open threads. Read the discussion before deciding action is owed.`) + readinessEvidence,
      provenance: `Live ${source === 'ado' ? 'ADO' : 'GitHub'} metadata · not yet triaged`
    });
  }).filter(Boolean);
}
export const adoItems = snapshot => prItems(snapshot, 'ado');

export function workSessionTitle(item, repository) {
  const title = stripVTControlCharacters(item?.title || 'Copilot work')
    .replace(/^(?:\s*\[[^\]\r\n]+\]\s*)+/u, '').trim() || 'Copilot work';
  const kind = item && isPullRequest(item) && item.pullRequestId ? `PR ${item.pullRequestId}`
    : ({ email: 'Email', teams: 'Teams', documents: 'Document' }[item?.source] || 'Work');
  return `${repository || 'Copilot'} | ${kind} | ${title}`;
}

export function assertCurrentPullRequest(item, snapshot) {
  requireValue(item.headCommit && item.pullRequestId && item.repository,
    'Missing PR revision. Refresh PRs and preview again.', 409);
  const provider = item.source === 'github' ? 'GitHub' : 'Azure DevOps';
  const current = Array.isArray(snapshot?.items) ? snapshot.items.find(pr =>
    pr.pullRequestId === item.pullRequestId && pr.repository?.toLowerCase() === item.repository.toLowerCase()) : null;
  if (!current || ['failed', 'unavailable'].includes(snapshot?.coverage?.status)) {
    const errors = Array.isArray(snapshot?.coverage?.errors) ? snapshot.coverage.errors : [];
    const httpStatus = errors.map(error => String(error.error || '').match(/\bHTTP (401|403|404)\b/)?.[1]).find(Boolean);
    const reason = httpStatus ? ` (HTTP ${httpStatus})` : '';
    const action = item.source === 'github' ? 'Check GitHub CLI access.' : "Check Buddy's Azure DevOps tenant and Azure CLI sign-in.";
    throw new HttpError(503, `${provider} could not read this PR${reason}. ${action} No task started.`);
  }
  requireValue(current.status && current.headCommit, `${provider} returned incomplete PR details. No task started.`, 503);
  requireValue(['active', 'open', 'OPEN'].includes(current.status), 'This PR is no longer active. No task started.', 409);
  requireValue(current.headCommit === item.headCommit, 'This PR has a new commit. Refresh PRs and preview again. No task started.', 409);
  return current;
}

export function createPortal({ adapter, token = randomBytes(32).toString('hex'), initial, save = async () => {}, html = '', logo = '', now }) {
  let state = initial || {
    items: [], feedback: {}, jobs: [],
    coverage: { ado: { status: 'not-loaded' }, github: { status: 'not-loaded' },
      email: { status: 'awaiting-scout' }, teams: { status: 'awaiting-scout' }, documents: { status: 'awaiting-scout' } }
  };
  state = clone(state);
  for (const job of state.jobs) { if (job.error) job.error = cleanError(job.error); }
  for (const conversation of state.conversations || []) {
    for (const turn of conversation.turns || []) {
      if (turn.role === 'assistant' && turn.content?.startsWith("I couldn't complete this turn:")) {
        turn.content = cleanError(turn.content);
      }
    }
  }
  state.feedback = Object.assign(Object.create(null), state.feedback);
  state.jobs = state.jobs.map(job => job.status === 'running' && job.execution !== 'native-interactive'
    ? { ...job, status: 'interrupted', error: 'Portal restarted. Inspect the native Copilot session before retrying.' } : job);
  state.conversations ||= [];
  state.scoutQueue ||= [];
  for (const conversation of state.conversations) {
    if (conversation.status === 'running' && conversation.handler === 'cli') {
      conversation.status = 'interrupted';
    }
  }
  for (const job of state.jobs) {
    const item = state.items.find(entry => entry.id === job.itemId);
    if (!item || state.conversations.some(entry => entry.itemId === job.itemId)) continue;
    state.conversations.push({
      id: randomUUID(), itemId: job.itemId, itemSnapshot: clone(item), handler: 'cli',
      sessionId: job.result?.sessionId || null, input: job.input || null,
      status: ['done', 'dismissed'].includes(state.feedback[item.id]?.status) ? 'closed' : 'awaiting-user',
      turns: [
        { id: randomUUID(), role: 'user', content: job.task || '', at: job.startedAt },
        ...(job.result?.assessment ? [{ id: randomUUID(), role: 'assistant', content: job.result.assessment, at: job.finishedAt }] : [])
      ]
    });
  }
  for (const conversation of state.conversations) {
    if (conversation.handler === 'cli' && !conversation.sessionTitle) {
      conversation.sessionTitle = workSessionTitle(conversation.itemSnapshot ||
        state.items.find(item => item.id === conversation.itemId), conversation.input?.repository);
    }
  }
  const plans = new Map();
  const openingSessions = new Map();
  const launchingNative = new Set();
  let nativeRefresh;
  let lastNativeRefresh = 0;
  const sessions = new Set();
  let saveChain = Promise.resolve();
  let mutationChain = Promise.resolve();
  let refreshRunning = false;
  let origin;
  const persist = () => {
    const snapshot = clone(state);
    const operation = saveChain.then(() => save(snapshot));
    saveChain = operation.catch(() => {});
    return operation;
  };
  const mutate = work => {
    const operation = mutationChain.then(work);
    mutationChain = operation.catch(() => {});
    return operation;
  };
  const itemById = id => {
    const item = state.items.find(entry => entry.id === id);
    requireValue(item, 'Item no longer exists; refresh your inbox.', 409);
    return item;
  };
  const conversationByItem = id => state.conversations.find(entry => entry.itemId === id);
  const conversationById = id => {
    const conversation = state.conversations.find(entry => entry.id === id);
    requireValue(conversation, 'Conversation not found.', 404);
    return conversation;
  };
  const busy = conversation => ['running', 'queued-scout', 'running-scout', 'dispatching',
    'native-starting', 'native-active', 'native-unavailable'].includes(conversation?.status) ||
    (conversation?.execution === 'native-interactive' && conversation.native?.safeToClose !== true);
  const addTurn = (conversation, role, content) => {
    conversation.turns.push({ id: randomUUID(), role, content, at: new Date().toISOString() });
    conversation.updatedAt = new Date().toISOString();
  };
  const finishConversation = (job, result, error) => {
    if (error) error = cleanError(error);
    const conversation = conversationById(job.conversationId);
    job.status = error ? 'failed' : 'returned-for-review';
    if (result) job.result = result;
    if (error) job.error = error;
    job.finishedAt = new Date().toISOString();
    conversation.status = error ? 'failed' : 'awaiting-user';
    if (result?.sessionId) conversation.sessionId = result.sessionId;
    addTurn(conversation, 'assistant', error ? `I couldn't complete this turn: ${error}` : result.assessment);
  };
  const body = async req => {
    requireValue(req.headers['content-type']?.startsWith('application/json'), 'JSON content type required.', 415);
    let bytes = 0;
    const chunks = [];
    for await (const chunk of req) {
      bytes += chunk.length;
      requireValue(bytes <= 1_000_000, 'Request is too large.', 413);
      chunks.push(chunk);
    }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new HttpError(400, 'Invalid JSON.'); }
  };
  const send = (res, status, value) => {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(value));
  };
  const mergeItems = (items, scannedSources, markUnseen = true) => {
    const byIdentity = new Map(state.items.map(item => [itemIdentity(item), item]));
    const incoming = new Set();
    for (const item of items) {
      const key = itemIdentity(item), previous = byIdentity.get(key);
      incoming.add(key);
      if (previous) {
        // Keep the original identifier so user status, notes and sessions cannot detach.
        const updated = { ...item, id: previous.id };
        if (previous.version === updated.version) delete previous.retainedFromPreviousScan;
        else Object.assign(previous, updated, { retainedFromPreviousScan: false });
        const conversation = conversationByItem(previous.id);
        if (conversation) conversation.itemSnapshot = clone(previous);
      } else {
        requireValue(!state.items.some(entry => entry.id === item.id), 'Conflicting source identity.', 409);
        state.items.push(item); byIdentity.set(key, item);
      }
    }
    if (markUnseen) {
      for (const item of state.items) {
        if (scannedSources.includes(item.source) && !incoming.has(itemIdentity(item))) item.retainedFromPreviousScan = true;
      }
    }
  };
  const scans = createScanCoordinator({ state, mutate, persist, adapter, upsert: mergeItems, normalize: normalizeItem, prItems, now });
  async function runJob(job, saved) {
    try {
      const result = await adapter.run(saved.input, saved.plan);
      requireValue(typeof result?.assessment === 'string' && result.assessment.trim(), 'The agent returned no response for this turn.', 502);
      requireValue(!result.sessionId || result.sessionId === saved.input.sessionId,
        'Agent returned a different session ID; continuity was not accepted.', 502);
      await mutate(async () => {
        finishConversation(job, result);
        await persist();
      });
    } catch (error) {
      await mutate(async () => {
        finishConversation(job, null, error.message);
        try { await persist(); }
        catch (storageError) { job.error += ` Protected state save failed: ${storageError.message}`; }
      });
    }
  }
    const nativeStatuses = ['native-starting', 'native-active', 'native-closed', 'native-failed', 'native-orphaned'];
    function applyNative(job, result) {
      requireValue(result?.sessionId === job.input.sessionId && result.requestId === job.id &&
        nativeStatuses.includes(result.status) && typeof result.runtimeActive === 'boolean' &&
        typeof result.safeToClose === 'boolean' && typeof result.promptSubmitted === 'boolean',
      'Native lifecycle returned an invalid identity/status. No replacement runtime was started.', 502);
      job.status = result.status;
      job.native = clone(result);
      const conversation = conversationById(job.conversationId);
      conversation.native = clone(result);
      if (conversation.status !== 'closed') conversation.status = result.status;
      // A terminal opening/closing is never an assessment or task-completion event.
      if (result.status === 'native-failed') job.error = cleanError(result.message);
    }
    async function launchNative(job, saved) {
      launchingNative.add(job.id);
      try {
        const result = await adapter.launchNative(saved.input, saved.plan, job.launchNotAfter);
        await mutate(async () => { applyNative(job, result); await persist(); });
      } catch (error) {
        await mutate(async () => {
          job.status = 'native-failed'; job.error = cleanError(error.message);
          const conversation = conversationById(job.conversationId);
          conversation.status = 'native-failed';
          conversation.native = { status: 'native-failed', safeToClose: false, message: job.error };
          try { await persist(); }
          catch (storageError) {
            job.error += ` Protected state save failed: ${cleanError(storageError.message)}`;
            conversation.native.message = job.error;
          }
        });
      } finally { launchingNative.delete(job.id); }
    }
    async function refreshNative(force = false) {
      if (nativeRefresh) return nativeRefresh;
      if (!force && Date.now() - lastNativeRefresh < 5000) return;
      const jobs = state.jobs.filter(job => job.execution === 'native-interactive' && !launchingNative.has(job.id));
      if (!jobs.length) return;
      nativeRefresh = (async () => {
        for (const job of jobs) {
          try {
            requireValue(typeof adapter.nativeStatus === 'function', 'Native lifecycle discovery is unavailable.', 503);
            const result = await adapter.nativeStatus({ repository: job.input.repository,
              sessionId: job.input.sessionId, requestId: job.id });
            if (result.startupPending && Date.now() < Date.parse(job.launchNotAfter || '')) result.safeToClose = false;
            await mutate(async () => { applyNative(job, result); await persist(); });
          } catch (error) {
            await mutate(async () => {
              job.native = { status: 'native-unavailable', safeToClose: false, message: cleanError(error.message) };
              const conversation = conversationById(job.conversationId);
              conversation.native = clone(job.native);
              if (conversation.status !== 'closed') conversation.status = 'native-unavailable';
              await persist();
            });
          }
        }
      })();
      try { await nativeRefresh; } finally { nativeRefresh = null; lastNativeRefresh = Date.now(); }
    }
  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    try {
      requireValue(req.headers.host === new URL(origin).host, 'Invalid Host header.', 403);
      requireValue(!req.headers.origin || req.headers.origin === origin, 'Cross-origin access denied.', 403);
      const route = new URL(req.url, origin).pathname;
      const cookieName = `buddy_session_${server.address().port}`;
      if (req.method === 'GET' && route === '/health') return send(res, 200, { application: 'My Buddy Portal' });
      if (req.method === 'GET' && route === '/favicon.ico') { res.writeHead(204); return res.end(); }
      if (req.method === 'GET' && route === '/buddy-logo.svg') {
        res.writeHead(200, { 'Content-Type': 'image/svg+xml' });
        return res.end(logo);
      }
      if (req.method === 'GET' && route === '/') {
        const nonce = randomBytes(18).toString('base64');
        res.setHeader('Content-Security-Policy', `default-src 'self'; script-src 'nonce-${nonce}'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`);
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(html.replaceAll('__NONCE__', nonce));
      }
      if (req.method === 'POST' && route === '/api/session') {
        const data = await body(req);
        requireValue(equal(data.token, token), 'Open this portal through its local launcher.', 401);
        const session = randomBytes(32).toString('hex');
        sessions.add(session);
        res.setHeader('Set-Cookie', `${cookieName}=${session}; HttpOnly; SameSite=Strict; Path=/`);
        return send(res, 200, { authenticated: true });
      }
      const cookie = (req.headers.cookie || '').split(';').map(value => value.trim())
        .find(value => value.startsWith(cookieName + '='))?.slice(cookieName.length + 1);
      const bearer = req.headers.authorization?.replace(/^Bearer /, '');
      requireValue(sessions.has(cookie) || equal(bearer, token), 'Open the portal using Start-BuddyPortal.ps1 -Open.', 401);
      if (req.method === 'GET' && route === '/api/state') {
        await refreshNative();
        const { scanLedger, ...visibleState } = state;
        return send(res, 200, {
        ...visibleState, scan: scans.summary(), refreshRunning, publicationEnabled: false,
        scoutQueue: state.scoutQueue.map(({ claimToken, completionToken, ...entry }) => entry),
        persistence: 'Windows-user encrypted local storage'
        });
      }
      if (req.method === 'GET' && route === '/api/scan/pending') {
        requireValue(equal(bearer, token), 'Scout scan authentication required.', 403);
        return send(res, 200, await scans.pending());
      }
      if (req.method === 'GET' && route === '/api/doctor') {
        const doctor = await adapter.doctor();
        doctor.repositories = (doctor.repositories || []).map(repo => ({
          ...repo, agents: [
            { id: '__default_cli__', label: 'Default CLI' },
            ...(adapter.supportsScoutTasks === false ? [] : [{ id: '__scout__', label: 'Scout' }]),
            ...(repo.agents || []).filter(agent => /^xfe-/i.test(agent.id) || /^xfe-/i.test(agent.label))
          ]
        }));
        doctor.scoutTasksAvailable = adapter.supportsScoutTasks !== false;
        doctor.agentNote = adapter.supportsScoutTasks === false ? 'Default CLI and installed XFE-* agents. Scout handles source scans.'
          : doctor.repositories.some(repo => repo.agents.length > 2)
            ? 'Showing Scout, Default CLI and installed XFE-* agents.'
            : 'No XFE-* agent definitions found. Scout and Default CLI are available.';
        return send(res, 200, doctor);
      }
      if (req.method === 'GET' && route === '/api/scout/pending') {
        requireValue(equal(bearer, token), 'Scout bridge authentication required.', 403);
        return send(res, 200, state.scoutQueue.filter(entry => entry.status === 'queued').map(entry => ({
          jobId: entry.jobId, conversationId: entry.conversationId,
          automationId: conversationById(entry.conversationId).scoutAutomationId || null,
          automationName: `My Buddy item ${entry.conversationId}`
        })));
      }
      requireValue(req.method === 'POST', 'Route not found.', 404);
      requireValue(req.headers['x-buddy-action'] === '1', 'Missing action header.', 403);
      const data = await body(req);
      if (route === '/api/scan' || route === '/api/refresh') {
        return send(res, 202, await scans.request());
      }
      if (route.startsWith('/api/scan/')) {
        requireValue(equal(bearer, token), 'Scout scan authentication required.', 403);
        if (route === '/api/scan/dispatch') return send(res, 200, await scans.dispatch(text(data.scanId, 100)));
        if (route === '/api/scan/claim') return send(res, 200, await scans.claim());
        if (route === '/api/scan/commit') return send(res, 200, await scans.commit(data));
        if (route === '/api/scan/fail-dispatch') return send(res, 200,
          await scans.failDispatch(text(data.scanId, 100), text(data.dispatchToken, 64), text(data.error, 3000)));
      }
      if (route.startsWith('/api/scout/')) {
        requireValue(equal(bearer, token), 'Scout bridge authentication required.', 403);
        if (route === '/api/scout/claim') {
          return await mutate(async () => {
            const entry = state.scoutQueue.find(value => value.jobId === data.jobId);
            requireValue(entry?.status === 'queued', 'Scout turn already claimed or unavailable.', 409);
            entry.status = 'dispatching'; entry.claimToken = randomBytes(32).toString('hex');
            conversationById(entry.conversationId).status = 'dispatching';
            await persist();
            return send(res, 200, { ...entry, automationId: conversationById(entry.conversationId).scoutAutomationId || null,
              automationName: `My Buddy item ${entry.conversationId}` });
          });
        }
        if (route === '/api/scout/bind') {
          return await mutate(async () => {
            const entry = state.scoutQueue.find(value => value.jobId === data.jobId);
            requireValue(entry?.status === 'dispatching' && equal(data.claimToken, entry.claimToken), 'Invalid Scout claim.', 409);
            const conversation = conversationById(entry.conversationId);
            const automationId = text(data.automationId, 100);
            requireValue(/^[a-zA-Z0-9-]+$/.test(automationId), 'Invalid automation ID.');
            requireValue(!conversation.scoutAutomationId || conversation.scoutAutomationId === automationId, 'Cannot change a work item to a different Scout automation.', 409);
            conversation.scoutAutomationId = automationId;
            entry.status = 'dispatched'; conversation.status = 'queued-scout';
            await persist(); return send(res, 200, { bound: true });
          });
        }
        if (route === '/api/scout/take') {
          return await mutate(async () => {
            const conversation = conversationById(text(data.conversationId, 100));
            const entry = state.scoutQueue.find(value => value.conversationId === conversation.id && value.status === 'dispatched');
            if (!entry) return send(res, 200, { available: false });
            const job = state.jobs.find(value => value.id === entry.jobId);
            entry.status = 'running'; entry.completionToken = randomBytes(32).toString('hex');
            job.status = 'running-scout'; conversation.status = 'running-scout';
            await persist();
            return send(res, 200, {
              available: true, jobId: job.id, conversationId: conversation.id, completionToken: entry.completionToken,
              task: job.task, mode: job.mode, item: conversation.itemSnapshot,
              turns: conversation.turns, automationId: conversation.scoutAutomationId,
              sessionId: conversation.scoutSessionId || null,
              contract: 'Execute only the explicitly approved user turn. Prepare replies/actions but never send, post, resolve, vote, merge or push. Return questions/results to this conversation; only the user can mark it done.'
            });
          });
        }
        if (route === '/api/scout/fail-dispatch') {
          return await mutate(async () => {
            const entry = state.scoutQueue.find(value => value.jobId === data.jobId);
            requireValue(entry && ['dispatching', 'dispatched'].includes(entry.status) &&
              equal(data.claimToken, entry.claimToken), 'Invalid dispatch failure report.', 409);
            finishConversation(state.jobs.find(value => value.id === entry.jobId), null, text(data.error, 6000));
            entry.status = 'failed';
            await persist(); return send(res, 200, { recorded: true });
          });
        }
        if (route === '/api/scout/complete') {
          return await mutate(async () => {
            const entry = state.scoutQueue.find(value => value.jobId === data.jobId);
            requireValue(entry && equal(data.completionToken, entry.completionToken), 'Invalid Scout completion token.', 409);
            const response = text(data.response, 200000);
            const digest = hash(response);
            if (entry.status === 'completed') {
              requireValue(entry.responseHash === digest, 'Turn already completed with different content.', 409);
              return send(res, 200, { recorded: true, duplicate: true });
            }
            requireValue(entry.status === 'running', 'Scout turn is not running.', 409);
            const conversation = conversationById(entry.conversationId);
            if (data.sessionId) {
              requireValue(/^[a-f0-9-]{36}$/i.test(data.sessionId), 'Invalid Scout session ID.');
              requireValue(!conversation.scoutSessionId || conversation.scoutSessionId === data.sessionId, 'Scout session changed unexpectedly.', 409);
              conversation.scoutSessionId = data.sessionId;
            }
            finishConversation(state.jobs.find(value => value.id === entry.jobId), { assessment: response }, data.failed ? response : null);
            entry.status = 'completed'; entry.responseHash = digest;
            await persist(); return send(res, 200, { recorded: true });
          });
        }
        throw new HttpError(404, 'Unknown Scout bridge operation.');
      }
      if (route === '/api/ingest') {
        requireValue(Array.isArray(data.items) && data.items.length <= 300, 'Invalid briefing items.');
        requireValue(Array.isArray(data.sources) && data.sources.length > 0 &&
          data.sources.every(source => sources.includes(source)), 'Invalid source scope.');
        const items = data.items.map(normalizeItem).filter(Boolean);
        requireValue(items.every(item => data.sources.includes(item.source)), 'Item outside supplied source scope.');
        requireValue(new Set(items.map(item => item.id)).size === items.length, 'Duplicate briefing IDs.');
        const coverageBySource = {};
        for (const source of data.sources) {
          const coverage = data.coverage?.[source];
          requireValue(coverage && ['complete', 'partial', 'failed'].includes(coverage.status), 'Provide honest source coverage.');
          coverageBySource[source] = {
            status: coverage.status, note: optionalText(coverage.note, 3000),
            asOf: optionalText(data.asOf, 100), provenance: 'Scout briefing'
          };
        }
        requireValue(items.every(item => coverageBySource[item.source].status !== 'failed'),
          'Use partial coverage, not failed, when supplying current items.');
        await mutate(async () => {
          mergeItems(items, data.sources.filter(source => coverageBySource[source].status !== 'failed'));
          for (const source of data.sources) {
            if (coverageBySource[source].status !== 'complete') coverageBySource[source].previousItemsRetained = true;
            if (coverageBySource[source].status === 'failed') {
              coverageBySource[source].attemptedAt = coverageBySource[source].asOf;
              coverageBySource[source].asOf = state.coverage[source]?.asOf;
              for (const item of state.items.filter(entry => entry.source === source)) item.retainedFromPreviousScan = true;
            }
          }
          Object.assign(state.coverage, coverageBySource);
          await persist();
        });
        return send(res, 200, { imported: items.length, excluded: data.items.length - items.length });
      }
      if (route === '/api/feedback') {
        const id = text(data.id, 500);
        itemById(id);
        requireValue(['open', 'done', 'dismissed', 'waiting'].includes(data.status), 'Unknown feedback status.');
        if (['done', 'dismissed'].includes(data.status)) await refreshNative(true);
        await mutate(async () => {
          const conversation = conversationByItem(id);
          requireValue(!(['done', 'dismissed'].includes(data.status) && busy(conversation)), 'Wait for the current turn to finish before closing this item.', 409);
          state.feedback[id] = { status: data.status, note: optionalText(data.note, 3000), updatedAt: new Date().toISOString() };
          if (conversation) {
            if (['done', 'dismissed'].includes(data.status)) conversation.status = 'closed';
            else if (conversation.status === 'closed') conversation.status = 'awaiting-user';
          }
          await persist();
        });
        return send(res, 200, { saved: true });
      }
      if (route === '/api/open-session') {
        const conversation = conversationByItem(text(data.id, 500));
        requireValue(conversation?.handler === 'cli', 'This item has no linked Copilot CLI conversation.', 409);
        requireValue(/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(conversation.sessionId || ''),
          'The original CLI session ID is missing. No replacement session was created.', 409);
        requireValue(conversation.input?.repository, 'The saved checkout mapping is missing.', 409);
        const native = conversation.execution === 'native-interactive';
        requireValue(native || !busy(conversation), 'The background turn is still running. Wait for it to finish before opening the interactive session.', 409);
        requireValue(typeof adapter.openSession === 'function', 'Native CLI handoff is unavailable on this host.', 503);
        // Use only the saved link, never a browser-supplied session, path, agent or prompt.
        const key = conversation.sessionId;
        let operation = openingSessions.get(key);
        if (!operation) {
          operation = (async () => {
            const result = await adapter.openSession({
              sessionId: conversation.sessionId, repository: conversation.input.repository,
              sessionTitle: conversation.sessionTitle || workSessionTitle(conversation.itemSnapshot, conversation.input.repository),
              ...(native ? { focusOnly: conversation.native?.safeToClose !== true } : {})
            });
            requireValue(result.sessionId === conversation.sessionId && result.promptSubmitted === false &&
              ['opened', 'focused', 'attention-requested', 'already-running', 'checkout-busy', 'unavailable'].includes(result.status),
              'Native handoff returned an invalid result.', 502);
            await mutate(async () => {
              if (result.sessionTitle) conversation.sessionTitle = text(result.sessionTitle, 500);
              const navigated = ['opened','focused','attention-requested'].includes(result.status);
              if (navigated) conversation.nativeOpenedAt = new Date().toISOString();
              conversation.nativeOpenStatus = result.status;
              if (!native && conversation.status !== 'closed' && navigated) conversation.status = 'in-cli';
              if (native && result.status === 'opened') {
                conversation.native = { status:'native-active', runtimeActive:true, safeToClose:false,
                  promptSubmitted:false, activity:'working-or-awaiting-input', message:'Saved session reopened without submitting any prompt.' };
                if (conversation.status !== 'closed') conversation.status = 'native-active';
              }
              await persist();
            });
            return result;
          })();
          openingSessions.set(key, operation);
        }
        try { return send(res, 200, await operation); }
        finally { if (openingSessions.get(key) === operation) openingSessions.delete(key); }
      }
      if (route === '/api/preview' || route === '/api/reply-preview') {
        const item = itemById(text(data.id, 500));
        const existing = conversationByItem(item.id);
        const continuing = route === '/api/reply-preview';
        if (continuing) {
          requireValue(existing && existing.status !== 'closed', 'Open the work item conversation first.', 409);
          requireValue(existing.handler === 'scout', 'Continue this conversation in Copilot CLI using the linked session button.', 409);
          requireValue(!busy(existing), 'Wait for the current turn to finish.', 409);
          requireValue(existing.input, 'This older task has no saved handoff configuration; its history is preserved but cannot be resumed automatically.', 409);
          requireValue(existing.handler === 'scout' || existing.sessionId, 'The original CLI session ID is unavailable.', 409);
        } else {
          requireValue(!existing, 'Use Continue conversation for this item instead of opening another session.', 409);
        }
        const input = continuing ? {
          ...existing.input, task: text(data.task, 24000), sourceRef: sourceReference(item),
          sessionId: existing.sessionId, resumeSession: existing.handler === 'cli'
        } : {
          repository: text(data.repository, 100), mode: data.mode,
          agent: data.agent == null ? '__default_cli__' : text(data.agent, 150),
          permissionMode: data.permissionMode || 'native',
          task: text(data.task, 24000), sourceRef: sourceReference(item),
          initializeEnvironment: data.initializeEnvironment === true,
          sessionId: randomUUID(), resumeSession: false
        };
        const handler = continuing ? existing.handler : input.agent === '__scout__' ? 'scout' : 'cli';
        requireValue(handler !== 'scout' || adapter.supportsScoutTasks !== false,
          'Scout task dispatch has been retired. Choose Default CLI or an XFE agent; Scout still performs source scans.', 409);
        if (handler === 'cli') input.sessionTitle = workSessionTitle(item, input.repository);
        requireValue(['review', 'develop', 'specify'].includes(input.mode), 'Choose review, local development or Specify.');
        requireValue(handler === 'scout' || input.agent === '__default_cli__' || /^xfe-/i.test(input.agent), 'Choose Scout, Default CLI or an XFE-* agent.');
        if (handler === 'scout') {
          requireValue(input.mode !== 'develop', 'Use Specify to tell Scout what to do.');
          input.permissionMode = 'native'; input.initializeEnvironment = false; input.sessionId = null;
        }
        requireValue(['native', 'full'].includes(input.permissionMode), 'Invalid permission mode.');
        requireValue(input.permissionMode !== 'full' || input.mode === 'specify', 'Full tool auto-approval requires Specify mode.');
        requireValue(input.task.trim(), 'Describe the exact task.');
        const version = item.version;
        const plan = handler === 'scout' ? {
          requestId: randomUUID(), agent: '__scout__', agentLabel: 'Scout', mode: input.mode,
          permissionMode: 'native', workingDirectory: 'Scout work-item conversation', sourceRef: input.sourceRef,
          task: input.task, configuredMcpServers: [], initializationScript: null, timeoutSeconds: null,
          prompt: 'Scout will process the approved task in a persistent per-item conversation. It may read relevant work context, return questions and prepare actions. No external publication is approved.',
          publicationAuthorized: false, approvalHash: hash({ input, version, handler })
        } : await adapter.preview(input);
        if (handler === 'cli' && plan.sessionTitle) input.sessionTitle = text(plan.sessionTitle, 500);
        if (handler === 'cli' && adapter.launchNative) {
          requireValue(plan.execution === 'native-interactive' && plan.sessionId === input.sessionId &&
            plan.timeoutSeconds === null, 'Bridge did not preview a visible native launch. Hidden execution is not permitted.', 502);
        }
        requireValue(plan.publicationAuthorized === false && plan.approvalHash && plan.requestId, 'Bridge returned an invalid approval plan.', 502);
        requireValue(itemById(item.id).version === version, 'Source changed while preparing the preview.', 409);
        const previewId = randomUUID();
        for (const [id, existing] of plans) { if (existing.expires <= Date.now()) plans.delete(id); }
        requireValue(plans.size < 1000, 'Too many pending previews; wait for old previews to expire.', 429);
        plans.set(previewId, { input, plan, itemId: item.id, version, handler, continuing,
          conversationId: existing?.id || randomUUID(), turnCount: existing?.turns.length || 0,
          expires: Date.now() + 15 * 60_000 });
        return send(res, 200, { previewId, plan, itemVersion: version });
      }
      if (route === '/api/approve') {
        const previewId = text(data.previewId, 100);
        const saved = plans.get(previewId);
        requireValue(saved && saved.expires > Date.now(), 'Preview expired or already consumed. Preview again.', 409);
        requireValue(data.approvalHash === saved.plan.approvalHash && data.confirmed === true, 'Explicit confirmation of the exact preview is required.');
        const item = itemById(saved.itemId);
        requireValue(item.version === saved.version, 'Source changed. Preview again.', 409);
        requireValue(!busy(conversationByItem(item.id)), 'This item already has a running task.', 409);
        // Consume before asynchronous validation, so double-clicks cannot launch twice.
        plans.delete(previewId);
        if (isPullRequest(item)) await adapter.verifySource(item);
        const job = { id: saved.plan.requestId, itemId: item.id, conversationId: saved.conversationId, title: item.title,
          mode: saved.input.mode, status: saved.handler === 'scout' ? 'queued-scout' : 'running', startedAt: new Date().toISOString(),
          task: saved.input.task, agent: saved.plan.agent, input: saved.input, permissionMode: saved.input.permissionMode, publicationAuthorized: false };
        const native = saved.handler === 'cli' && saved.plan.execution === 'native-interactive';
        if (native) {
          job.execution = 'native-interactive'; job.status = 'native-starting';
          job.launchNotAfter = new Date(Date.now() + 60_000).toISOString();
        }
        await mutate(async () => {
          requireValue(itemById(item.id).version === saved.version, 'Source changed while validating approval.', 409);
          let conversation = conversationByItem(item.id);
          requireValue(!busy(conversation), 'This item already has a running task.', 409);
          requireValue(saved.continuing ? conversation?.turns.length === saved.turnCount : !conversation, 'Conversation changed. Preview again.', 409);
          const beforeConversation = conversation ? clone(conversation) : null;
          const beforeFeedback = state.feedback[item.id];
          if (!conversation) {
            conversation = { id: saved.conversationId, itemId: item.id, itemSnapshot: clone(item), handler: saved.handler,
              input: saved.input, sessionId: saved.handler === 'cli' ? saved.input.sessionId : null,
              ...(saved.handler === 'cli' ? { sessionTitle: saved.plan.sessionTitle || saved.input.sessionTitle } : {}), turns: [] };
            state.conversations.push(conversation);
          }
          conversation.status = saved.handler === 'scout' ? 'queued-scout' : 'running';
          if (native) {
            conversation.execution = 'native-interactive'; conversation.status = 'native-starting';
            conversation.native = { status:'native-starting', safeToClose:false, promptSubmitted:false,
              activity:'awaiting-native-startup-or-input', message:'Starting the approved native task. No result is available yet.' };
          }
          addTurn(conversation, 'user', saved.input.task);
          if (saved.handler === 'scout') state.scoutQueue.push({ jobId: job.id, conversationId: conversation.id, status: 'queued' });
          state.feedback[item.id] = { ...(state.feedback[item.id] || {}), status: 'open' };
          state.jobs.unshift(job);
          try { await persist(); }
          catch (error) {
            state.jobs = state.jobs.filter(entry => entry.id !== job.id);
            state.scoutQueue = state.scoutQueue.filter(entry => entry.jobId !== job.id);
            state.conversations = state.conversations.filter(entry => entry.id !== saved.conversationId);
            if (beforeConversation) state.conversations.push(beforeConversation);
            if (beforeFeedback) state.feedback[item.id] = beforeFeedback;
            else delete state.feedback[item.id];
            throw error;
          }
        });
        if (saved.handler === 'cli') {
          if (native) void launchNative(job, saved);
          else void runJob(job, saved);
        }
        return send(res, 202, { jobId: job.id, conversationId: job.conversationId, status: job.status });
      }
      throw new HttpError(404, 'Route not found.');
    } catch (error) {
      if (!res.headersSent) send(res, error.status || 500, { error: cleanError(error.message) });
      else res.end();
    }
  });
  server.requestTimeout = 120_000;
  server.headersTimeout = 15_000;
  return {
    server, token,
    async listen(port = 0) {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, '127.0.0.1', resolve);
      });
      origin = `http://127.0.0.1:${server.address().port}`;
      await refreshNative(true);
      await scans.recover();
      return origin;
    },
    async close() {
      await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      await mutationChain;
      await saveChain;
    }
  };
}

function runPowerShell(script, args = [], input = '') {
  return new Promise((resolve, reject) => {
    const child = spawn('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', script, ...args], {
      cwd: packageDirectory, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'], shell: false,
      env: { ...process.env, NO_COLOR: '1', TERM: 'dumb' }
    });
    let output = '', errors = '', oversized = false;
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', part => {
      if (output.length + part.length > 4_000_000) oversized = true;
      output = (output + part).slice(0, 4_000_000);
    });
    child.stderr.on('data', part => { errors = (errors + part).slice(-16000); });
    child.on('error', reject);
    child.stdin.on('error', error => { if (error.code !== 'EPIPE') reject(error); });
    child.on('close', code => {
      if (oversized) reject(new Error('Bridge output exceeded its limit; inspect the underlying session.'));
      else if (code !== 0) reject(new Error(cleanError(errors || `PowerShell bridge exited ${code}.`)));
      else resolve(output.replace(/^\uFEFF/, '').trim());
    });
    child.stdin.end(input);
  });
}
async function bridge(operation, values = {}) {
  const output = await runPowerShell(path.join(directory, 'Invoke-PortalBridge.ps1'), [], JSON.stringify({ operation, ...values }));
  try { return JSON.parse(output); } catch { throw new Error('PowerShell bridge did not return valid JSON.'); }
}

export async function main() {
  requireValue(process.platform === 'win32', 'The encrypted local portal currently requires Windows.');
  const dataDirectory = path.join(process.env.LOCALAPPDATA || os.homedir(), 'MyBuddy', 'portal');
  await mkdir(dataDirectory, { recursive: true });
  const protectedFile = path.join(dataDirectory, 'state.dpapi');
  const connectionFile = path.join(dataDirectory, 'connection.dpapi');
  const protector = path.join(directory, 'Protect-PortalData.ps1');
  let initial;
  try {
    const encrypted = await readFile(protectedFile);
    if (encrypted.length) initial = JSON.parse(await runPowerShell(protector, ['-Operation', 'read', '-Path', protectedFile]));
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const adapter = {
    supportsScoutTasks: false,
    doctor: () => bridge('doctor'),
    scanConfig: async () => JSON.parse(await readFile(path.join(packageDirectory, 'buddy.config.json'), 'utf8')),
    collect: input => bridge('collect', input || { asOf: new Date().toISOString() }),
    collectGitHub: input => bridge('collect-github', input || { asOf: new Date().toISOString() }),
    preview: input => bridge('preview', { input }),
    launchNative: (input, plan, launchNotAfter) => bridge('launch-native', { input, plan, launchNotAfter }),
    nativeStatus: input => bridge('native-status', { input }),
    openSession: input => bridge('open-session', { input }),
    async verifySource(item) {
      requireValue(item.headCommit && item.pullRequestId && item.repository, 'Missing PR revision; refresh PRs before approval.', 409);
      const snapshot = await bridge(item.source === 'github' ? 'collect-github' : 'collect',
        { asOf: new Date().toISOString(), repository: item.repository, pullRequestId: item.pullRequestId });
      assertCurrentPullRequest(item, snapshot);
    }
  };
  const portal = createPortal({
    adapter, initial, html: await readFile(path.join(directory, 'index.html'), 'utf8'),
    logo: await readFile(path.join(directory, 'buddy-logo.svg'), 'utf8'),
    save: value => runPowerShell(protector, ['-Operation', 'write', '-Path', protectedFile], JSON.stringify(value))
  });
  const origin = await portal.listen(Number(process.env.MY_BUDDY_PORT || 0));
  await runPowerShell(protector, ['-Operation', 'write', '-Path', connectionFile], JSON.stringify({
    origin, token: portal.token, pid: process.pid, startedAt: new Date().toISOString(), packageDirectory
  }));
  console.log(`My Buddy Portal listening at ${origin}`);
  console.log('Private state and connection details are encrypted for the current Windows user.');
  console.log('Open with Start-BuddyPortal.ps1 -Open. No tasks run automatically.');
  return portal;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
