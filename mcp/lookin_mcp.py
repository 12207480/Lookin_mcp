#!/usr/bin/env python3
"""
Read-only MCP server for inspecting exported Lookin `.lookin` files.

The `.lookin` document format is an NSKeyedArchive. This server intentionally
does not depend on Lookin app runtime classes; it decodes the archive shape
generically and exposes normalized hierarchy queries for LLM clients.
"""

from __future__ import annotations

import hashlib
import json
import plistlib
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple


SERVER_NAME = "lookin_mcp"
SERVER_VERSION = "0.1.0"
DEFAULT_BRIDGE_URL = "http://127.0.0.1:47638"
DEFAULT_LIMIT = 50
MAX_LIMIT = 200
MAX_DETAIL_BYTES = 256
LIVE_TIMEOUT_SECONDS = 20


class ResponseFormat(str, Enum):
    MARKDOWN = "markdown"
    JSON = "json"


class ToolError(Exception):
    pass


@dataclass(frozen=True)
class ObjectRef:
    index: int


@dataclass
class NormalizedItem:
    item_id: str
    object_index: int
    title: Optional[str]
    subtitle: Optional[str]
    depth: int
    child_count: int
    view_object: Optional[Dict[str, Any]]
    layer_object: Optional[Dict[str, Any]]
    controller_object: Optional[Dict[str, Any]]
    frame: Any
    bounds: Any
    hidden: Optional[bool]
    displaying: Optional[bool]
    raw_class: Optional[str]
    raw: Optional[Dict[str, Any]] = None

    def compact(self) -> Dict[str, Any]:
        data = {
            "id": self.item_id,
            "title": self.title,
            "subtitle": self.subtitle,
            "depth": self.depth,
            "child_count": self.child_count,
            "view": self.view_object,
            "layer": self.layer_object,
            "controller": self.controller_object,
            "frame": self.frame,
            "bounds": self.bounds,
            "hidden": self.hidden,
            "displaying": self.displaying,
            "object_index": self.object_index,
            "raw_class": self.raw_class,
        }
        return {key: value for key, value in data.items() if value is not None}

    def detailed(self) -> Dict[str, Any]:
        data = self.compact()
        if self.raw is not None:
            data["raw"] = self.raw
        return data


class LookinArchive:
    def __init__(self, path: str, data: Optional[bytes] = None) -> None:
        self.path = str(Path(path).expanduser()) if data is None else path
        try:
            if data is None:
                file_path = Path(self.path)
                if not file_path.exists():
                    raise ToolError(f"File not found: {self.path}")
                if not file_path.is_file():
                    raise ToolError(f"Path is not a file: {self.path}")
                if file_path.suffix.lower() != ".lookin":
                    raise ToolError("Expected a .lookin file exported by Lookin.")
                with file_path.open("rb") as file:
                    self.archive = plistlib.load(file)
            else:
                self.archive = plistlib.loads(data)
        except Exception as exc:
            if isinstance(exc, ToolError):
                raise
            raise ToolError(
                "Failed to parse file as a property-list NSKeyedArchive. "
                "Please export a fresh .lookin file from Lookin and try again."
            ) from exc

        if not isinstance(self.archive, dict) or "$objects" not in self.archive:
            raise ToolError("Unsupported .lookin archive: missing $objects table.")

        self.objects: List[Any] = self.archive["$objects"]

    def class_name_for_index(self, index: int) -> Optional[str]:
        if index < 0 or index >= len(self.objects):
            return None
        obj = self.objects[index]
        if not isinstance(obj, dict):
            return None
        class_ref = obj.get("$class")
        class_obj = self.resolve(class_ref, depth=1)
        if isinstance(class_obj, dict):
            return class_obj.get("$classname") or class_obj.get("classname")
        return None

    def resolve_ref_index(self, value: Any) -> Optional[int]:
        if isinstance(value, plistlib.UID):
            return int(value.data)
        if isinstance(value, ObjectRef):
            return value.index
        return None

    def resolve(self, value: Any, depth: int = 6, seen: Optional[Set[int]] = None) -> Any:
        if seen is None:
            seen = set()

        ref_index = self.resolve_ref_index(value)
        if ref_index is not None:
            if ref_index < 0 or ref_index >= len(self.objects):
                return {"__invalid_ref": ref_index}
            if ref_index == 0:
                return None
            if depth <= 0:
                return {"__ref": ref_index, "__class": self.class_name_for_index(ref_index)}
            if ref_index in seen:
                return {"__ref": ref_index, "__class": self.class_name_for_index(ref_index)}
            return self._decode_object(ref_index, depth, seen | {ref_index})

        if isinstance(value, bytes):
            return {
                "__bytes": len(value),
                "sha256": hashlib.sha256(value[:MAX_DETAIL_BYTES]).hexdigest(),
            }
        if isinstance(value, dict):
            return {str(key): self.resolve(val, depth - 1, seen) for key, val in value.items()}
        if isinstance(value, list):
            return [self.resolve(item, depth - 1, seen) for item in value]
        return value

    def _decode_object(self, index: int, depth: int, seen: Set[int]) -> Any:
        obj = self.objects[index]
        if not isinstance(obj, dict):
            return obj

        class_name = self.class_name_for_index(index)
        object_values = obj.get("NS.objects")
        if isinstance(object_values, list) and self._is_collection_class(class_name):
            return [self.resolve(item, depth - 1, seen) for item in object_values]

        ns_keys = obj.get("NS.keys")
        ns_objects = obj.get("NS.objects")
        if isinstance(ns_keys, list) and isinstance(ns_objects, list) and self._is_dictionary_class(class_name):
            result: Dict[str, Any] = {}
            for key_ref, val_ref in zip(ns_keys, ns_objects):
                key = self.resolve(key_ref, depth - 1, seen)
                result[str(key)] = self.resolve(val_ref, depth - 1, seen)
            return result

        result = {"__class": class_name, "__object_index": index}
        for key, val in obj.items():
            if key == "$class":
                continue
            result[str(key)] = self.resolve(val, depth - 1, seen)
        return result

    @staticmethod
    def _is_collection_class(class_name: Optional[str]) -> bool:
        return class_name in {"NSArray", "NSMutableArray", "NSSet", "NSMutableSet"}

    @staticmethod
    def _is_dictionary_class(class_name: Optional[str]) -> bool:
        return class_name in {"NSDictionary", "NSMutableDictionary"}

    def iter_objects(self) -> Iterable[Tuple[int, Any, Optional[str]]]:
        for index, obj in enumerate(self.objects):
            yield index, obj, self.class_name_for_index(index)

    def root(self) -> Any:
        top = self.archive.get("$top", {})
        return self.resolve(top.get("root"), depth=8)

    def root_ref(self) -> Optional[int]:
        top = self.archive.get("$top", {})
        return self.resolve_ref_index(top.get("root"))

    def class_counts(self) -> Dict[str, int]:
        counts: Dict[str, int] = {}
        for _, _, class_name in self.iter_objects():
            if class_name:
                counts[class_name] = counts.get(class_name, 0) + 1
        return dict(sorted(counts.items(), key=lambda item: (-item[1], item[0])))

    def decoded_object_by_class(self, name_fragment: str, depth: int = 5) -> Optional[Dict[str, Any]]:
        for index, _, class_name in self.iter_objects():
            if class_name and name_fragment in class_name:
                decoded = self.resolve(ObjectRef(index), depth=depth)
                if isinstance(decoded, dict):
                    return decoded
        return None

    def hierarchy_roots(self) -> List[ObjectRef]:
        hierarchy_info_index = self._first_index_for_class("LookinHierarchyInfo")
        if hierarchy_info_index is None:
            return self._all_display_item_refs()

        hierarchy_info = self.objects[hierarchy_info_index]
        if not isinstance(hierarchy_info, dict):
            return self._all_display_item_refs()

        root_value = self._first_field(hierarchy_info, ("displayItems", "_displayItems", "items", "_items"))
        roots = self._refs_from_collection(root_value)
        if roots:
            return roots
        return self._all_display_item_refs()

    def _first_index_for_class(self, name_fragment: str) -> Optional[int]:
        for index, _, class_name in self.iter_objects():
            if class_name and name_fragment in class_name:
                return index
        return None

    def _all_display_item_refs(self) -> List[ObjectRef]:
        refs: List[ObjectRef] = []
        for index, _, class_name in self.iter_objects():
            if class_name and class_name.endswith("LookinDisplayItem"):
                refs.append(ObjectRef(index))
        return refs

    def _refs_from_collection(self, value: Any) -> List[ObjectRef]:
        refs: List[ObjectRef] = []
        ref_index = self.resolve_ref_index(value)
        if ref_index is not None:
            obj = self.objects[ref_index]
            if isinstance(obj, dict):
                value = obj.get("NS.objects") or []
        if isinstance(value, list):
            for item in value:
                index = self.resolve_ref_index(item)
                if index is not None:
                    refs.append(ObjectRef(index))
        return refs

    @staticmethod
    def _first_field(raw: Dict[str, Any], names: Sequence[str]) -> Any:
        normalized = {LookinArchive._normalized_key(key): key for key in raw.keys()}
        for name in names:
            key = normalized.get(LookinArchive._normalized_key(name))
            if key is not None:
                return raw[key]
        return None

    @staticmethod
    def _normalized_key(key: Any) -> str:
        return str(key).replace("_", "").lower()

    def display_items(self, include_raw: bool = False) -> List[NormalizedItem]:
        roots = self.hierarchy_roots()
        items: List[NormalizedItem] = []
        visited: Set[int] = set()

        def visit(ref: ObjectRef, depth: int) -> None:
            if ref.index in visited:
                return
            visited.add(ref.index)
            normalized = self._normalize_display_item(ref.index, depth, include_raw=include_raw)
            items.append(normalized)
            raw = self.objects[ref.index]
            if isinstance(raw, dict):
                subitems = self._first_field(raw, ("subitems", "_subitems", "children", "_children"))
                for child_ref in self._refs_from_collection(subitems):
                    visit(child_ref, depth + 1)

        for root in roots:
            visit(root, 0)

        if not items:
            for ref in self._all_display_item_refs():
                visit(ref, 0)
        return items

    def _normalize_display_item(self, index: int, depth: int, include_raw: bool) -> NormalizedItem:
        raw = self.objects[index]
        if not isinstance(raw, dict):
            raise ToolError(f"Object {index} is not a LookinDisplayItem.")

        view_object = self._object_summary(self._first_field(raw, ("viewObject", "_viewObject")))
        layer_object = self._object_summary(self._first_field(raw, ("layerObject", "_layerObject")))
        controller_object = self._object_summary(
            self._first_field(raw, ("hostViewControllerObject", "_hostViewControllerObject"))
        )

        custom_info = self.resolve(self._first_field(raw, ("customInfo", "_customInfo")), depth=3)
        custom_title = self._scalar(self._first_field(raw, ("customDisplayTitle", "_customDisplayTitle")))
        title = self._value_from_decoded(custom_info, ("title", "_title"))
        if not title:
            title = custom_title
        if not title and view_object:
            title = self._simple_class_name(view_object.get("rawClassName") or view_object.get("className"))
        if not title and layer_object:
            title = self._simple_class_name(layer_object.get("rawClassName") or layer_object.get("className"))

        subtitle = self._value_from_decoded(custom_info, ("subtitle", "_subtitle"))
        if not subtitle and controller_object:
            controller_name = self._simple_class_name(
                controller_object.get("rawClassName") or controller_object.get("className")
            )
            if controller_name:
                subtitle = f"{controller_name}.view"
        if not subtitle:
            source_object = view_object or layer_object
            if source_object:
                subtitle = source_object.get("specialTrace")

        subitems = self._refs_from_collection(self._first_field(raw, ("subitems", "_subitems", "children", "_children")))
        raw_detail = self.resolve(ObjectRef(index), depth=4) if include_raw else None

        return NormalizedItem(
            item_id=str(index),
            object_index=index,
            title=title,
            subtitle=subtitle,
            depth=depth,
            child_count=len(subitems),
            view_object=view_object,
            layer_object=layer_object,
            controller_object=controller_object,
            frame=self.resolve(self._first_field(raw, ("frame", "_frame")), depth=3),
            bounds=self.resolve(self._first_field(raw, ("bounds", "_bounds")), depth=3),
            hidden=self._bool(self._first_field(raw, ("inHiddenHierarchy", "_inHiddenHierarchy"))),
            displaying=self._bool(self._first_field(raw, ("displayingInHierarchy", "_displayingInHierarchy"))),
            raw_class=self.class_name_for_index(index),
            raw=raw_detail if isinstance(raw_detail, dict) else None,
        )

    def _object_summary(self, value: Any) -> Optional[Dict[str, Any]]:
        ref_index = self.resolve_ref_index(value)
        if ref_index is None or ref_index == 0:
            return None
        decoded = self.resolve(ObjectRef(ref_index), depth=4)
        if not isinstance(decoded, dict):
            return None
        result = {
            "object_index": ref_index,
            "rawClassName": self._value_from_decoded(decoded, ("rawClassName", "_rawClassName")),
            "className": self._value_from_decoded(decoded, ("className", "_className")),
            "oid": self._value_from_decoded(decoded, ("oid", "_oid")),
            "memoryAddress": self._value_from_decoded(decoded, ("memoryAddress", "_memoryAddress")),
            "specialTrace": self._value_from_decoded(decoded, ("specialTrace", "_specialTrace")),
        }
        return {key: val for key, val in result.items() if val is not None}

    def _scalar(self, value: Any) -> Any:
        return self.resolve(value, depth=2)

    @staticmethod
    def _value_from_decoded(decoded: Any, names: Sequence[str]) -> Any:
        if not isinstance(decoded, dict):
            return None
        normalized = {LookinArchive._normalized_key(key): key for key in decoded.keys()}
        for name in names:
            key = normalized.get(LookinArchive._normalized_key(name))
            if key is not None:
                value = decoded.get(key)
                if isinstance(value, dict) and "__ref" in value:
                    continue
                return value
        return None

    @staticmethod
    def _simple_class_name(raw_name: Any) -> Optional[str]:
        if not isinstance(raw_name, str) or not raw_name:
            return None
        cleaned = raw_name.split("<", 1)[0]
        return cleaned.split(".")[-1]

    def _bool(self, value: Any) -> Optional[bool]:
        resolved = self.resolve(value, depth=2)
        if isinstance(resolved, bool):
            return resolved
        if isinstance(resolved, (int, float)):
            return bool(resolved)
        return None


def parse_response_format(value: Any) -> ResponseFormat:
    try:
        return ResponseFormat(str(value or ResponseFormat.MARKDOWN.value))
    except ValueError as exc:
        raise ToolError("response_format must be 'markdown' or 'json'.") from exc


def pagination(params: Dict[str, Any]) -> Tuple[int, int]:
    limit = int(params.get("limit", DEFAULT_LIMIT))
    offset = int(params.get("offset", 0))
    if limit < 1 or limit > MAX_LIMIT:
        raise ToolError(f"limit must be between 1 and {MAX_LIMIT}.")
    if offset < 0:
        raise ToolError("offset must be greater than or equal to 0.")
    return limit, offset


def paged(items: Sequence[Any], limit: int, offset: int) -> Tuple[List[Any], Dict[str, Any]]:
    page = list(items[offset : offset + limit])
    next_offset = offset + len(page) if offset + len(page) < len(items) else None
    return page, {
        "total_count": len(items),
        "count": len(page),
        "offset": offset,
        "limit": limit,
        "has_more": next_offset is not None,
        "next_offset": next_offset,
    }


def markdown_table(headers: Sequence[str], rows: Sequence[Sequence[Any]]) -> str:
    escaped_rows = [[str(cell if cell is not None else "").replace("\n", " ") for cell in row] for row in rows]
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in escaped_rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def tool_inspect_file(params: Dict[str, Any]) -> str:
    path = require_path(params)
    response_format = parse_response_format(params.get("response_format"))
    archive = LookinArchive(path)
    items = archive.display_items()
    app_info = archive.decoded_object_by_class("LookinAppInfo", depth=4)
    hierarchy_info = archive.decoded_object_by_class("LookinHierarchyInfo", depth=3)
    class_counts = archive.class_counts()
    result = {
        "path": archive.path,
        "root_object_index": archive.root_ref(),
        "display_item_count": len(items),
        "root_display_item_count": len([item for item in items if item.depth == 0]),
        "app_info": app_info,
        "hierarchy_info": hierarchy_info,
        "top_classes": dict(list(class_counts.items())[:20]),
    }
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    lines = [
        "# Lookin File",
        f"- Path: `{archive.path}`",
        f"- Display items: {result['display_item_count']}",
        f"- Root display items: {result['root_display_item_count']}",
        f"- Root object index: {result['root_object_index']}",
        "",
        "## Top Classes",
    ]
    lines.extend(f"- `{name}`: {count}" for name, count in result["top_classes"].items())
    return "\n".join(lines)


def tool_list_hierarchy(params: Dict[str, Any]) -> str:
    path = require_path(params)
    response_format = parse_response_format(params.get("response_format"))
    limit, offset = pagination(params)
    archive = LookinArchive(path)
    items = [item.compact() for item in archive.display_items()]
    page, meta = paged(items, limit, offset)
    result = {**meta, "items": page}
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    rows = [
        [
            item.get("id"),
            "  " * int(item.get("depth", 0)) + str(item.get("title") or ""),
            item.get("subtitle") or "",
            item.get("child_count", 0),
        ]
        for item in page
    ]
    return "\n".join(
        [
            f"# Hierarchy ({meta['count']}/{meta['total_count']})",
            markdown_table(["id", "title", "subtitle", "children"], rows),
            pagination_hint(meta),
        ]
    )


def tool_search_hierarchy(params: Dict[str, Any]) -> str:
    path = require_path(params)
    query = str(params.get("query") or "").strip()
    if not query:
        raise ToolError("query is required.")
    response_format = parse_response_format(params.get("response_format"))
    limit, offset = pagination(params)
    pattern = query.lower()
    archive = LookinArchive(path)
    all_items = archive.display_items()
    matched = []
    for item in all_items:
        compact = item.compact()
        haystack = json.dumps(compact, ensure_ascii=False).lower()
        if pattern in haystack:
            matched.append(compact)
    page, meta = paged(matched, limit, offset)
    result = {**meta, "query": query, "items": page}
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    rows = [
        [
            item.get("id"),
            "  " * int(item.get("depth", 0)) + str(item.get("title") or ""),
            item.get("subtitle") or "",
            item.get("view", {}).get("memoryAddress") or item.get("layer", {}).get("memoryAddress") or "",
        ]
        for item in page
    ]
    return "\n".join(
        [
            f"# Search: `{query}` ({meta['count']}/{meta['total_count']})",
            markdown_table(["id", "title", "subtitle", "address"], rows),
            pagination_hint(meta),
        ]
    )


def tool_get_item(params: Dict[str, Any]) -> str:
    path = require_path(params)
    item_id = str(params.get("item_id") or "").strip()
    if not item_id:
        raise ToolError("item_id is required. Use lookin_list_hierarchy or lookin_search_hierarchy first.")
    response_format = parse_response_format(params.get("response_format"))
    include_raw = bool(params.get("include_raw", False))
    archive = LookinArchive(path)
    item = find_item(archive, item_id, include_raw=include_raw)
    result = item.detailed()
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    lines = [
        f"# Item `{item.item_id}`",
        f"- Title: {item.title or ''}",
        f"- Subtitle: {item.subtitle or ''}",
        f"- Depth: {item.depth}",
        f"- Children: {item.child_count}",
        f"- View: `{item.view_object}`",
        f"- Layer: `{item.layer_object}`",
        f"- Frame: `{json.dumps(item.frame, ensure_ascii=False)}`",
        f"- Bounds: `{json.dumps(item.bounds, ensure_ascii=False)}`",
    ]
    if include_raw and item.raw is not None:
        lines.extend(["", "## Raw", "```json", json.dumps(item.raw, ensure_ascii=False, indent=2), "```"])
    return "\n".join(lines)


def find_item(archive: LookinArchive, item_id: str, include_raw: bool) -> NormalizedItem:
    for item in archive.display_items(include_raw=include_raw):
        if item.item_id == item_id:
            return item
        for obj in (item.view_object, item.layer_object):
            if not obj:
                continue
            if str(obj.get("oid")) == item_id or str(obj.get("memoryAddress")) == item_id:
                return item
    raise ToolError(f"No hierarchy item found for item_id '{item_id}'.")


def pagination_hint(meta: Dict[str, Any]) -> str:
    if meta.get("has_more"):
        return f"\nMore results available: call again with offset={meta['next_offset']}."
    return ""


def require_path(params: Dict[str, Any]) -> str:
    path = str(params.get("path") or "").strip()
    if not path:
        raise ToolError("path is required and must point to a local .lookin file.")
    return path


def bridge_url(params: Dict[str, Any]) -> str:
    raw = str(params.get("bridge_url") or DEFAULT_BRIDGE_URL).strip().rstrip("/")
    if not raw.startswith("http://127.0.0.1:") and not raw.startswith("http://localhost:"):
        raise ToolError("bridge_url must point to a localhost Lookin MCP bridge.")
    return raw


def live_snapshot_archive(params: Dict[str, Any]) -> LookinArchive:
    base_url = bridge_url(params)
    refresh = bool(params.get("refresh", True))
    compression = float(params.get("compression", 0.5))
    if compression < 0.01 or compression > 1:
        raise ToolError("compression must be between 0.01 and 1.")

    query = urllib.parse.urlencode({"refresh": "1" if refresh else "0", "compression": str(compression)})
    url = f"{base_url}/snapshot?{query}"
    request = urllib.request.Request(url, method="GET", headers={"Accept": "application/octet-stream"})
    try:
        with urllib.request.urlopen(request, timeout=LIVE_TIMEOUT_SECONDS) as response:
            data = response.read()
            source = response.headers.get("X-Lookin-Live-Source", "live")
            return LookinArchive(f"<lookin live snapshot: {source}>", data=data)
    except urllib.error.HTTPError as exc:
        message = exc.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(message)
            message = payload.get("error") or payload.get("recoverySuggestion") or message
        except json.JSONDecodeError:
            pass
        raise ToolError(f"Lookin live bridge returned HTTP {exc.code}: {message}") from exc
    except urllib.error.URLError as exc:
        raise ToolError(
            "Cannot connect to Lookin live bridge. Start the updated Lookin app first, "
            f"then retry. Detail: {exc.reason}"
        ) from exc


def tool_live_status(params: Dict[str, Any]) -> str:
    response_format = parse_response_format(params.get("response_format"))
    url = f"{bridge_url(params)}/status"
    request = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise ToolError(
            "Cannot connect to Lookin live bridge. Start the updated Lookin app first, "
            f"then retry. Detail: {exc.reason}"
        ) from exc

    if response_format == ResponseFormat.JSON:
        return json.dumps(payload, ensure_ascii=False, indent=2)

    lines = [
        "# Lookin Live Bridge",
        f"- Connected app: {'yes' if payload.get('connected') else 'no'}",
        f"- Cached hierarchy: {'yes' if payload.get('hasCachedHierarchy') else 'no'}",
        f"- Port: {payload.get('port')}",
    ]
    app = payload.get("app")
    if isinstance(app, dict):
        lines.extend(["", "## App"])
        lines.extend(f"- {key}: {value}" for key, value in app.items())
    return "\n".join(lines)


def tool_live_inspect_current(params: Dict[str, Any]) -> str:
    response_format = parse_response_format(params.get("response_format"))
    archive = live_snapshot_archive(params)
    items = archive.display_items()
    app_info = archive.decoded_object_by_class("LookinAppInfo", depth=4)
    result = {
        "source": archive.path,
        "display_item_count": len(items),
        "root_display_item_count": len([item for item in items if item.depth == 0]),
        "app_info": app_info,
        "top_classes": dict(list(archive.class_counts().items())[:20]),
    }
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    lines = [
        "# Lookin Live Snapshot",
        f"- Source: `{archive.path}`",
        f"- Display items: {result['display_item_count']}",
        f"- Root display items: {result['root_display_item_count']}",
        "",
        "## Top Classes",
    ]
    lines.extend(f"- `{name}`: {count}" for name, count in result["top_classes"].items())
    return "\n".join(lines)


def tool_live_list_hierarchy(params: Dict[str, Any]) -> str:
    response_format = parse_response_format(params.get("response_format"))
    limit, offset = pagination(params)
    archive = live_snapshot_archive(params)
    items = [item.compact() for item in archive.display_items()]
    page, meta = paged(items, limit, offset)
    result = {**meta, "source": archive.path, "items": page}
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    rows = [
        [
            item.get("id"),
            "  " * int(item.get("depth", 0)) + str(item.get("title") or ""),
            item.get("subtitle") or "",
            item.get("child_count", 0),
        ]
        for item in page
    ]
    return "\n".join(
        [
            f"# Live Hierarchy ({meta['count']}/{meta['total_count']})",
            markdown_table(["id", "title", "subtitle", "children"], rows),
            pagination_hint(meta),
        ]
    )


def tool_live_search_hierarchy(params: Dict[str, Any]) -> str:
    query = str(params.get("query") or "").strip()
    if not query:
        raise ToolError("query is required.")
    response_format = parse_response_format(params.get("response_format"))
    limit, offset = pagination(params)
    archive = live_snapshot_archive(params)
    pattern = query.lower()
    matched = []
    for item in archive.display_items():
        compact = item.compact()
        if pattern in json.dumps(compact, ensure_ascii=False).lower():
            matched.append(compact)
    page, meta = paged(matched, limit, offset)
    result = {**meta, "source": archive.path, "query": query, "items": page}
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    rows = [
        [
            item.get("id"),
            "  " * int(item.get("depth", 0)) + str(item.get("title") or ""),
            item.get("subtitle") or "",
            item.get("view", {}).get("memoryAddress") or item.get("layer", {}).get("memoryAddress") or "",
        ]
        for item in page
    ]
    return "\n".join(
        [
            f"# Live Search: `{query}` ({meta['count']}/{meta['total_count']})",
            markdown_table(["id", "title", "subtitle", "address"], rows),
            pagination_hint(meta),
        ]
    )


def tool_live_get_item(params: Dict[str, Any]) -> str:
    item_id = str(params.get("item_id") or "").strip()
    if not item_id:
        raise ToolError("item_id is required. Use lookin_live_list_hierarchy or lookin_live_search_hierarchy first.")
    response_format = parse_response_format(params.get("response_format"))
    include_raw = bool(params.get("include_raw", False))
    archive = live_snapshot_archive(params)
    item = find_item(archive, item_id, include_raw=include_raw)
    result = {"source": archive.path, **item.detailed()}
    if response_format == ResponseFormat.JSON:
        return json.dumps(result, ensure_ascii=False, indent=2)

    lines = [
        f"# Live Item `{item.item_id}`",
        f"- Source: `{archive.path}`",
        f"- Title: {item.title or ''}",
        f"- Subtitle: {item.subtitle or ''}",
        f"- Depth: {item.depth}",
        f"- Children: {item.child_count}",
        f"- View: `{item.view_object}`",
        f"- Layer: `{item.layer_object}`",
        f"- Frame: `{json.dumps(item.frame, ensure_ascii=False)}`",
        f"- Bounds: `{json.dumps(item.bounds, ensure_ascii=False)}`",
    ]
    if include_raw and item.raw is not None:
        lines.extend(["", "## Raw", "```json", json.dumps(item.raw, ensure_ascii=False, indent=2), "```"])
    return "\n".join(lines)


def tool_live_capture_current_layer_screenshot(params: Dict[str, Any]) -> str:
    response_format = parse_response_format(params.get("response_format"))
    image_type = str(params.get("image_type") or "auto").strip()
    if image_type not in {"auto", "group", "solo"}:
        raise ToolError("image_type must be 'auto', 'group', or 'solo'.")

    output_path = str(params.get("output_path") or "").strip()
    if output_path:
        target_path = Path(output_path).expanduser()
    else:
        target_path = Path("/private/tmp") / f"lookin_current_layer_{int(time.time())}.tiff"
    if target_path.suffix.lower() not in {".tif", ".tiff"}:
        raise ToolError("output_path must end with .tif or .tiff.")
    target_path.parent.mkdir(parents=True, exist_ok=True)

    url = f"{bridge_url(params)}/selected-screenshot?{urllib.parse.urlencode({'type': image_type})}"
    request = urllib.request.Request(url, method="GET", headers={"Accept": "image/tiff"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            data = response.read()
            metadata = {
                "path": str(target_path),
                "bytes": len(data),
                "content_type": response.headers.get("Content-Type"),
                "image_type": response.headers.get("X-Lookin-Screenshot-Type"),
                "item_title": response.headers.get("X-Lookin-Item-Title"),
                "layer_oid": response.headers.get("X-Lookin-Layer-Oid"),
            }
    except urllib.error.HTTPError as exc:
        message = exc.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(message)
            message = payload.get("error") or payload.get("recoverySuggestion") or message
        except json.JSONDecodeError:
            pass
        raise ToolError(f"Lookin live bridge returned HTTP {exc.code}: {message}") from exc
    except urllib.error.URLError as exc:
        raise ToolError(
            "Cannot connect to Lookin live bridge. Start the updated Lookin app first, "
            f"then retry. Detail: {exc.reason}"
        ) from exc

    target_path.write_bytes(data)
    metadata = {key: value for key, value in metadata.items() if value is not None}
    if response_format == ResponseFormat.JSON:
        return json.dumps(metadata, ensure_ascii=False, indent=2)

    lines = [
        "# Current Layer Screenshot",
        f"- Path: `{metadata['path']}`",
        f"- Bytes: {metadata['bytes']}",
    ]
    if metadata.get("item_title"):
        lines.append(f"- Item: {metadata['item_title']}")
    if metadata.get("layer_oid"):
        lines.append(f"- Layer oid: {metadata['layer_oid']}")
    if metadata.get("image_type"):
        lines.append(f"- Type: {metadata['image_type']}")
    return "\n".join(lines)


TOOLS = {
    "lookin_live_status": {
        "description": "Check whether the updated Lookin app local live bridge is reachable and has a connected app.",
        "handler": tool_live_status,
        "inputSchema": {
            "type": "object",
            "properties": {
                "bridge_url": {"type": "string", "default": DEFAULT_BRIDGE_URL},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "additionalProperties": False,
        },
    },
    "lookin_live_inspect_current": {
        "description": "Fetch and inspect a live snapshot from the currently connected Lookin app.",
        "handler": tool_live_inspect_current,
        "inputSchema": {
            "type": "object",
            "properties": {
                "bridge_url": {"type": "string", "default": DEFAULT_BRIDGE_URL},
                "refresh": {"type": "boolean", "default": True},
                "compression": {"type": "number", "minimum": 0.01, "maximum": 1, "default": 0.5},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "additionalProperties": False,
        },
    },
    "lookin_live_list_hierarchy": {
        "description": "Fetch a live snapshot from the currently connected Lookin app and list hierarchy items.",
        "handler": tool_live_list_hierarchy,
        "inputSchema": {
            "type": "object",
            "properties": {
                "bridge_url": {"type": "string", "default": DEFAULT_BRIDGE_URL},
                "refresh": {"type": "boolean", "default": True},
                "compression": {"type": "number", "minimum": 0.01, "maximum": 1, "default": 0.5},
                "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LIMIT, "default": DEFAULT_LIMIT},
                "offset": {"type": "integer", "minimum": 0, "default": 0},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "additionalProperties": False,
        },
    },
    "lookin_live_search_hierarchy": {
        "description": "Fetch a live snapshot from the currently connected Lookin app and search hierarchy items.",
        "handler": tool_live_search_hierarchy,
        "inputSchema": {
            "type": "object",
            "properties": {
                "bridge_url": {"type": "string", "default": DEFAULT_BRIDGE_URL},
                "refresh": {"type": "boolean", "default": True},
                "compression": {"type": "number", "minimum": 0.01, "maximum": 1, "default": 0.5},
                "query": {"type": "string", "description": "Case-insensitive search text.", "minLength": 1},
                "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LIMIT, "default": DEFAULT_LIMIT},
                "offset": {"type": "integer", "minimum": 0, "default": 0},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    "lookin_live_get_item": {
        "description": "Fetch a live snapshot from the currently connected Lookin app and get one hierarchy item.",
        "handler": tool_live_get_item,
        "inputSchema": {
            "type": "object",
            "properties": {
                "bridge_url": {"type": "string", "default": DEFAULT_BRIDGE_URL},
                "refresh": {"type": "boolean", "default": True},
                "compression": {"type": "number", "minimum": 0.01, "maximum": 1, "default": 0.5},
                "item_id": {"type": "string", "description": "Item id from live list/search, object oid, or memory address."},
                "include_raw": {"type": "boolean", "default": False},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "required": ["item_id"],
            "additionalProperties": False,
        },
    },
    "lookin_live_capture_current_layer_screenshot": {
        "description": "Save the screenshot of the currently selected Lookin hierarchy item to a local TIFF file.",
        "handler": tool_live_capture_current_layer_screenshot,
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": False,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "bridge_url": {"type": "string", "default": DEFAULT_BRIDGE_URL},
                "image_type": {"type": "string", "enum": ["auto", "group", "solo"], "default": "auto"},
                "output_path": {
                    "type": "string",
                    "description": "Optional local output path ending in .tif or .tiff. Defaults to /private/tmp.",
                },
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "additionalProperties": False,
        },
    },
    "lookin_inspect_file": {
        "description": "Inspect metadata and archive shape of a local Lookin .lookin file.",
        "handler": tool_inspect_file,
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute or user-relative path to a .lookin file."},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    "lookin_list_hierarchy": {
        "description": "List normalized hierarchy items from a local Lookin .lookin file.",
        "handler": tool_list_hierarchy,
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute or user-relative path to a .lookin file."},
                "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LIMIT, "default": DEFAULT_LIMIT},
                "offset": {"type": "integer", "minimum": 0, "default": 0},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    "lookin_search_hierarchy": {
        "description": "Search hierarchy items by class name, title, subtitle, object id, memory address, or decoded fields.",
        "handler": tool_search_hierarchy,
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute or user-relative path to a .lookin file."},
                "query": {"type": "string", "description": "Case-insensitive search text.", "minLength": 1},
                "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LIMIT, "default": DEFAULT_LIMIT},
                "offset": {"type": "integer", "minimum": 0, "default": 0},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "required": ["path", "query"],
            "additionalProperties": False,
        },
    },
    "lookin_get_item": {
        "description": "Get details for one hierarchy item by listed item id, object oid, or memory address.",
        "handler": tool_get_item,
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute or user-relative path to a .lookin file."},
                "item_id": {"type": "string", "description": "Item id from list/search, object oid, or memory address."},
                "include_raw": {"type": "boolean", "default": False, "description": "Include decoded raw archive fields."},
                "response_format": {"type": "string", "enum": ["markdown", "json"], "default": "markdown"},
            },
            "required": ["path", "item_id"],
            "additionalProperties": False,
        },
    },
}


def read_message() -> Optional[Dict[str, Any]]:
    headers: Dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if line == b"":
            return None
        if line in (b"\r\n", b"\n"):
            break
        decoded = line.decode("ascii", errors="replace").strip()
        if ":" in decoded:
            key, value = decoded.split(":", 1)
            headers[key.lower()] = value.strip()

    content_length = headers.get("content-length")
    if not content_length:
        return None
    body = sys.stdin.buffer.read(int(content_length))
    return json.loads(body.decode("utf-8"))


def write_message(payload: Dict[str, Any]) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def response(message_id: Any, result: Any) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def error_response(message_id: Any, code: int, message: str) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def tool_definitions() -> List[Dict[str, Any]]:
    definitions: List[Dict[str, Any]] = []
    default_annotations = {
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    }
    for name, spec in TOOLS.items():
        definitions.append(
            {
                "name": name,
                "description": spec["description"],
                "inputSchema": spec["inputSchema"],
                "annotations": spec.get("annotations", default_annotations),
            }
        )
    return definitions


def handle_request(message: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    method = message.get("method")
    message_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        client_protocol = params.get("protocolVersion") or "2024-11-05"
        return response(
            message_id,
            {
                "protocolVersion": client_protocol,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        )

    if method in {"notifications/initialized", "notifications/cancelled"}:
        return None

    if method == "tools/list":
        return response(message_id, {"tools": tool_definitions()})

    if method == "tools/call":
        tool_name = params.get("name")
        arguments = params.get("arguments") or {}
        spec = TOOLS.get(tool_name)
        if not spec:
            return error_response(message_id, -32602, f"Unknown tool: {tool_name}")
        try:
            text = spec["handler"](arguments)
            return response(message_id, {"content": [{"type": "text", "text": text}]})
        except ToolError as exc:
            return response(message_id, {"isError": True, "content": [{"type": "text", "text": str(exc)}]})
        except Exception:
            print(traceback.format_exc(), file=sys.stderr)
            return response(
                message_id,
                {
                    "isError": True,
                    "content": [
                        {
                            "type": "text",
                            "text": "Unexpected server error. See server stderr for details.",
                        }
                    ],
                },
            )

    return error_response(message_id, -32601, f"Method not found: {method}")


def main() -> None:
    while True:
        message = read_message()
        if message is None:
            break
        if "id" not in message:
            handle_request(message)
            continue
        result = handle_request(message)
        if result is not None:
            write_message(result)


if __name__ == "__main__":
    main()
