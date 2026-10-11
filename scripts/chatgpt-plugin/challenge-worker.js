// Serves the OpenAI apps domain-verification token per hostname.
// Deploy once to workers.dev, then add a zone redirect rule per domain:
//   /.well-known/openai-apps-challenge -> 302 https://<worker>.workers.dev/?h=<domain>
// Zone redirect rules run before Workers custom domains, so the site
// (deployed on a custom domain) never sees the request.
//
// Tokens live in the OPENAI_TOKENS var as JSON: { "example.com": "token" }.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const tokens = JSON.parse(env.OPENAI_TOKENS || '{}');
    const host = (url.searchParams.get('h') || url.hostname).replace(/^www\./, '');
    const token = tokens[host];
    if (!token) return new Response('not found', { status: 404 });
    return new Response(token, { headers: { 'content-type': 'text/plain' } });
  },
};
