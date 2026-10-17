// Run with: node --experimental-strip-types supabase/functions/analyze/guardrails.test.mjs
import assert from 'node:assert/strict';
import { validateAgentOutput, clampStep, buildProposal, summarizeReadings } from './guardrails.ts';

const now = new Date('2026-10-17T12:00:00Z');
const ago = (h) => new Date(now.getTime() - h * 3600000);
const good = { status: 'watch', confidence: 'medium', summary: 'Edges look dry.', observations: ['dry tips'], recommendation: { interval_min: 120, duration_sec: 8, reason: 'Too dry overnight.' } };
const base = (over = {}) => ({
  current: { interval_min: 240, duration_sec: 5 }, maxOnSec: 8,
  output: validateAgentOutput(good).value, avoidHardware: false, lastAppliedAt: null, hasPending: false,
  photoTakenAt: ago(1), latestReadingAt: ago(0.2), now, ...over,
});
let n = 0; const t = (name, fn) => { fn(); n++; console.log('ok  ' + name); };

t('validate accepts a good output', () => assert.equal(validateAgentOutput(good).ok, true));
t('validate rejects bad status', () => assert.equal(validateAgentOutput({ ...good, status: 'dead' }).ok, false));
t('validate rejects non-numeric setting', () => assert.equal(validateAgentOutput({ ...good, recommendation: { interval_min: '5; drop table', reason: 'x' } }).ok, false));
t('validate drops a recommendation with no reason', () => assert.equal(validateAgentOutput({ ...good, recommendation: { interval_min: 100, reason: '' } }).value.recommendation, null));
t('validate ignores unknown recommendation keys', () => { const v = validateAgentOutput({ ...good, recommendation: { interval_min: 200, pin: 25, reason: 'r' } }).value.recommendation; assert.deepEqual(Object.keys(v).sort(), ['interval_min', 'reason']); });
t('validate truncates huge text', () => assert.ok(validateAgentOutput({ ...good, summary: 'x'.repeat(5000) }).value.summary.length <= 500));

t('clamp: 25% step down', () => assert.equal(clampStep(240, 60, 1, 525600), 180));
t('clamp: 25% step up', () => assert.equal(clampStep(240, 1000, 1, 525600), 300));
t('clamp: small numbers may still move by 1', () => { assert.equal(clampStep(2, 9, 1, 8), 3); assert.equal(clampStep(2, 1, 1, 8), 1); });
t('clamp: never above the hardware ceiling', () => assert.equal(clampStep(8, 20, 1, 8), 8));
t('clamp: never below the minimum', () => assert.equal(clampStep(1, 0, 1, 8), 1));

t('proposal: steps are limited', () => { const r = buildProposal(base()); assert.deepEqual(r.proposal.proposed_settings, { interval_min: 180, duration_sec: 6 }); assert.match(r.proposal.reason, /limited/); });
t('proposal: respects hardware ceiling', () => { const r = buildProposal(base({ current: { interval_min: 240, duration_sec: 8 } })); assert.equal(r.proposal.proposed_settings.duration_sec, undefined); });
t('skip: critical', () => assert.match(buildProposal(base({ output: { ...good, status: 'critical' } })).skip, /critical/));
t('skip: low confidence', () => assert.match(buildProposal(base({ output: { ...good, confidence: 'low' } })).skip, /confidence/));
t('skip: avoid rule', () => assert.match(buildProposal(base({ avoidHardware: true })).skip, /avoid/));
t('skip: pending exists', () => assert.match(buildProposal(base({ hasPending: true })).skip, /waiting/));
t('skip: old photo', () => assert.match(buildProposal(base({ photoTakenAt: ago(20) })).skip, /photo/));
t('skip: stale sensor', () => assert.match(buildProposal(base({ latestReadingAt: ago(10) })).skip, /sensor/));
t('skip: no sensor', () => assert.match(buildProposal(base({ latestReadingAt: null })).skip, /sensor/));
t('skip: cooldown', () => assert.match(buildProposal(base({ lastAppliedAt: ago(5) })).skip, /24 hours/));
t('ok: after cooldown', () => assert.ok(buildProposal(base({ lastAppliedAt: ago(30) })).proposal));
t('skip: no recommendation', () => assert.match(buildProposal(base({ output: { ...good, recommendation: null } })).skip, /no change/));
t('skip: same as current', () => assert.match(buildProposal(base({ output: { ...good, recommendation: { interval_min: 240, duration_sec: 5, reason: 'same' } } })).skip, /same/));

t('summarize readings', () => {
  const s = summarizeReadings([{ taken_at: ago(2).toISOString(), temp_c: 20, humidity_pct: 60 }, { taken_at: ago(0.5).toISOString(), temp_c: 22, humidity_pct: 80 }], now);
  assert.deepEqual(s.humidity_pct, { min: 60, max: 80, avg: 70 }); assert.equal(s.latest.minutes_ago, 30);
});
t('summarize empty', () => assert.equal(summarizeReadings([], now).latest, null));

console.log(`\n${n} checks passed`);
