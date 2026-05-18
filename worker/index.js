// Claude Meter CORS proxy.
//
// Relays two upstream endpoints used by the web build and adds CORS headers
// so a browser can reach them. The Worker never stores or logs tokens — it
// just forwards the request and response unchanged (aside from headers).
//
// Routes:
//   GET  /usage  -> https://api.anthropic.com/api/oauth/usage
//   POST /token  -> https://platform.claude.com/v1/oauth/token

const UPSTREAMS = {
  '/usage': {
    url: 'https://api.anthropic.com/api/oauth/usage',
    methods: ['GET'],
  },
  '/token': {
    url: 'https://platform.claude.com/v1/oauth/token',
    methods: ['POST'],
  },
};

// Tighten this with your deployed origin(s) once you know the GH Pages URL.
// `*` works for development but won't allow credentialed requests (we don't
// use cookies, so `*` is fine — Authorization header is forwarded explicitly).
const ALLOWED_ORIGIN = '*';

const corsHeaders = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers':
    'Authorization, Content-Type, anthropic-beta',
  'Access-Control-Max-Age': '86400',
};

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (url.pathname === '/' || url.pathname === '/health') {
      return new Response('claude-meter worker ok', {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'text/plain' },
      });
    }

    const route = UPSTREAMS[url.pathname];
    if (!route) {
      return new Response('Not found', { status: 404, headers: corsHeaders });
    }
    if (!route.methods.includes(request.method)) {
      return new Response('Method not allowed', {
        status: 405,
        headers: corsHeaders,
      });
    }

    const headers = new Headers();
    const auth = request.headers.get('authorization');
    if (auth) headers.set('Authorization', auth);
    const ct = request.headers.get('content-type');
    if (ct) headers.set('Content-Type', ct);
    const beta = request.headers.get('anthropic-beta');
    if (beta) headers.set('anthropic-beta', beta);

    const body =
      request.method === 'GET' || request.method === 'HEAD'
        ? undefined
        : await request.arrayBuffer();

    const upstream = await fetch(route.url, {
      method: request.method,
      headers,
      body,
    });

    const out = new Headers(corsHeaders);
    const passthrough = ['content-type', 'cache-control', 'retry-after'];
    for (const name of passthrough) {
      const v = upstream.headers.get(name);
      if (v) out.set(name, v);
    }
    return new Response(upstream.body, {
      status: upstream.status,
      headers: out,
    });
  },
};
