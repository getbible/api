"""The query endpoint.

    GET /{version}/{translation}/{reference}   -> the librarian's select()

Shorter forms redirect only when the requested reference resolves. Missing or
unresolved references return 404; no default scripture is substituted. The
endpoint takes no parameters: a query string is a 400.
"""

from __future__ import annotations

from urllib.parse import quote

from flask import Flask, Response, g, request
from getbible import ReferenceValidationError

from getbible_api_common.control import install_control
from getbible_api_common import detect
from getbible_api_common.bible import query_client
from getbible_api_common.health import register_health
from getbible_api_common.http import install_request_hooks, json_response, redirect_permanent
from getbible_api_common.logging import configure_logging
from getbible_api_common.problems import ProblemError, problem, register_error_handlers

from .config import Settings


def create_app(settings: Settings | None = None) -> Flask:
    settings = settings or Settings.from_environment()
    logger = configure_logging("getbible.query", settings.service.log_level, settings.service.app_log)
    app = Flask(__name__)
    app.json.sort_keys = False
    app.url_map.strict_slashes = False
    install_request_hooks(app, settings.service, logger)
    register_error_handlers(app, logger)

    @app.errorhandler(ReferenceValidationError)
    def reference_not_found(error: ReferenceValidationError) -> Response:
        # This HTTP policy belongs to query; search retains its own errors.
        return problem(app, 404, "invalid_reference", str(error))

    bible = query_client(
        settings.librarian,
        reference_cache_limit=settings.reference_cache_limit,
        chapter_cache_limit=settings.chapter_cache_limit,
        max_references=settings.max_references,
        max_total_verses=settings.max_total_verses,
    )
    app.extensions["getbible"] = bible
    app.extensions["settings"] = settings
    install_control(app, bible, settings.librarian, "query")
    version = settings.librarian.version
    default_translation = settings.service.default_translation
    max_length = settings.service.max_input_length
    allowed = settings.service.translation_allowed

    def canonical(translation: str, reference: str) -> str:
        return "/" + "/".join(quote(part, safe=":;,") for part in (version, translation, reference))

    def missing_reference() -> Response:
        raise ProblemError(404, "missing_reference",
                           f"No scripture reference was supplied. Request /{version}/{{translation}}/{{reference}}.")

    def select_reference(translation: str, reference: str) -> dict:
        code = translation.casefold()
        g.translation = code
        g.reference = reference
        if not allowed(code):
            raise ProblemError(404, "translation_not_found", f"Translation ({translation}) not found.")
        if len(reference) > max_length:
            raise ProblemError(404, "invalid_reference", f"Reference cannot exceed {max_length} characters.")
        result = bible.select(reference, code)
        if not any(chapter.get("verses") for chapter in result.values()):
            raise ProblemError(404, "invalid_reference",
                               "The requested reference did not resolve to any scripture. Check the reference and try again.")
        return result

    def redirect_reference(translation: str, reference: str) -> Response:
        # Resolve first: a syntactically plausible but unavailable reference
        # must not send callers to another request or substitute scripture.
        select_reference(translation, reference)
        g.operation = "redirect"
        return redirect_permanent(canonical(translation.casefold(), reference))

    @app.before_request
    def _no_parameters() -> None:
        if request.args:
            raise ProblemError(400, "parameters_not_accepted",
                               "This endpoint takes no parameters. Put the translation and the reference in the path.")

    register_health(app, bible, default_translation, logger, reference=settings.default_reference)

    @app.get("/")
    def index() -> Response:
        return missing_reference()

    @app.get("/<segment>")
    def one_segment(segment: str) -> Response:
        g.operation = "scripture"
        g.version = version
        if detect.is_known_version(segment, version):
            return missing_reference()
        if detect.looks_like_version(segment):
            raise ProblemError(404, "unknown_version", f"API version {segment} is not served here; use {version}.")
        if detect.is_translation(bible, segment, allowed):
            g.translation = segment.casefold()
            return missing_reference()
        return redirect_reference(default_translation, segment)

    @app.get("/<first>/<second>")
    def two_segments(first: str, second: str) -> Response:
        g.operation = "scripture"
        g.version = version
        if detect.is_known_version(first, version):
            if detect.is_translation(bible, second, allowed):
                g.translation = second.casefold()
                return missing_reference()
            return redirect_reference(default_translation, second)
        if detect.looks_like_version(first):
            raise ProblemError(404, "unknown_version", f"API version {first} is not served here; use {version}.")
        return redirect_reference(first, second)

    @app.get("/<requested_version>/<translation>/<reference>")
    def scripture(requested_version: str, translation: str, reference: str) -> Response:
        g.operation = "scripture"
        g.version = requested_version
        if requested_version != version:
            raise ProblemError(404, "unknown_version", f"API version {requested_version} is not served here; use {version}.")
        result = select_reference(translation, reference)
        g.books = sorted({chapter["book_nr"] for chapter in result.values() if "book_nr" in chapter})
        g.references = len([part for part in reference.split(";") if part.strip()])
        g.verses = sum(len(chapter["verses"]) for chapter in result.values())
        return json_response(app, result, cache_seconds=app.extensions["getbible_control"].cache_seconds(settings.service.cache_seconds))

    return app
