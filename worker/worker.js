// Agent proxy for the utility source digest.
// Serves the Pages production origin so utility.rizkifaizalr.workers.dev
// always mirrors the latest deploy. Root returns llms.txt so agents that
// fetch the bare URL get the machine index immediately.
const ORIGIN = "https://utility-digest.pages.dev";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname === "/" ? "/llms.txt" : url.pathname;
    const res = await fetch(ORIGIN + path + url.search,
                            { redirect: "follow" });
    if (res.ok) {
      return res;
    }
    return new Response(
      "digest unavailable (" + res.status + "); try /llms.txt or" +
      " /digest-full.txt\n",
      { status: 502, headers: { "content-type": "text/plain" } });
  },
};
