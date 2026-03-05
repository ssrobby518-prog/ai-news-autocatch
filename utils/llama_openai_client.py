"""utils/llama_openai_client.py — Stdlib-only client for llama-server.exe OpenAI API.

No pip dependencies.  Uses urllib only.

Environment variables:
    LLAMA_HOST             : base URL   (default http://127.0.0.1:8080)
    LLAMA_TIMEOUT_SECONDS  : HTTP timeout in seconds (default 120)

Public API
----------
    chat(messages, model="qwen2.5-7b-instruct", temperature=0, top_p=0.9,
         max_tokens=800, timeout=None) -> tuple[bool, str]
        POST /v1/chat/completions.
        Returns (True, text) on success, (False, error_message) on failure.
        Never raises — caller always gets a (bool, str) tuple.

    is_available(timeout=5) -> bool
        GET /v1/models; returns True if llama-server is reachable.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# Config from environment
# ---------------------------------------------------------------------------

_DEFAULT_HOST    = "http://127.0.0.1:8080"
_DEFAULT_TIMEOUT = 120

LLAMA_HOST    = os.environ.get("LLAMA_HOST",            _DEFAULT_HOST).strip().rstrip("/")
LLAMA_TIMEOUT = int(os.environ.get("LLAMA_TIMEOUT_SECONDS", str(_DEFAULT_TIMEOUT)))

# Ensure protocol prefix
if not LLAMA_HOST.startswith(("http://", "https://")):
    LLAMA_HOST = "http://" + LLAMA_HOST


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _post(path: str, payload: dict, timeout: int) -> dict:
    """POST with wall-clock timeout cap.

    iter31: wraps urllib in a thread so that slow-streaming Qwen responses
    (1 tok/sec) don't bypass the socket timeout — each streaming byte resets
    the per-read timer, but concurrent.futures.Future.result(timeout=X) is a
    true wall-clock cap regardless of streaming behaviour.
    Uses executor.shutdown(wait=False) (same pattern as fulltext_hydrator.py
    Iter26 fix) to avoid hanging when the stuck thread is still in resp.read().
    """
    import concurrent.futures as _lc_cf

    url  = f"{LLAMA_HOST}{path}"
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    def _do() -> dict:
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
        return json.loads(raw)

    executor = _lc_cf.ThreadPoolExecutor(max_workers=1)
    future   = executor.submit(_do)
    try:
        return future.result(timeout=timeout)
    except _lc_cf.TimeoutError:
        raise TimeoutError(f"llama_openai_client wall-clock timeout after {timeout}s")
    finally:
        executor.shutdown(wait=False)


def _get(path: str, timeout: int = 10) -> dict:
    url = f"{LLAMA_HOST}{path}"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def is_available(timeout: int = 5) -> bool:
    """Return True if llama-server is reachable at LLAMA_HOST."""
    try:
        _get("/v1/models", timeout=timeout)
        return True
    except Exception:
        return False


def chat(
    messages: list[dict],
    model: str = "qwen2.5-7b-instruct",
    temperature: float = 0.0,
    top_p: float = 0.9,
    max_tokens: int = 800,
    timeout: int | None = None,
    max_retries: int = 1,
) -> tuple[bool, str]:
    """POST /v1/chat/completions and return (ok, text_or_error).

    Parameters
    ----------
    messages    : OpenAI-style message list, e.g.
                  [{"role":"system","content":"..."}, {"role":"user","content":"..."}]
    model       : Model name string (llama-server ignores it but we send it).
    temperature : 0 = fully deterministic.
    top_p       : Nucleus sampling probability.
    max_tokens  : Max tokens to generate.
    timeout     : HTTP timeout in seconds; defaults to LLAMA_TIMEOUT env var.
    max_retries : Additional attempts on transient HTTP failure (default 1).

    Returns
    -------
    (True, generated_text)  on success
    (False, error_message)  on failure (never raises)
    """
    _timeout = timeout if timeout is not None else LLAMA_TIMEOUT

    payload = {
        "model":       model,
        "messages":    messages,
        "temperature": temperature,
        "top_p":       top_p,
        "max_tokens":  max_tokens,
        "stream":      False,
    }

    last_err = ""
    for attempt in range(max_retries + 1):
        try:
            resp = _post("/v1/chat/completions", payload, _timeout)
            # OpenAI response format
            choices = resp.get("choices") or []
            if not choices:
                return (False, f"empty choices in response: {resp!r}")
            text = (choices[0].get("message") or {}).get("content", "") or ""
            return (True, text.strip())
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            last_err = str(exc)
            if attempt < max_retries:
                time.sleep(2 ** attempt)
        except json.JSONDecodeError as exc:
            return (False, f"JSON parse error: {exc}")
        except Exception as exc:
            last_err = str(exc)
            break

    return (False, f"llama_openai_client.chat failed after {max_retries + 1} attempt(s): {last_err}")
