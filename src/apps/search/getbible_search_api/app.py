"""The search endpoint.

    GET|POST /{version}/{translation}/{search string}
    GET|POST /{version}/{translation}        search string in parameters or body
    GET|POST /{version}                      translation and search string in
                                             parameters or body
    GET|POST /{version}/{search string}      redirects to the default translation

Filters travel as query-string parameters on GET or POST, or as a JSON body
on POST. GET bodies are not read. Precedence is
fixed: the path wins, then the query string, then the body, then the
endpoint's configured defaults. A search string that parses as a scripture
reference returns that scripture instead of searching.
"""

from __future__ import annotations

import dataclasses
import threading
from typing import Any
from urllib.parse import quote

from flask import Flask, Response, g, request
from getbible import SEARCH_ENGINE_VERSION, SearchBible, SearchValidationError

from getbible_api_common.control import install_control
from getbible_api_common import detect
from getbible_api_common.bible import search_client
from getbible_api_common.health import register_health
from getbible_api_common.http import install_request_hooks, json_response, redirect_permanent
from getbible_api_common.logging import configure_logging
from getbible_api_common.problems import ProblemError, register_error_handlers

from .config import Settings

FILTER_KEYS = frozenset({"words", "match", "case_sensitive", "scope", "book", "books", "diacritics",
                         "exclude", "proximity", "sort", "limit", "offset"})
REPEATABLE = frozenset({"book", "exclude"})
ALLOWED_KEYS = FILTER_KEYS | {"q", "translation"}
_MAX_BOOKS = 83
_MAX_EXCLUDED = 32
_MAX_EXCLUDED_LENGTH = 100


class _Gate:
    """Bounded concurrency per worker: answer fast instead of queueing."""

    def __init__(self, normal: int, expensive: int) -> None:
        self._normal = threading.BoundedSemaphore(normal)
        self._expensive = threading.BoundedSemaphore(expensive)

    def acquire(self, expensive: bool) -> tuple[threading.BoundedSemaphore, ...]:
        held: list[threading.BoundedSemaphore] = []
        for semaphore in ((self._normal, self._expensive) if expensive else (self._normal,)):
            if not semaphore.acquire(blocking=False):
                for previous in held:
                    previous.release()
                raise ProblemError(503, "busy", "The search service is at capacity; retry in a moment.",
                                   headers={"Retry-After": "2"}, retry_after=2)
            held.append(semaphore)
        return tuple(held)


def create_app(settings: Settings | None = None) -> Flask:
    settings = settings or Settings.from_environment()
    logger = configure_logging("getbible.search", settings.service.log_level, settings.service.app_log)
    app = Flask(__name__)
    app.json.sort_keys = False
    app.url_map.strict_slashes = False
    install_request_hooks(app, settings.service, logger)
    register_error_handlers(app, logger)

    bible = search_client(
        settings.librarian,
        search_corpus_limit=settings.search_corpus_limit,
        translation_cache_limit=settings.translation_cache_limit,
        deadline_seconds=settings.deadline_seconds,
        max_limit=settings.max_page_size,
        max_offset=settings.max_offset,
    )
    app.extensions["getbible"] = bible
    app.extensions["settings"] = settings
    install_control(app, bible, settings.librarian, "search")
    gate = _Gate(settings.max_concurrent, settings.max_concurrent_expensive)
    version = settings.librarian.version
    default_translation = settings.service.default_translation
    allowed = settings.service.translation_allowed
    max_length = settings.max_query_length

    register_health(app, bible, default_translation, logger, search_probe=True)

    # --- parameter handling ---------------------------------------------------
    def body_values() -> dict[str, Any]:
        if request.method != "POST":
            return {}
        if not request.content_length and not request.data and not request.form:
            return {}
        if not request.is_json:
            raise ProblemError(415, "unsupported_media_type", "POST bodies must be JSON (Content-Type: application/json).")
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            raise ProblemError(400, "invalid_body", "The JSON body must be an object of search parameters.")
        unknown = set(data) - ALLOWED_KEYS
        if unknown:
            raise ProblemError(400, "unknown_parameter", f"Unknown parameters in the body: {', '.join(sorted(unknown))}.")
        return data

    def query_values() -> dict[str, Any]:
        unknown = set(request.args) - ALLOWED_KEYS
        if unknown:
            raise ProblemError(400, "unknown_parameter", f"Unknown parameters: {', '.join(sorted(unknown))}.")
        duplicated = sorted(k for k in request.args if k not in REPEATABLE and len(request.args.getlist(k)) > 1)
        if duplicated:
            raise ProblemError(400, "repeated_parameter", f"Parameters cannot be repeated: {', '.join(duplicated)}.")
        values: dict[str, Any] = {}
        for key in request.args:
            values[key] = request.args.getlist(key) if key in REPEATABLE else request.args[key]
        return values

    def merged_values(path: dict[str, Any]) -> dict[str, Any]:
        """Path beats query string beats body beats configured defaults."""
        values: dict[str, Any] = dict(settings.default_criteria)
        for layer in (body_values(), query_values(), path):
            for key, value in layer.items():
                if value is None:
                    continue
                values[key] = value
        return values

    def parse_criteria(values: dict[str, Any]) -> SearchBible:
        criteria: dict[str, Any] = {}
        for key in ("words", "match", "scope", "diacritics", "sort"):
            if key in values:
                criteria[key] = str(values[key])
        if "case_sensitive" in values:
            criteria["case_sensitive"] = _boolean("case_sensitive", values["case_sensitive"])
        for key in ("proximity", "limit", "offset"):
            if key in values:
                criteria[key] = _integer(key, values[key])
        books = _listed(values.get("book")) + _split_csv(values.get("books"))
        if books:
            if any(not str(item).strip() for item in books):
                raise SearchValidationError("Book filters cannot be empty.")
            if len(books) > _MAX_BOOKS:
                raise SearchValidationError(f"Search cannot contain more than {_MAX_BOOKS} book filters.")
            criteria["books"] = tuple(str(item).strip() for item in books)
        excluded = _listed(values.get("exclude"))
        if excluded:
            if any(not str(item).strip() for item in excluded):
                raise SearchValidationError("Excluded terms cannot be empty.")
            if len(excluded) > _MAX_EXCLUDED:
                raise SearchValidationError(f"Search cannot contain more than {_MAX_EXCLUDED} excluded terms.")
            if any(len(str(item)) > _MAX_EXCLUDED_LENGTH for item in excluded):
                raise SearchValidationError(f"An excluded term cannot exceed {_MAX_EXCLUDED_LENGTH} characters.")
            criteria["exclude"] = tuple(str(item).strip() for item in excluded)
        parsed = SearchBible.from_value(criteria)
        if parsed.limit > settings.max_page_size:
            raise SearchValidationError(f"Public page size cannot exceed {settings.max_page_size}.")
        if parsed.offset > settings.max_offset:
            raise SearchValidationError(f"Public search offset cannot exceed {settings.max_offset}.")
        return parsed

    def require_translation(code: str) -> str:
        code = code.casefold()
        g.translation = code
        if not allowed(code) or not detect.is_translation(bible, code, allowed):
            raise ProblemError(404, "translation_not_found", f"Translation ({code}) not found.")
        return code

    def require_search_string(values: dict[str, Any]) -> str:
        text = values.get("q")
        if isinstance(text, list):
            text = text[0] if text else ""
        text = str(text or "").strip()
        if not text:
            raise ProblemError(400, "missing_search", "No search string was given. Put it in the path, in the q parameter, or in the JSON body.")
        if len(text) > max_length:
            raise ProblemError(400, "invalid_search", f"Search string cannot exceed {max_length} characters.")
        return text

    def perform(translation: str, text: str, values: dict[str, Any]) -> Response:
        g.search = text
        cache_seconds = app.extensions["getbible_control"].cache_seconds(settings.service.cache_seconds)
        if detect.is_reference(bible, text, translation, min(max_length, 200)):
            g.kind = "reference"
            g.operation = "reference"
            results = bible.select(text, translation)
            g.books = sorted({chapter["book_nr"] for chapter in results.values() if "book_nr" in chapter})
            matches = [
                {"reference": verse["name"], "book_nr": chapter["book_nr"], "chapter": chapter["chapter"], "verse": verse["verse"]}
                for chapter in results.values() for verse in chapter["verses"]
            ]
            g.returned = len(matches)
            g.total = len(matches)
            first = next(iter(results.values()), {})
            metadata = {key: first[key] for key in ("translation", "abbreviation", "lang", "language", "direction", "encoding") if key in first}
            payload = {
                "query": {
                    "text": text,
                    "kind": "reference",
                    "translation": metadata or translation,
                    "engine_version": SEARCH_ENGINE_VERSION,
                    "total": len(matches),
                    "returned": len(matches),
                },
                "results": results,
                "matches": matches,
            }
            return json_response(app, payload, cache_seconds=cache_seconds)
        g.kind = "search"
        g.operation = "search"
        criteria = parse_criteria(values)
        g.criteria = dataclasses.asdict(criteria)
        g.expensive = criteria.expensive
        held = gate.acquire(criteria.expensive)
        try:
            result = bible.search(text, translation, criteria)
        finally:
            for semaphore in held:
                semaphore.release()
        result["query"]["kind"] = "search"
        g.matched_books = sorted({item["book_nr"] for item in result.get("matches", []) if "book_nr" in item})
        # Record the book identities actually served; requested aliases and
        # filters remain available verbatim in criteria.books.
        g.books = g.matched_books
        g.total = result["query"].get("total")
        g.returned = result["query"].get("returned")
        g.cache_stale = result["query"].get("cache", {}).get("stale")
        return json_response(app, result, cache_seconds=cache_seconds)

    def not_here(requested: str) -> ProblemError:
        return ProblemError(404, "unknown_version", f"API version {requested} is not served here; use {version}.")

    def with_query_string(*segments: str) -> str:
        location = "/" + "/".join(quote(segment, safe=":;,") for segment in segments)
        qs = request.query_string.decode("utf-8", "replace")
        return f"{location}?{qs}" if qs else location

    # --- routes ----------------------------------------------------------------
    @app.route("/", methods=["GET", "POST"])
    def index() -> Response:
        raise ProblemError(404, "not_found", f"Search at /{version}/{{translation}}/{{search string}}. The documentation at the domain root explains the parameters.")

    @app.route("/<segment>", methods=["GET", "POST"])
    def one_segment(segment: str) -> Response:
        if detect.is_known_version(segment, version):
            g.version = segment
            values = merged_values({})
            translation = require_translation(str(values.get("translation") or default_translation))
            return perform(translation, require_search_string(values), values)
        if detect.looks_like_version(segment):
            raise not_here(segment)
        g.operation = "redirect"
        if detect.is_translation(bible, segment, allowed):
            return redirect_permanent(with_query_string(version, segment.casefold()))
        return redirect_permanent(with_query_string(version, default_translation, segment))

    @app.route("/<first>/<second>", methods=["GET", "POST"])
    def two_segments(first: str, second: str) -> Response:
        if detect.is_known_version(first, version):
            g.version = first
            if detect.is_translation(bible, second, allowed):
                values = merged_values({"translation": second.casefold()})
                translation = require_translation(second)
                return perform(translation, require_search_string(values), values)
            g.operation = "redirect"
            return redirect_permanent(with_query_string(version, default_translation, second))
        if detect.looks_like_version(first):
            raise not_here(first)
        g.operation = "redirect"
        return redirect_permanent(with_query_string(version, first, second))

    @app.route("/<requested_version>/<translation>/<text>", methods=["GET", "POST"])
    def search(requested_version: str, translation: str, text: str) -> Response:
        g.version = requested_version
        if requested_version != version:
            raise not_here(requested_version)
        code = require_translation(translation)
        values = merged_values({"translation": code, "q": text})
        return perform(code, require_search_string(values), values)

    return app


def _boolean(name: str, value: Any) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).casefold()
    if normalized in {"1", "true", "yes"}:
        return True
    if normalized in {"0", "false", "no"}:
        return False
    raise SearchValidationError(f"{name} must be true or false.")


def _integer(name: str, value: Any) -> int:
    if isinstance(value, bool):
        raise SearchValidationError(f"{name} must be an integer.")
    if isinstance(value, int):
        return value
    try:
        return int(str(value))
    except ValueError as error:
        raise SearchValidationError(f"{name} must be an integer.") from error


def _listed(value: Any) -> list:
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
    return [value]


def _split_csv(value: Any) -> list:
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [item for entry in value for item in str(entry).split(",")]
    return [item for item in str(value).split(",")]
