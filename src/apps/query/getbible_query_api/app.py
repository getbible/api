"""The query endpoint.

    GET /{version}/{translation}/{reference}   -> the librarian's select()

Every shorter form is a permanent redirect to that canonical path, with the
default translation and the default reference substituted for anything that
does not resolve. The endpoint takes no parameters: a query string is a 400.
"""

from __future__ import annotations

from urllib.parse import quote

from flask import Flask, Response, g, request

from getbible_api_common import detect
from getbible_api_common.bible import query_client
from getbible_api_common.health import register_health
from getbible_api_common.http import install_request_hooks, json_response, redirect_permanent
from getbible_api_common.logging import configure_logging
from getbible_api_common.problems import ProblemError, register_error_handlers

from .config import Settings


def create_app(settings: Settings | None = None) -> Flask:
    settings = settings or Settings.from_environment()
    logger = configure_logging("getbible.query", settings.service.log_level, settings.service.app_log)
    app = Flask(__name__)
    app.json.sort_keys = False
    app.url_map.strict_slashes = False
    install_request_hooks(app, settings.service, logger)
    register_error_handlers(app, logger)

    bible = query_client(
        settings.librarian,
        reference_cache_limit=settings.reference_cache_limit,
        chapter_cache_limit=settings.chapter_cache_limit,
        max_references=settings.max_references,
        max_total_verses=settings.max_total_verses,
    )
    app.extensions["getbible"] = bible
    app.extensions["settings"] = settings
    version = settings.librarian.version
    default_translation = settings.service.default_translation
    default_reference = settings.default_reference
    max_length = settings.service.max_input_length
    allowed = settings.service.translation_allowed

    def canonical(translation: str, reference: str) -> str:
        return "/" + "/".join(quote(part, safe=":;,") for part in (version, translation, reference))

    def translation_or_default(segment: str) -> str:
        return segment.casefold() if detect.is_translation(bible, segment, allowed) else default_translation

    def reference_or_default(segment: str, translation: str) -> str:
        return segment if detect.is_reference(bible, segment, translation, max_length) else default_reference

    @app.before_request
    def _no_parameters() -> None:
        if request.args:
            raise ProblemError(400, "parameters_not_accepted",
                               "This endpoint takes no parameters. Put the translation and the reference in the path.")

    register_health(app, bible, default_translation, logger, reference=default_reference)

    @app.get("/")
    def index() -> Response:
        g.operation = "redirect"
        return redirect_permanent(canonical(default_translation, default_reference))

    @app.get("/<segment>")
    def one_segment(segment: str) -> Response:
        g.operation = "redirect"
        if detect.is_known_version(segment, version):
            return redirect_permanent(canonical(default_translation, default_reference))
        if detect.looks_like_version(segment):
            raise ProblemError(404, "unknown_version", f"API version {segment} is not served here; use {version}.")
        if detect.is_translation(bible, segment, allowed):
            return redirect_permanent(canonical(segment.casefold(), default_reference))
        return redirect_permanent(canonical(default_translation, reference_or_default(segment, default_translation)))

    @app.get("/<first>/<second>")
    def two_segments(first: str, second: str) -> Response:
        g.operation = "redirect"
        if detect.is_known_version(first, version):
            if detect.is_translation(bible, second, allowed):
                return redirect_permanent(canonical(second.casefold(), default_reference))
            return redirect_permanent(canonical(default_translation, reference_or_default(second, default_translation)))
        if detect.looks_like_version(first):
            raise ProblemError(404, "unknown_version", f"API version {first} is not served here; use {version}.")
        translation = translation_or_default(first)
        return redirect_permanent(canonical(translation, reference_or_default(second, translation)))

    @app.get("/<requested_version>/<translation>/<reference>")
    def scripture(requested_version: str, translation: str, reference: str) -> Response:
        g.operation = "scripture"
        g.version = requested_version
        if requested_version != version:
            raise ProblemError(404, "unknown_version", f"API version {requested_version} is not served here; use {version}.")
        code = translation.casefold()
        g.translation = code
        if not allowed(code):
            raise ProblemError(404, "translation_not_found", f"Translation ({translation}) not found.")
        if len(reference) > max_length:
            raise ProblemError(400, "invalid_reference", f"Reference cannot exceed {max_length} characters.")
        g.reference = reference
        result = bible.select(reference, code)
        g.references = len([part for part in reference.split(";") if part.strip()])
        g.verses = sum(len(chapter["verses"]) for chapter in result.values())
        return json_response(app, result, cache_seconds=settings.service.cache_seconds)

    return app
