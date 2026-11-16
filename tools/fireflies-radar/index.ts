import { createHandler } from './handler.mjs';
import { createRpc, createWorker } from './worker.mjs';
import { prepareTranscript, buildAnalysisRequest, validateAndMaterializeAnalysis } from './analyzer.mjs';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

// These credentials are injected by Supabase into its own Edge runtime.
// No owner JWT, browser token, API key or transcript is embedded in source.
const rpc = createRpc({
  url: (Deno.env.get('SUPABASE_URL') || '').replace(/\/$/, ''),
  serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '',
});
const runOneJob = createWorker({rpc, prepareTranscript, buildAnalysisRequest, validateAndMaterializeAnalysis});
const handler = createHandler({rpc, runOneJob, waitUntil: (promise: Promise<unknown>) => EdgeRuntime.waitUntil(promise)});
Deno.serve(handler);
