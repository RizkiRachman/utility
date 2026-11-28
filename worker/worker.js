// Agent proxy for the utility source digest.
// Serves the Pages production origin so utility.rizkifaizalr.workers.dev
// always mirrors the latest deploy. Root returns llms.txt so agents that
// fetch the bare URL get the machine index immediately.
const DEFAULT_ORIGIN = "https://utility-digest.pages.dev";

export default {
  async fetch(request, env) {
    const origin = (env && env.DIGEST_ORIGIN ? env.DIGEST_ORIGIN : DEFAULT_ORIGIN).replace(/\/+$/, "");
    const url = new URL(request.url);
    const path = url.pathname === "/" ? "/llms.txt" : url.pathname;
    const target = origin + path + url.search;
    const res = await fetch(target, { redirect: "follow" });
    if (res.ok) {
      const headers = new Headers(res.headers);
      headers.set("x-digest-origin", origin);
      return new Response(res.body, { status: res.status, headers });
    }
    return new Response(
      "digest unavailable (" + res.status + " from " + target + "); try /llms.txt or /digest-full.txt\n",
      { status: 502, headers: { "content-type": "text/plain" } }
    );
  },
};
