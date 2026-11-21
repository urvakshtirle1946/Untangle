import { createClient } from 'npm:@supabase/supabase-js@2';

const systemPrompt = `You are a thoughtful, natural voice conversation partner. Keep replies concise and conversational. Respond to greetings like hi or hello naturally; do not force an idea-related question. When the user shares an idea or thought, acknowledge its specific content and ask one genuine, relevant follow-up when useful. Use the conversation history, remember what the user has answered, and do not repeat answered questions or turn every response into an interview. Answer direct questions first; add a follow-up only when it helps. Do not invent details, claim to create or save anything, or create a thought card.`;
const summaryPrompt = `Create a concise, faithful note summary from the supplied transcript. Return only valid JSON with this shape: {"title":"short title","sections":[{"heading":"section heading","bullets":["fact or action"]}]}. Choose section headings that fit the content. Use only information present in the transcript. Do not include markdown fences. Use 1 to 8 bullets per section and 1 to 12 sections. Keep the title under 160 characters, headings under 80 characters, and each bullet under 500 characters.`;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-request-id, x-conv-session-id, x-listen-generation',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(
  status: number,
  body: Record<string, unknown>,
  requestId?: string,
): Response {
  return new Response(JSON.stringify(
    requestId ? { ...body, request_id: requestId } : body,
  ), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function sanitizeProviderCode(value: unknown): string {
  if (typeof value !== 'string') return 'unclassified';
  const code = value.trim().toLowerCase();
  const knownCodes = new Set([
    'invalid_api_key',
    'authentication_error',
    'unauthorized',
    'permission_denied',
    'model_not_found',
    'invalid_model',
    'unsupported_model',
    'rate_limit_exceeded',
    'insufficient_quota',
    'invalid_request_error',
    'bad_request',
    'unsupported_parameter',
    'overloaded_error',
    'server_error',
  ]);
  return knownCodes.has(code) ? code : 'unclassified';
}

function sanitizeProviderMessage(value: unknown): string {
  if (typeof value !== 'string') return 'Provider returned no diagnostic message.';
  const message = value.toLowerCase();
  if (/api.?key|credential|authentication|unauthorized|invalid.?token/.test(message)) {
    return 'Provider authentication was rejected.';
  }
  if (/model.{0,40}(not found|unavailable|unsupported|invalid)|(?:not found|unavailable|unsupported|invalid).{0,40}model/.test(message)) {
    return 'The configured provider model is unavailable or invalid.';
  }
  if (/rate.?limit|quota|too many requests/.test(message)) {
    return 'The provider rate limit or quota was reached.';
  }
  if (/unsupported parameter|invalid parameter|invalid request|bad request/.test(message)) {
    return 'The provider rejected the request parameters.';
  }
  if (/overload|temporarily unavailable|service unavailable|try again later/.test(message)) {
    return 'The provider is temporarily unavailable.';
  }
  if (/safety|content.?filter|policy/.test(message)) {
    return 'The provider rejected the request under its safety policy.';
  }
  return 'The provider rejected the request with an unclassified error.';
}

async function providerErrorDiagnostics(response: Response): Promise<{
  code: string;
  message: string;
}> {
  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    return {
      code: 'unclassified',
      message: 'Provider returned an unreadable error response.',
    };
  }
  const root = payload && typeof payload === 'object'
    ? payload as Record<string, unknown>
    : {};
  const error = root.error && typeof root.error === 'object'
    ? root.error as Record<string, unknown>
    : root;
  return {
    code: sanitizeProviderCode(error.code ?? error.type),
    message: sanitizeProviderMessage(error.message ?? root.message),
  };
}

Deno.serve(async (request: Request) => {
  const functionStartedAt = performance.now();
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const suppliedRequestId = request.headers.get('x-request-id') ?? '';
  const requestId = /^[A-Za-z0-9._:-]{1,80}$/.test(suppliedRequestId)
    ? suppliedRequestId
    : crypto.randomUUID();
  const suppliedSessionId = request.headers.get('x-conv-session-id') ?? '';
  const sessionId = /^[A-Za-z0-9._:-]{1,100}$/.test(suppliedSessionId)
    ? suppliedSessionId
    : 'unknown';
  const parsedListenGeneration = Number(request.headers.get('x-listen-generation'));
  const listenGeneration = Number.isSafeInteger(parsedListenGeneration) && parsedListenGeneration >= 0
    ? parsedListenGeneration
    : -1;
  const diag = (event: string, details = '') => {
    console.info(
      `[conv-diag] elapsed_ms=${Math.round(performance.now() - functionStartedAt)} session_id=${sessionId} listen_generation=${listenGeneration} sessionActive=true requestPending=true request_id=${requestId} ${event}${details ? ` ${details}` : ''}`,
    );
  };
  const respond = (status: number, body: Record<string, unknown>) => {
    diag('event=request_complete', `status=${status} total_ms=${Math.round(performance.now() - functionStartedAt)}`);
    return json(status, body, requestId);
  };
  if (request.method !== 'POST') return respond(405, { error: 'Use POST for conversation requests.' });

  const authorization = request.headers.get('Authorization') ?? '';
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    diag('event=jwt_check', 'status=missing_bearer elapsed_ms=0');
    return respond(401, { error: 'Sign in before starting an AI conversation.' });
  }
  const token = match[1];

  const projectUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  if (!projectUrl || !anonKey) return respond(503, { error: 'Conversation service is not configured.' });
  const supabase = createClient(projectUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const jwtStartedAt = performance.now();
  const { data: authData, error: authError } = await supabase.auth.getUser(token);
  diag('event=jwt_check', `status=${authError || !authData.user ? 401 : 200} elapsed_ms=${Math.round(performance.now() - jwtStartedAt)}`);
  if (authError || !authData.user) return respond(401, { error: 'Your sign-in has expired. Sign in again.' });

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return respond(400, { error: 'Request body must be valid JSON.' });
  }
  const action = (payload as { action?: unknown })?.action ?? 'conversation';
  if (action !== 'conversation' && action !== 'summarize') {
    return respond(400, { error: 'Unsupported AI action.' });
  }
  const providerMessages: Array<{ role: 'system' | 'user' | 'assistant'; content: string }> = [];
  let summaryAction = false;
  if (action === 'summarize') {
    const transcript = (payload as { transcript?: unknown }).transcript;
    if (typeof transcript !== 'string' || !transcript.trim()) {
      return respond(400, { error: 'A transcript is required for summary generation.' });
    }
    if (transcript.length > 12000) return respond(413, { error: 'The transcript is too long to summarize.' });
    summaryAction = true;
    providerMessages.push({ role: 'system', content: summaryPrompt });
    providerMessages.push({ role: 'user', content: transcript });
  } else {
    const messages = (payload as { messages?: unknown })?.messages;
    if (!Array.isArray(messages) || messages.length === 0 || messages.length > 12) {
      return respond(400, { error: 'Conversation history must contain 1 to 12 messages.' });
    }
    let totalCharacters = 0;
    const validMessages: Array<{ role: 'user' | 'assistant'; content: string }> = [];
    for (const item of messages) {
      if (!item || typeof item !== 'object') return respond(400, { error: 'Invalid conversation message.' });
      const role = (item as { role?: unknown }).role;
      const content = (item as { content?: unknown }).content;
      if ((role !== 'user' && role !== 'assistant') || typeof content !== 'string' || !content.trim()) {
        return respond(400, { error: 'Messages need a user or assistant role and non-empty text.' });
      }
      if (content.length > 4000) return respond(413, { error: 'A conversation message is too long.' });
      totalCharacters += content.length;
      validMessages.push({ role, content });
    }
    if (totalCharacters > 12000) return respond(413, { error: 'Conversation history is too long.' });
    if (validMessages[validMessages.length - 1].role !== 'user') {
      return respond(400, { error: 'The latest conversation message must be from the user.' });
    }
    providerMessages.push({ role: 'system', content: systemPrompt }, ...validMessages);
  }

  const apiKey = Deno.env.get('NVIDIA_API_KEY');
  const model = Deno.env.get('NVIDIA_MODEL');
  if (!apiKey || !model) return respond(503, { error: 'Conversation service is not configured by the project administrator.' });

  const limitStartedAt = performance.now();
  const { data: withinLimit, error: limitError } = await supabase.rpc('consume_ai_request_limit', {
    p_max_requests: 10,
    p_window_seconds: 60,
  });
  diag('event=limit_check', `status=${limitError ? 'error' : withinLimit === true ? 'allowed' : 'limited'} elapsed_ms=${Math.round(performance.now() - limitStartedAt)}`);
  if (limitError) return respond(503, { error: 'Request limits are not configured. Apply the database migration.' });
  if (withinLimit !== true) return respond(429, { error: 'Conversation request limit reached. Wait a minute and try again.' });

  let providerResponse: Response;
  const providerStartedAt = performance.now();
  const enableThinking = false;
  const loggedModel = model.replace(/[^A-Za-z0-9._/-]/g, '?').slice(0, 100);
  diag('event=inference_start', `model=${loggedModel} enable_thinking_sent=${enableThinking}`);
  try {
    providerResponse = await fetch('https://integrate.api.nvidia.com/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages: providerMessages,
        max_tokens: summaryAction ? 4096 : 2048,
        stream: false,
        temperature: 0.3,
        chat_template_kwargs: { enable_thinking: enableThinking },
      }),
      signal: AbortSignal.timeout(25000),
    });
  } catch (error) {
    diag('event=inference_end', `status=transport_error provider_ms=${Math.round(performance.now() - providerStartedAt)} total_ms=${Math.round(performance.now() - functionStartedAt)}`);
    return respond(error instanceof DOMException && error.name === 'TimeoutError' ? 504 : 502, {
      error: error instanceof DOMException && error.name === 'TimeoutError'
        ? 'The AI provider timed out. Please try again.'
        : 'Could not reach the AI provider. Please try again.',
    });
  }
  diag('event=inference_end', `status=${providerResponse.status} upstream_status=${providerResponse.status} provider_ms=${Math.round(performance.now() - providerStartedAt)} total_ms=${Math.round(performance.now() - functionStartedAt)}`);
  if (!providerResponse.ok) {
    const diagnostics = await providerErrorDiagnostics(providerResponse);
    diag('event=provider_rejected', `status=${providerResponse.status} upstream_status=${providerResponse.status} code=${diagnostics.code} message="${diagnostics.message}" finish_reason=unavailable completion_tokens=unavailable`);
    const status = providerResponse.status === 429 ? 429 : 502;
    return respond(status, { error: providerResponse.status === 429
      ? 'The AI provider is busy or its quota was reached. Please try again later.'
      : 'The AI provider rejected the request. Check the server model and key configuration.' });
  }

  let providerData: {
    choices?: Array<{
      finish_reason?: unknown;
      message?: { content?: unknown };
    }>;
    usage?: { completion_tokens?: unknown };
  };
  try {
    providerData = await providerResponse.json();
  } catch {
    return respond(502, { error: 'The AI provider returned an invalid response.' });
  }
  const choice = providerData.choices?.[0];
  const content = choice?.message?.content;
  const finishReason = typeof choice?.finish_reason === 'string'
    ? choice.finish_reason.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 40) || 'unknown'
    : 'none';
  const completionTokens = Number.isInteger(providerData.usage?.completion_tokens)
    ? providerData.usage?.completion_tokens
    : 'none';
  diag('event=provider_result', `upstream_status=${providerResponse.status} finish_reason=${finishReason} completion_tokens=${completionTokens}`);
  if (typeof content !== 'string') {
    diag('event=provider_invalid_reply', `upstream_status=${providerResponse.status} code=missing_message_content`);
    return respond(502, { error: 'The AI provider returned no reply. Please try again.' });
  }
  const reply = content.trim();
  if (reply.length === 0) {
    diag('event=provider_invalid_reply', `upstream_status=${providerResponse.status} code=empty_message_content`);
    return respond(502, { error: 'The AI provider returned no reply. Please try again.' });
  }
  if (summaryAction) {
    if (finishReason === 'length') {
      diag('event=summary_rejected', 'code=length_truncation');
      return respond(502, { error: 'The AI summary was incomplete. Please retry.' });
    }
    let summary: unknown;
    try {
      summary = JSON.parse(reply);
    } catch {
      diag('event=summary_rejected', 'code=invalid_json');
      return respond(502, { error: 'The AI provider returned an invalid summary.' });
    }
    if (!summary || typeof summary !== 'object') {
      diag('event=summary_rejected', 'code=invalid_shape');
      return respond(502, { error: 'The AI provider returned an invalid summary.' });
    }
    const candidate = summary as { title?: unknown; sections?: unknown };
    if (typeof candidate.title !== 'string' || !candidate.title.trim() || candidate.title.length > 160 ||
        !Array.isArray(candidate.sections) || candidate.sections.length < 1 || candidate.sections.length > 12) {
      diag('event=summary_rejected', 'code=invalid_shape');
      return respond(502, { error: 'The AI provider returned an invalid summary.' });
    }
    for (const section of candidate.sections) {
      if (!section || typeof section !== 'object') {
        diag('event=summary_rejected', 'code=invalid_section');
        return respond(502, { error: 'The AI provider returned an invalid summary.' });
      }
      const item = section as { heading?: unknown; bullets?: unknown };
      if (typeof item.heading !== 'string' || !item.heading.trim() || item.heading.length > 80 ||
          !Array.isArray(item.bullets) || item.bullets.length < 1 || item.bullets.length > 8 ||
          item.bullets.some((bullet) => typeof bullet !== 'string' || !bullet.trim() || bullet.length > 500)) {
        diag('event=summary_rejected', 'code=invalid_section');
        return respond(502, { error: 'The AI provider returned an invalid summary.' });
      }
    }
    return respond(200, { summary: candidate });
  }
  return respond(200, { reply });
});
