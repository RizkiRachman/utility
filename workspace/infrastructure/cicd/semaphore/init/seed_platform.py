#!/usr/bin/env python3
# seed_platform.py - Layer 0: idempotent cold-start seeding for Semaphore UI.
# Runs at container startup (compose sidecar) and provisions with zero clicks:
#   project -> gitea-git access key -> inventory (secrets) -> repository ->
#   platform templates (provisioner + platform-deployer) with Run dialogs.
# Proven on semaphore v2.20.24 (sqlite, docker_executor=false). Stdlib only.
#
# Env:
#   SEED_API_BASE (default http://semaphore:3000)
#   SEED_ADMIN / SEED_ADMIN_PASSWORD (fallback: SEMAPHORE_ADMIN / SEMAPHORE_ADMIN_PASSWORD)
#   SEED_PROJECT_NAME (default Deployers)
#   DEPLOYER_GIT_URL / DEPLOYER_REPO_NAME / DEPLOYER_GIT_BRANCH (default main)
#   GITEA_BOOTSTRAP_USERNAME / GITEA_BOOTSTRAP_PASSWORD / VAULT_TOKEN
import json
import os
import sys
import time
import urllib.request
import urllib.error
import http.cookiejar

API = os.environ.get("SEED_API_BASE") or "http://semaphore:3000"
ADMIN = os.environ.get("SEED_ADMIN") or os.environ.get("SEMAPHORE_ADMIN") or "admin"
PASSWORD = os.environ.get("SEED_ADMIN_PASSWORD") or os.environ.get("SEMAPHORE_ADMIN_PASSWORD") or ""
PROJECT_NAME = os.environ.get("SEED_PROJECT_NAME") or "Deployers"
GIT_URL = os.environ.get("DEPLOYER_GIT_URL") or "http://host.docker.internal:3300/development-tools/springboot-application-web-deployer"
REPO_NAME = os.environ.get("DEPLOYER_REPO_NAME") or "springboot-application-web-deployer"
GIT_BRANCH = os.environ.get("DEPLOYER_GIT_BRANCH") or "main"
GITEA_USER = os.environ.get("GITEA_BOOTSTRAP_USERNAME") or ""
GITEA_PASS = os.environ.get("GITEA_BOOTSTRAP_PASSWORD") or ""
VAULT_TOKEN = os.environ.get("VAULT_TOKEN") or ""
KEY_NAME = "gitea-git"
Q = chr(39)

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
errors = []

def req(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(API + path, data=data, method=method)
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        resp = opener.open(r, timeout=20)
        body = resp.read().decode()
        return resp.getcode(), (json.loads(body) if body.strip()[:1] in ("{", "[") else body)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            return e.code, (json.loads(body) if body.strip()[:1] in ("{", "[") else body)
        except ValueError:
            return e.code, {"raw": body[:200]}

    except (urllib.error.URLError, OSError) as e:
        return None, {"error": str(e)}

def say(tag, msg):
    print("[" + tag + "] " + msg)

def wait_for_api(timeout=int(os.environ.get("SEED_WAIT_TIMEOUT") or "180")):
    deadline = time.time() + timeout
    while time.time() < deadline:
        code, _ = req("GET", "/api/ping")
        if code == 200:
            return True
        time.sleep(3)
    return False

def fail(msg):
    print("FATAL: " + msg)
    sys.exit(1)

def ensure_project():
    code, projects = req("GET", "/api/projects")
    if code != 200 or not isinstance(projects, list):
        fail("cannot list projects: HTTP " + str(code))
    for p in projects:
        if p.get("name") == PROJECT_NAME:
            say("skip", "project " + PROJECT_NAME + " (id " + str(p["id"]) + ")")
            return p["id"]
    body = {"name": PROJECT_NAME, "alert": False, "max_parallel_tasks": 0}
    code, resp = req("POST", "/api/projects", body)
    if code not in (200, 201, 204):
        fail("create project failed: HTTP " + str(code) + " " + json.dumps(resp))
    if isinstance(resp, dict) and resp.get("id"):
        say("create", "project " + PROJECT_NAME + " (id " + str(resp["id"]) + ")")
        return resp["id"]
    code, projects = req("GET", "/api/projects")
    for p in projects:
        if p.get("name") == PROJECT_NAME:
            say("create", "project " + PROJECT_NAME + " (id " + str(p["id"]) + ")")
            return p["id"]
    fail("project created but id not found")

def ensure_key(pid):
    code, keys = req("GET", "/api/project/" + str(pid) + "/keys")
    if code == 200 and isinstance(keys, list):
        for k in keys:
            if k.get("name") == KEY_NAME:
                say("skip", "key " + KEY_NAME + " (id " + str(k["id"]) + ")")
                return k["id"]
    if not (GITEA_USER and GITEA_PASS):
        errors.append("cannot create key " + KEY_NAME + ": GITEA_BOOTSTRAP_USERNAME/PASSWORD not set")
        return None
    payloads = [
        {"project_id": pid, "name": KEY_NAME, "type": "login_password",
         "login_password": {"login": GITEA_USER, "password": GITEA_PASS}},
        {"project_id": pid, "name": KEY_NAME, "type": "login_password",
         "key": GITEA_USER, "key_store": GITEA_PASS},
    ]
    last = ""
    for body in payloads:
        code, resp = req("POST", "/api/project/" + str(pid) + "/keys", body)
        if code in (200, 201, 204):
            kid = resp.get("id") if isinstance(resp, dict) else None
            if not kid:
                code2, keys = req("GET", "/api/project/" + str(pid) + "/keys")
                for k in keys or []:
                    if k.get("name") == KEY_NAME:
                        kid = k["id"]
            say("create", "key " + KEY_NAME + " (id " + str(kid) + ")")
            return kid
        last = "HTTP " + str(code) + " " + json.dumps(resp)[:150]
    errors.append("key creation failed: " + last)
    return None

def ensure_inventory(pid):
    code, invs = req("GET", "/api/project/" + str(pid) + "/inventory")
    if code == 200 and isinstance(invs, list):
        for i in invs:
            if i.get("name") == "deployer-platform":
                say("skip", "inventory deployer-platform (id " + str(i["id"]) + ")")
                return i["id"]
    yml = "---\nall:\n  hosts:\n    localhost:\n      ansible_connection: local\n  vars:\n"
    yml += "    VAULT_TOKEN: " + Q + VAULT_TOKEN + Q + "\n"
    yml += "    GITEA_BOOTSTRAP_USERNAME: " + Q + GITEA_USER + Q + "\n"
    yml += "    GITEA_BOOTSTRAP_PASSWORD: " + Q + GITEA_PASS + Q + "\n"
    body = {"project_id": pid, "name": "deployer-platform", "type": "static", "inventory": yml}
    code, resp = req("POST", "/api/project/" + str(pid) + "/inventory", body)
    if code not in (200, 201, 204):
        fail("create inventory failed: HTTP " + str(code) + " " + json.dumps(resp))
    say("create", "inventory deployer-platform (id " + str(resp["id"]) + ")")
    return resp["id"]

def ensure_repository(pid, kid):
    code, repos = req("GET", "/api/project/" + str(pid) + "/repositories")
    if code == 200 and isinstance(repos, list):
        for r in repos:
            if r.get("name") == REPO_NAME:
                say("skip", "repository " + REPO_NAME + " (id " + str(r["id"]) + ")")
                return r["id"]
    body = {"project_id": pid, "name": REPO_NAME, "git_url": GIT_URL,
            "git_branch": GIT_BRANCH, "monorepo": True}
    if kid:
        body["ssh_key_id"] = kid
    code, resp = req("POST", "/api/project/" + str(pid) + "/repositories", body)
    if code not in (200, 201, 204):
        fail("create repository failed: HTTP " + str(code) + " " + json.dumps(resp))
    say("create", "repository " + REPO_NAME + " (id " + str(resp["id"]) + ")")
    return resp["id"]

def ensure_template(pid, inv_id, repo_id, name, playbook, survey=None):
    code, tpls = req("GET", "/api/project/" + str(pid) + "/templates")
    if code == 200 and isinstance(tpls, list):
        for t in tpls:
            if t.get("name") == name:
                say("skip", "template " + name + " (id " + str(t["id"]) + ")")
                return t["id"]
    body = {"project_id": pid, "inventory_id": inv_id, "repository_id": repo_id,
            "playbook": playbook, "name": name, "type": "", "app": "ansible"}
    if survey:
        body["survey_vars"] = survey
    code, resp = req("POST", "/api/project/" + str(pid) + "/templates", body)
    if code not in (200, 201, 204):
        fail("create template " + name + " failed: HTTP " + str(code) + " " + json.dumps(resp))
    say("create", "template " + name + " (id " + str(resp["id"]) + ")")
    return resp["id"]

def main():
    if not wait_for_api():
        fail("semaphore API not reachable at " + API)
    say("api", "reachable at " + API)
    code, _ = req("POST", "/api/auth/login", {"auth": ADMIN, "password": PASSWORD})
    if code not in (200, 204):
        fail("login failed for " + ADMIN + ": HTTP " + str(code))
    say("auth", "logged in as " + ADMIN)
    pid = ensure_project()
    kid = ensure_key(pid)
    inv_id = ensure_inventory(pid)
    repo_id = ensure_repository(pid, kid)
    ensure_template(pid, inv_id, repo_id, "pipeline-provisioner",
                    "pipelines/semaphore/provision.yml")
    action_enum = {"description": "", "name": "PIPELINE_ACTION", "required": True,
                   "target": "", "title": "Action", "type": "enum",
                   "values": [{"name": v, "value": v} for v in ("plan", "apply", "destroy")]}
    survey = [
        {"description": "Git URL of the service repository", "name": "REPO_URL",
         "required": True, "target": "", "title": "Repository URL", "type": "string"},
        {"description": "Short name of the service", "name": "REPO_NAME",
         "required": True, "target": "", "title": "Repository Name", "type": "string"},
        action_enum,
    ]
    ensure_template(pid, inv_id, repo_id, "platform-deployer",
                    "pipelines/semaphore/platform_deployer.yml", survey)
    if errors:
        for e in errors:
            say("warn", e)
        sys.exit(2)
    say("done", "platform ready: project " + PROJECT_NAME + " has provisioner + platform-deployer")

if __name__ == "__main__":
    main()
