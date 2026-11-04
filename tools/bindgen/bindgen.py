#!/usr/bin/env python3
"""Regenerate the self-owned kernel surface: C ABI + Go `//export` bodies + Dart FFI bindings.

The core's public surface is fixed by `app/libs/ThroneCore-sources.jar` (gobind's Java
classes for `ThroneCore/mobile`). This tool reads those sources and emits the three halves
of a binding layer the repository owns:

* `bridge_symbols.h` — the C ABI contract: one prototype per crossing, plus the callback
  table the Android JNI shim fills in and the Dart port plumbing.
* `bridge_calls.go`  — the Go `//export` implementations (package `mobile`, patched into
  the core tree) with real method bodies.
* `throne_ffi.dart`  — Dart `dart:ffi` bindings: raw lookups plus typed wrappers.

Architecture (dart:ffi direct, no method channel for kernel control):

    Dart ──dart:ffi──▶ C ABI (throne_*) ──▶ Go mobile package ──▶ sing-box core
      ▲                                      │
      └── ReceivePort ◀── Dart_PostCObject ──┘   (events: logs, test results)
    Kotlin ──JNI──▶ libcore.so (core.cpp) ──▶ same C ABI   (Android duties: startTun,
                                                             protect, resolverProcess)

Everything that is not a primitive or a string crosses as an `int64_t` handle (the role
`go.Seq`'s refnum played). Strings return as `char *` allocated by Go and released with
`throne_free`. Interfaces implemented by the platform (PlatformInterface, LocalDNSTransport,
Func) cross through `throne_callbacks_t`, a table of C function pointers filled by
`JNI_OnLoad` — the bettbox pattern. Interfaces implemented by Go (iterators, TunOptions,
InterfaceUpdateListener) are plain C ABI calls on handles. Test handlers and the log sink
cross as Dart ports.

    python3 tools/bindgen/bindgen.py --emit manifest --go-src ../throne-go/core_mobile
    python3 tools/bindgen/bindgen.py --emit all --out build/bindgen --go-src ../throne-go/core_mobile

Everything this emits is generated; edit the generator (or the templates it owns), never
the output.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from dataclasses import dataclass, field, asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCES_JAR = REPO_ROOT / "app" / "libs" / "ThroneCore-sources.jar"
JAVA_PKG = "io.throneproj.mobile"

# ---------------------------------------------------------------------------
# Who implements each bound interface decides which way the methods cross.
# ---------------------------------------------------------------------------

# Implemented in Go (newIterator wrappers, tunOptions, the interface monitor).
# Their methods are ordinary C ABI calls on handles — Dart/JNI invoke them.
GO_IMPL_INTERFACES = {
    "StringIterator", "Int32Iterator", "RoutePrefixIterator", "NetworkInterfaceIterator",
    "OutboundGroupIterator", "OutboundGroupItemIterator", "AutoSelectorMemberIterator",
    "AutoSelectorStatusIterator", "ResolvedDomainIterator", "TunOptions",
    "InterfaceUpdateListener",
}

# Implemented on the platform side and reached through the JNI callback table.
JNI_INTERFACES = {"PlatformInterface", "LocalDNSTransport", "Func"}

# Implemented on the platform side but delivered as Dart port events instead of
# synchronous callbacks (the bettbox message-port pattern).
PORT_INTERFACES = {"LogSink", "URLTestHandler", "IPTestHandler", "SpeedTestHandler"}

# Parameters that change shape on the C ABI.
DROP_PARAMS = {
    "PlatformInterface": "platform is the global bridge (throne_register_callbacks)",
    "LogSink": "logs always stream to the attached message port",
}
PORT_PARAMS = {"URLTestHandler", "IPTestHandler", "SpeedTestHandler"}  # -> int64 port
JSON_PARAMS = {"StringIterator"}  # -> char * json array (Go wraps newIterator)
JNI_PTR_PARAMS = {"Func"}  # -> void * java object (Go wraps a Func adapter)

# Runtime / lifecycle exports layered on top of the 340+25 surface.
EXTRA_EXPORTS = [
    ("throne_init_dart_api", "void", [("void *", "api")],
     "Dart_InitializeApiDL — pass NativeApi.initializeApiDLData once at startup."),
    ("throne_attach_message_port", "void", [("int64_t", "port")],
     "Receives unsolicited events (logs, ...) as JSON strings via Dart_PostCObject."),
    ("throne_free", "void", [("char *", "p")],
     "Release a string returned by any throne_* export."),
    ("throne_last_error", "char *", [],
     "Error of the last failing throne_* call (thread-safe); empty when none. "
     "Read and clear after calls whose Java form declares `throws`."),
    ("throne_handle_release", "void", [("int64_t", "h")],
     "Drop a handle returned by a constructor or an object-returning call."),
    ("throne_start_tun", "int32_t", [("int32_t", "fd"), ("void *", "tun")],
     "Feed the VpnService fd and the TunInterface token to the kernel before Start."),
    ("throne_stop_tun", "void", [], "Stop the tun started by throne_start_tun."),
    ("throne_suspend", "void", [("int32_t", "suspended")],
     "0 = resume, 1 = suspend, 2 = doze-suspend."),
    ("throne_register_callbacks", "void", [("throne_callbacks_t *", "table")],
     "Filled by JNI_OnLoad in core.cpp; Go calls the platform through these."),
    ("throne_getAndroidVpnOptions", "char *", [("char *", "coreConfig")],
     "Tun inbound section of the core config as JSON, for VpnService.Builder "
     "(establish() → fd → throne_start_tun)."),
    ("throne_TunOptions_toJSON", "char *", [("int64_t", "options")],
     "A TunOptions handle as JSON {mtu,inet4Address[],autoRoute,dnsMode,...} — "
     "the open_tun callback reads the fields it needs to build "
     "VpnService.Builder without the gobind TunOptions type."),
]

# The Go->platform callback table (filled by the JNI shim). All object graphs cross as
# JSON so the table stays primitive/string-shaped like bettbox's.
CALLBACKS = [
    # (c name, c return, [(c type, name)], doc)
    ("open_tun", "int32_t", [("int64_t", "options")],
     "Establish the VPN for these tun options (a TunOptions handle; read fields "
     "via throne_TunOptions_toJSON) and return the fd, or -1 on failure. The "
     "shim feeds the fd to the kernel through throne_start_tun with its "
     "TunInterface, so a pre-fed fd makes this call unnecessary."),
    ("protect", "void", [("void *", "tun"), ("int32_t", "fd")],
     "TunInterface.protect — VpnService.protect(fd)."),
    ("resolver_process", "const char *",
     [("void *", "tun"), ("int32_t", "protocol"), ("const char *", "source"),
      ("const char *", "target"), ("int32_t", "uid")],
     "TunInterface.resolverProcess — package name owning a connection; caller frees."),
    ("release_object", "void", [("void *", "obj")], "Release a JNI global ref."),
    ("use_platform_auto_detect_interface_control", "int8_t", [("void *", "tun")], ""),
    ("auto_detect_interface_control", "const char *",
     [("void *", "tun"), ("int32_t", "fd")], "Returns error string or empty."),
    ("use_proc_fs", "int8_t", [("void *", "tun")], ""),
    ("find_connection_owner", "const char *",
     [("void *", "tun"), ("int32_t", "ip_protocol"), ("const char *", "source_address"),
      ("int32_t", "source_port"), ("const char *", "destination_address"),
      ("int32_t", "destination_port")],
     "JSON {userId,userName,processPath,packageNames[]} or empty on failure."),
    ("package_names_by_uid", "const char *", [("void *", "tun"), ("int32_t", "uid")],
     "JSON string array."),
    ("start_default_interface_monitor", "const char *",
     [("void *", "tun"), ("int64_t", "listener")],
     "listener is a Go InterfaceUpdateListener handle; report changes by calling "
     "throne_InterfaceUpdateListener_update* back."),
    ("close_default_interface_monitor", "const char *",
     [("void *", "tun"), ("int64_t", "listener")], ""),
    ("get_interfaces", "const char *", [("void *", "tun")],
     "JSON array of {index,mtu,name,addresses[],flags,type,dnsServer[],gateway[],metered}."),
    ("read_wifi_state", "const char *", [("void *", "tun")],
     "JSON {ssid,bssid} or empty."),
    ("clear_dns_cache", "void", [("void *", "tun")], ""),
    ("send_notification", "const char *",
     [("void *", "tun"), ("const char *", "notification_json")], ""),
    ("cancel_notification", "const char *",
     [("void *", "tun"), ("const char *", "identifier"), ("int32_t", "type_id")], ""),
    ("local_dns_raw", "int8_t", [("void *", "tun")], "LocalDNSTransport.Raw."),
    ("local_dns_lookup", "const char *",
     [("void *", "tun"), ("int64_t", "ctx"), ("const char *", "network"),
      ("const char *", "domain")], "Error string or empty."),
    ("local_dns_exchange", "const char *",
     [("void *", "tun"), ("int64_t", "ctx"), ("const uint8_t *", "message"),
      ("int32_t", "message_len")], "Error string or empty."),
    ("func_invoke", "void", [("void *", "obj")], "Func.Invoke on a Java-side Func."),
]


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------


@dataclass
class Param:
    type: str
    name: str


@dataclass
class Method:
    """One member of the boundary. `native` methods cross Java -> Go; interface
    methods cross Go -> Java (a callback)."""

    name: str
    returns: str
    params: list[Param] = field(default_factory=list)
    throws: bool = False
    is_static: bool = False
    is_ctor: bool = False
    doc: str = ""


@dataclass
class Cls:
    name: str
    kind: str  # "proxy" | "interface" | "abstract"
    methods: list[Method] = field(default_factory=list)
    proxy_for: list[str] = field(default_factory=list)
    doc: str = ""


# ---------------------------------------------------------------------------
# Parsing gobind's Java (highly regular output; a real Java parser is not needed)
# ---------------------------------------------------------------------------

CLASS_RE = re.compile(
    r"^(?P<doc>(?:/\*\*.*?\*/\s*)?)"
    r"public\s+(?P<mods>(?:final\s+|abstract\s+)*)"
    r"(?P<kind>class|interface)\s+(?P<name>\w+)"
    r"(?:\s+implements\s+(?P<impl>[^{]+))?\s*\{",
    re.S | re.M,
)
METHOD_RE = re.compile(
    r"^(?P<doc>(?:/\*\*.*?\*/\s*)?)"
    r"\s*public\s+(?P<mods>(?:(?:static|final|abstract|native)\s+)*)"
    r"(?P<ret>[\w.<>\[\]]+)\s+(?P<name>\w+)\s*\((?P<params>[^)]*)\)"
    r"(?P<throws>\s+throws\s+[^{;]+)?\s*(?P<term>[;{])",
    re.S | re.M,
)
CTOR_RE = re.compile(
    r"^\s*(?P<vis>public|private|protected)?\s*(?P<name>\w+)\s*\((?P<params>[^)]*)\)"
    r"(?P<throws>\s+throws\s+[^{;]+)?\s*\{",
    re.M,
)
NESTED_RE = re.compile(
    r"^\s*(?:private|public|protected|static|final|\s)*"
    r"(?:class|interface)\s+(\w+)\s*(?:implements\s+[^{]+)?\{",
    re.M,
)


def _strip_nested(body: str) -> str:
    """Drop the bodies of types nested inside the class, keeping only its own members."""
    out = []
    pos = 0
    while True:
        m = NESTED_RE.search(body, pos)
        if not m:
            out.append(body[pos:])
            break
        out.append(body[pos:m.start()])
        depth = 1
        i = m.end()
        while i < len(body) and depth:
            if body[i] == "{":
                depth += 1
            elif body[i] == "}":
                depth -= 1
            i += 1
        pos = i
    return "".join(out)


def _doc_of(raw: str) -> str:
    body = raw.strip()
    if body.startswith("/**") and body.endswith("*/"):
        body = body[3:-2]
    return "\n".join(l.strip().lstrip("*").strip() for l in body.splitlines()).strip()


def _params_of(raw: str) -> list[Param]:
    raw = raw.strip()
    if not raw:
        return []
    out = []
    for piece in raw.split(","):
        piece = piece.strip()
        if not piece:
            continue
        type_, name = piece.rsplit(" ", 1)
        out.append(Param(type_.strip(), name.strip()))
    return out


def parse_java(text: str, filename: str) -> Cls | None:
    m = CLASS_RE.search(text)
    if not m:
        return None
    name = m.group("name")
    kind = "interface" if m.group("kind") == "interface" else (
        "abstract" if "abstract" in (m.group("mods") or "") else "proxy"
    )
    impl = [p.strip() for p in (m.group("impl") or "").split(",") if p.strip()]
    cls = Cls(name=name, kind=kind, proxy_for=impl, doc=_doc_of(m.group("doc") or ""))

    body = text[m.end():]
    depth = 1
    cut = 0
    for i, ch in enumerate(body):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                cut = i
                break
    body = body[:cut]
    body = _strip_nested(body)

    for mm in METHOD_RE.finditer(body):
        mods = mm.group("mods") or ""
        ret = mm.group("ret")
        meth_name = mm.group("name")
        is_static = "static" in mods
        is_native = "native" in mods
        if meth_name in {"incRefnum", "equals", "hashCode", "toString", "touch"}:
            continue
        if meth_name.startswith("__"):
            cls.methods.append(
                Method(
                    name="<init>",
                    returns=ret,
                    params=_params_of(mm.group("params")),
                    throws=bool(mm.group("throws")),
                    is_static=is_static,
                    is_ctor=True,
                )
            )
            continue
        if cls.kind != "interface" and not is_native:
            continue
        cls.methods.append(
            Method(
                name=meth_name,
                returns=ret,
                params=_params_of(mm.group("params")),
                throws=bool(mm.group("throws")),
                is_static=is_static,
                doc=_doc_of(mm.group("doc") or ""),
            )
        )

    for cm in CTOR_RE.finditer(body):
        if cm.group("name") != name:
            continue
        if cm.group("vis") in (None, "private", "protected"):
            continue
        cls.methods.append(
            Method(
                name="<init>",
                returns="void",
                params=_params_of(cm.group("params")),
                throws=bool(cm.group("throws")),
                is_ctor=True,
            )
        )
    return cls


def load_sources() -> dict[str, Cls]:
    """Read every generated Java class out of the sources jar."""
    classes: dict[str, Cls] = {}
    with zipfile.ZipFile(SOURCES_JAR) as z:
        for info in z.infolist():
            if not info.filename.endswith(".java"):
                continue
            if "/go/" in info.filename:
                continue
            text = z.read(info).decode("utf-8")
            cls = parse_java(text, info.filename)
            if cls:
                classes[cls.name] = cls
    return classes


# ---------------------------------------------------------------------------
# Go source index — resolves Java names to the real Go member (field vs method)
# ---------------------------------------------------------------------------


@dataclass
class GoType:
    fields: set[str] = field(default_factory=set)
    methods: set[str] = field(default_factory=set)


@dataclass
class GoIndex:
    types: dict[str, GoType] = field(default_factory=dict)
    funcs: set[str] = field(default_factory=set)


TYPE_RE = re.compile(r"^type (\w+) (struct|interface)", re.M)
FIELD_RE = re.compile(r"^\t(\w+)\s+[\w\[\]\*\.]+", re.M)
METHOD_RE_GO = re.compile(r"^func \(\w+ \*?(\w+)\) (\w+)\(", re.M)
FUNC_RE_GO = re.compile(r"^func ([A-Z]\w+)\(", re.M)


def index_go(go_src: Path) -> GoIndex:
    idx = GoIndex()
    for f in sorted(go_src.glob("*.go")):
        text = f.read_text(encoding="utf-8")
        # type bodies
        for tm in TYPE_RE.finditer(text):
            t = GoType()
            start = tm.end()
            depth = 1 if tm.group(2) == "struct" else 1
            i = text.find("{", start)
            j = i + 1
            while j < len(text) and depth:
                if text[j] == "{":
                    depth += 1
                elif text[j] == "}":
                    depth -= 1
                j += 1
            body = text[i:j]
            if tm.group(2) == "struct":
                for fm in FIELD_RE.finditer(body):
                    t.fields.add(fm.group(1))
            else:
                for fm in re.finditer(r"^\t(\w+)\(", body, re.M):
                    t.methods.add(fm.group(1))
            idx.types.setdefault(tm.group(1), GoType()).fields |= t.fields
            idx.types[tm.group(1)].methods |= t.methods
        for mm in METHOD_RE_GO.finditer(text):
            idx.types.setdefault(mm.group(1), GoType()).methods.add(mm.group(2))
        for fm in FUNC_RE_GO.finditer(text):
            idx.funcs.add(fm.group(1))
    return idx


def upper_first(s: str) -> str:
    return s[:1].upper() + s[1:] if s else s


def _ci_member(names: set[str], key: str) -> str | None:
    """Case-insensitive lookup for acronym-heavy Go names (URLTestGroup etc.)."""
    lowered = key.lower()
    for name in sorted(names):
        if name.lower() == lowered:
            return name
    return None


def resolve_member(idx: GoIndex, cls: str, java_name: str) -> tuple[str, str]:
    """Map a Java member name to ("func"|"method"|"field", goName).

    gobind names: Go method `Foo` -> Java `foo`; Go field `Foo` -> Java
    `getFoo`/`setFoo`/`isFoo`. Prefer an exact method match on the uncapitalised
    form, then fall back to the field-accessor shape, then to a
    case-insensitive match (gobind folds leading acronyms, so `URLTestGroup`
    arrives as `urlTestGroup` and must still resolve to the real Go name).
    """
    cand = upper_first(java_name)
    if cand in idx.funcs:
        return ("func", cand)
    t = idx.types.get(cls)
    if t:
        if cand in t.methods:
            return ("method", cand)
        for pref in ("get", "set", "is"):
            if java_name.startswith(pref) and len(java_name) > len(pref) \
                    and java_name[len(pref)].isupper():
                rest = java_name[len(pref):]
                if rest in t.fields:
                    return ("field", rest)
                if upper_first(rest) in t.methods:
                    return ("method", upper_first(rest))
    # Only reached when the exact spelling is absent; keep the real Go casing.
    ci = _ci_member(idx.funcs, cand)
    if ci:
        return ("func", ci)
    if t:
        ci = _ci_member(t.methods, cand)
        if ci:
            return ("method", ci)
        for pref in ("get", "set", "is"):
            if java_name.startswith(pref) and len(java_name) > len(pref) \
                    and java_name[len(pref)].isupper():
                rest = java_name[len(pref):]
                ci = _ci_member(t.fields, rest)
                if ci:
                    return ("field", ci)
                ci = _ci_member(t.methods, upper_first(rest))
                if ci:
                    return ("method", ci)
    return ("method", cand)


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------


def classify(classes: dict[str, Cls]) -> dict:
    classes = {n: c for n, c in classes.items() if n not in {"Seq", "Universe", "error"}}
    interfaces = {n for n, c in classes.items() if c.kind == "interface"}

    java_to_go = []
    go_to_java = []
    ctors = []
    for c in classes.values():
        for m in c.methods:
            if c.kind == "interface":
                go_to_java.append({"class": c.name, **asdict(m)})
            elif m.is_ctor or m.name.startswith("__"):
                ctors.append({"class": c.name, **asdict(m)})
            else:
                java_to_go.append({"class": c.name, **asdict(m)})

    # Split the Go->Java pool by implementer: Go-implemented interfaces come back
    # as ordinary calls on handles; the rest leave through callbacks or ports.
    call_dir, callbacks, ports = [], [], []
    for m in go_to_java:
        if m["class"] in GO_IMPL_INTERFACES:
            call_dir.append(m)
        elif m["class"] in PORT_INTERFACES:
            ports.append(m)
        else:
            callbacks.append(m)

    return {
        "package": JAVA_PKG,
        "classes": len(classes),
        "interfaces": sorted(interfaces),
        "counts": {
            "java_to_go": len(java_to_go),
            "constructors": len(ctors),
            "go_impl_calls": len(call_dir),
            "jni_callbacks": len(callbacks),
            "port_events": len(ports),
        },
        "java_to_go": java_to_go,
        "constructors": ctors,
        "go_impl_calls": call_dir,
        "jni_callbacks": callbacks,
        "port_events": ports,
    }


# ---------------------------------------------------------------------------
# Type mapping
# ---------------------------------------------------------------------------

PRIM_C = {"int": "int32_t", "long": "int64_t", "boolean": "int8_t"}
PRIM_GO = {"int": "int32", "long": "int64", "boolean": "bool"}


def c_type_of(java: str) -> str:
    if java == "void":
        return "void"
    if java in PRIM_C:
        return PRIM_C[java]
    # cgo exports *C.char/*C.uint8_t as mutable pointers. `const` here would
    # conflict with the declarations in cgo's generated export header.
    if java == "String":
        return "char *"
    if java == "byte[]":
        return "uint8_t *"
    return "int64_t"  # handle


def go_type_of(java: str) -> str:
    if java == "void":
        return ""
    if java in PRIM_GO:
        return PRIM_GO[java]
    if java == "String":
        return "string"
    if java == "byte[]":
        return "[]byte"
    return "interface{}"  # stored in the handle table


def export_name(cls: str, java_name: str) -> str:
    safe = lambda s: re.sub(r"\W", "_", s)
    if java_name == "<init>":
        return f"throne_{safe(cls)}_new"
    return f"throne_{safe(cls)}_{safe(java_name)}"


class Signature:
    """A C ABI signature with the parameter adaptations applied."""

    def __init__(self, m: dict, classes: dict[str, Cls]):
        self.cls = m["class"]
        self.java_name = m["name"]
        self.is_ctor = m["name"] == "<init>"
        self.is_static = m.get("is_static", False)
        self.throws = m.get("throws", False)
        self.ret = m["returns"]
        self.symbol = export_name(self.cls, self.java_name)
        self.orig_params = list(m["params"])
        self.params: list[tuple[str, str, str]] = []  # (c type, name, java type)
        self.len_names: set[str] = set()  # synthesized byte[] length params
        self.dropped: list[str] = []
        for p in m["params"]:
            t, n = p["type"], p["name"]
            if t in DROP_PARAMS:
                self.dropped.append(t)
            elif t in PORT_PARAMS:
                self.params.append(("int64_t", n, t))
            elif t in JSON_PARAMS:
                self.params.append(("char *", n, t))
            elif t in JNI_PTR_PARAMS:
                self.params.append(("void *", n, t))
            elif t == "byte[]":
                self.params.append(("uint8_t *", n, t))
                self.params.append(("int32_t", n + "_len", "int"))
                self.len_names.add(n + "_len")
            else:
                self.params.append((c_type_of(t), n, t))

    def c_signature(self) -> str:
        ret = "int64_t" if self.is_ctor else (c_type_of(self.ret) or "void")
        params = []
        if not self.is_static and not self.is_ctor:
            params.append("int64_t handle")
        params += [f"{t} {n}" for t, n, _ in self.params]
        return f"{ret} {self.symbol}({', '.join(params) or 'void'})"


# ---------------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------------


def emit_symbols(surface: dict) -> str:
    L = [
        "/* Code generated by tools/bindgen/bindgen.py. DO NOT EDIT. */",
        "#ifndef THRONE_BRIDGE_SYMBOLS_H",
        "#define THRONE_BRIDGE_SYMBOLS_H",
        "",
        "#include <stdint.h>",
        "",
        "#ifdef __cplusplus",
        'extern "C" {',
        "#endif",
        "",
        "/* Go->platform callback table: filled by JNI_OnLoad (core.cpp) and passed to",
        " * throne_register_callbacks. The `tun` token is the TunInterface global ref",
        " * handed to throne_start_tun. Strings returned here are freed by the Go caller. */",
        "typedef struct {",
    ]
    for name, ret, params, doc in CALLBACKS:
        if doc:
            L.append(f"    /* {doc} */")
        L.append(f"    {ret} (*{name})({', '.join(f'{t} {n}' for t, n in params) or 'void'});")
    L += [
        "} throne_callbacks_t;",
        "",
        f"/* {surface['counts']['java_to_go']} java->go crossings, "
        f"{surface['counts']['constructors']} constructors, "
        f"{surface['counts']['go_impl_calls']} go-implemented interface calls */",
        "",
    ]
    for group in ("java_to_go", "constructors", "go_impl_calls"):
        L.append(f"/* --- {group} --- */")
        for m in surface[group]:
            L.append(Signature(m, {}).c_signature() + ";")
        L.append("")
    L.append("/* --- runtime --- */")
    for name, ret, params, doc in EXTRA_EXPORTS:
        if doc:
            L.append(f"/* {doc} */")
        L.append(f"{ret} {name}({', '.join(f'{t} {n}' for t, n in params) or 'void'});")
        L.append("")
    L += [
        "#ifdef __cplusplus",
        "}",
        "#endif",
        "#endif /* THRONE_BRIDGE_SYMBOLS_H */",
        "",
    ]
    return "\n".join(L)


def _go_arg(jt: str, name: str, classes: dict[str, Cls]) -> str:
    """One Go-side expression for a C parameter."""
    if jt == "String":
        return f"C.GoString({name})"
    if jt == "byte[]":
        return f"C.GoBytes(unsafe.Pointer({name}), C.int({name}_len))"
    if jt == "boolean":
        return f"{name} != 0"
    if jt == "int":
        return f"int32({name})"
    if jt == "long":
        return f"int64({name})"
    if jt in PORT_PARAMS:
        return {"URLTestHandler": "portURLTest", "IPTestHandler": "portIPTest",
                "SpeedTestHandler": "portSpeedTest"}[jt] + f"{{port: int64({name})}}"
    if jt in JSON_PARAMS:
        return f"newIterator(parseStringSlice(C.GoString({name})))"
    if jt in JNI_PTR_PARAMS:
        return f"jniFunc{{obj: {name}}}"
    if jt in DROP_PARAMS:
        # PlatformInterface / LogSink: supplied by the bridge runtime, not the caller.
        return {"PlatformInterface": "bridgePlatform", "LogSink": "portLogSink{}"}[jt]
    # Bound object: fetch from the handle table.
    # Object parameters arrive as C.int64_t; handleGet takes a Go int64.
    if jt in GO_IMPL_INTERFACES or jt in JNI_INTERFACES or jt in PORT_INTERFACES:
        return f"handleGet(int64({name})).({jt})"
    return f"handleGet(int64({name})).(*{jt})"


def _marshal(ret: str, expr: str) -> str:
    if ret == "String":
        return f"C.CString({expr})"
    if ret == "int":
        return f"C.int32_t({expr})"
    if ret == "long":
        return f"C.int64_t({expr})"
    if ret == "boolean":
        return f"cbool({expr})"
    return f"marshal_handle({expr})"


_ZERO = {"String": "nil", "int": "0", "long": "0", "boolean": "0", "void": ""}


def go_expr(idx: GoIndex, sig: Signature, classes: dict[str, Cls]) -> list[str]:
    """Body lines for one //export: unpack handles, call the Go member, marshal back."""
    cls = sig.cls
    is_iface_call = sig.java_name != "<init>" and cls in GO_IMPL_INTERFACES
    kind, go_name = ("ctor", "") if sig.is_ctor else resolve_member(idx, cls, sig.java_name)
    recv = ""
    if not sig.is_static and not sig.is_ctor:
        if is_iface_call:
            recv = f"handleGet(int64(handle)).({cls})"
        else:
            recv = f"handleGet(int64(handle)).(*{cls})"

    # Args follow the ORIGINAL parameter order so dropped parameters still occupy
    # their slot in the Go call (bridgePlatform / portLogSink fill it).
    args = []
    ai = 0
    for p in sig.orig_params:
        jt, n = p["type"], p["name"]
        if jt == "byte[]":
            args.append(_go_arg(jt, n, classes))
            ai += 2  # skip the synthesized len entry
        else:
            args.append(_go_arg(jt, n, classes))
            ai += 1
    argstr = ", ".join(args)

    if sig.is_ctor:
        call = f"&{cls}{{}}" if not sig.params and not sig.dropped else f"New{cls}({argstr})"
    elif kind == "func":
        call = f"{go_name}({argstr})"
    elif kind == "field":
        obj = recv
        if sig.java_name.startswith("set"):
            return [f"{obj}.{go_name} = {args[0]}"]
        return [f"return {_marshal(sig.ret, f'{obj}.{go_name}')}" ]
    else:
        call = f"{recv}.{go_name}({argstr})" if recv else f"{go_name}({argstr})"

    lines = []
    # NewInstance returns (T, error) even where the Java constructor omits `throws`;
    # the running box is tracked so throne_suspend can reach it.
    is_instance_new = (not sig.is_ctor and kind == "func" and go_name == "NewInstance") or \
                      (sig.is_ctor and cls == "Instance")
    if is_instance_new:
        lines.append(f"v, err := {call}")
        lines.append("if err != nil { setErr(err); return 0 }")
        lines.append("registerInstance(v)")
        lines.append("return marshal_handle(v)")
        return lines
    if sig.is_ctor:
        # Constructors have a C.int64_t handle return even though their Java
        # constructor entry has `returns=void`; marshal the new object explicitly.
        return [f"return marshal_handle({call})"]
    if sig.throws:
        if sig.ret == "void":
            lines.append(f"if err := {call}; err != nil {{ setErr(err) }}")
        else:
            zero = _ZERO.get(sig.ret, "0")
            ret_stmt = "return " + zero if zero else "return"
            lines.append(f"v, err := {call}")
            lines.append(f"if err != nil {{ setErr(err); {ret_stmt} }}")
            lines.append(f"return {_marshal(sig.ret, 'v')}")
    else:
        if sig.ret == "void":
            lines.append(call)
        else:
            lines.append(f"return {_marshal(sig.ret, call)}")
    return lines


def _c_ret_type(ret: str, is_ctor: bool) -> str:
    if is_ctor:
        return "C.int64_t"
    return {"void": "", "String": "*C.char", "int": "C.int32_t",
            "long": "C.int64_t", "boolean": "C.int8_t"}.get(ret, "C.int64_t")


def emit_go(surface: dict, idx: GoIndex, classes: dict[str, Cls]) -> str:
    L = [
        "// Code generated by tools/bindgen/bindgen.py. DO NOT EDIT.",
        "//",
        "// The Go half of the self-owned binding layer: one //export per C ABI symbol",
        "// in bridge_symbols.h. Lives in package mobile (patched into the core tree) so",
        "// the symbols land in the shared library gomobile builds.",
        "package mobile",
        "",
        "/*",
        '#include "bridge_symbols.h"',
        "#include <stdlib.h>",
        "*/",
        'import "C"',
        "",
        "import (",
        '\t"reflect"',
        '\t"sync"',
        '\t"unsafe"',
        ")",
        "",
        "// --- handle table (replaces go.Seq refnums) ---",
        "",
        "var (",
        "\thandlesMu sync.Mutex",
        "\tnextHandle int64 = 1",
        "\thandles   = map[int64]interface{}{}",
        ")",
        "",
        "func handleNew(v interface{}) int64 {",
        "\thandlesMu.Lock()",
        "\tdefer handlesMu.Unlock()",
        "\th := nextHandle",
        "\tnextHandle++",
        "\thandles[h] = v",
        "\treturn h",
        "}",
        "",
        "func handleGet(h int64) interface{} {",
        "\thandlesMu.Lock()",
        "\tdefer handlesMu.Unlock()",
        "\treturn handles[h]",
        "}",
        "",
        "//export throne_handle_release",
        "func throne_handle_release(h C.int64_t) {",
        "\thandlesMu.Lock()",
        "\tdefer handlesMu.Unlock()",
        "\tdelete(handles, int64(h))",
        "}",
        "",
        "//export throne_free",
        "func throne_free(p *C.char) { C.free(unsafe.Pointer(p)) }",
        "",
        "// --- error channel (the Java `throws` surface) ---",
        "",
        "var (",
        "\terrMu     sync.Mutex",
        "\tlastError string",
        ")",
        "",
        "func setErr(err error) {",
        "\terrMu.Lock()",
        "\tlastError = err.Error()",
        "\terrMu.Unlock()",
        "}",
        "",
        "//export throne_last_error",
        "func throne_last_error() *C.char {",
        "\terrMu.Lock()",
        "\tdefer errMu.Unlock()",
        "\treturn C.CString(lastError)",
        "}",
        "",
        "// --- marshalling helpers ---",
        "",
        "func cbool(v bool) C.int8_t {",
        "\tif v { return 1 }",
        "\treturn 0",
        "}",
        "",
        "// marshal_handle stores any bound value; typed nil pointers become handle 0.",
        "func marshal_handle(v interface{}) C.int64_t {",
        "\tif v == nil { return 0 }",
        "\trv := reflect.ValueOf(v)",
        "\tswitch rv.Kind() {",
        "\tcase reflect.Ptr, reflect.Interface, reflect.Map, reflect.Slice:",
        "\t\tif rv.IsNil() { return 0 }",
        "\t}",
        "\treturn C.int64_t(handleNew(v))",
        "}",
        "",
        "func parseStringSlice(s string) []string {",
        "\tvar out []string",
        "\tfor _, part := range splitJSONStrings(s) {",
        "\t\tout = append(out, part)",
        "\t}",
        "\treturn out",
        "}",
        "",
        "// --- crossings ---",
        "",
    ]

    for group in ("java_to_go", "constructors", "go_impl_calls"):
        for m in surface[group]:
            sig = Signature(m, classes)
            ret = _c_ret_type(sig.ret, sig.is_ctor)
            go_params = []
            if not sig.is_static and not sig.is_ctor:
                go_params.append("handle C.int64_t")
            for t, n, jt in sig.params:
                if n in sig.len_names:
                    go_params.append(f"{n} C.int32_t")
                elif jt == "String" or jt in JSON_PARAMS:
                    go_params.append(f"{n} *C.char")
                elif jt == "byte[]":
                    go_params.append(f"{n} *C.uint8_t")
                elif jt == "boolean":
                    go_params.append(f"{n} C.int8_t")
                elif jt == "int":
                    go_params.append(f"{n} C.int32_t")
                elif jt == "long":
                    go_params.append(f"{n} C.int64_t")
                elif jt in PORT_PARAMS:
                    go_params.append(f"{n} C.int64_t")
                elif jt in JNI_PTR_PARAMS:
                    go_params.append(f"{n} unsafe.Pointer")
                else:
                    go_params.append(f"{n} C.int64_t")
            L.append(f"//export {sig.symbol}")
            L.append(f"func {sig.symbol}({', '.join(go_params) or ''}) {ret} {{")
            body = go_expr(idx, sig, classes)
            L.extend("\t" + line for line in body)
            L.append("}")
            L.append("")
    return "\n".join(L) + "\n"


def emit_go_runtime() -> str:
    """Static support file: callbacks, port events, bridgePlatform, tun plumbing.

    Follows bettbox's android_bride.go shape: the callback table lives in C
    (filled by JNI_OnLoad through throne_register_callbacks) and Go calls it
    through small C wrappers, because cgo cannot call function-pointer fields.
    Object graphs cross as JSON so the table stays primitive/string-shaped.
    """
    c_wrappers = []
    for name, ret, params, _doc in CALLBACKS:
        plist = ", ".join(f"{t} {n}" for t, n in params)
        arglist = ", ".join(n for _, n in params)
        guard = f"g_has && g_callbacks.{name}"
        if ret == "void":
            fallback = ""
        elif ret in ("int8_t", "int32_t", "int64_t"):
            fallback = " return 0;"
        else:
            fallback = " return NULL;"
        c_wrappers.append(
            f"static {ret} call_{name}({plist}) {{"
            f" if ({guard}) return g_callbacks.{name}({arglist});{fallback} }}")

    def cparam(t, n):
        return {"void *": f"{n} unsafe.Pointer", "const char *": f"{n} *C.char",
                "const uint8_t *": f"{n} *C.uint8_t", "int32_t": f"{n} C.int32_t",
                "int64_t": f"{n} C.int64_t", "int8_t": f"{n} C.int8_t"}.get(t, f"{n} C.int64_t")

    def cgo_str(n):
        """Go string -> C string, plus the free line."""
        return (f"{n}C := C.CString({n})\n\tdefer C.free(unsafe.Pointer({n}C))",
                f"{n}C")

    return f"""// Code generated by tools/bindgen/bindgen.py. DO NOT EDIT.
//
// Runtime support for bridge_calls.go: the callback table the JNI shim fills,
// the Dart message port, port-backed event handlers, and bridgePlatform — the
// PlatformInterface implementation that routes Go->platform calls through
// throne_callbacks_t. Part of the core patch (package mobile).
package mobile

/*
#include "bridge_symbols.h"
#include <stdlib.h>
#include <string.h>

static throne_callbacks_t g_callbacks;
static int8_t g_has;

{chr(10).join(c_wrappers)}

void bridge_set_callbacks(const throne_callbacks_t *t) {{
    if (t) {{ g_callbacks = *t; g_has = 1; }}
}}
*/
import "C"

import (
\t"encoding/json"
\t"errors"
\t"sync"
\t"unsafe"
)

// --- callback table plumbing -----------------------------------------------

var (
\tbridgeMu    sync.Mutex
\tbridgeFd    int32
\tbridgeTunI  unsafe.Pointer
\tmessagePort int64 = -1
)

var (
\terrNoTunFd  = errors.New("bridge: no tun fd fed (call throne_start_tun first)")
\terrCallback = errors.New("bridge: platform callback failed")
)

//export throne_register_callbacks
func throne_register_callbacks(table *C.throne_callbacks_t) {{ C.bridge_set_callbacks(table) }}

//export throne_start_tun
func throne_start_tun(fd C.int32_t, tun unsafe.Pointer) C.int32_t {{
\tbridgeMu.Lock()
\tdefer bridgeMu.Unlock()
\tbridgeFd = int32(fd)
\tbridgeTunI = tun
\treturn 0
}}

//export throne_stop_tun
func throne_stop_tun() {{
\tbridgeMu.Lock()
\ttun := bridgeTunI
\tbridgeFd = 0
\tbridgeTunI = nil
\tbridgeMu.Unlock()
\tif tun != nil {{
\t\tC.call_release_object(tun)
\t}}
}}

//export throne_suspend
func throne_suspend(suspended C.int32_t) {{
\tlastInstance.mu.Lock()
\tinst := lastInstance.inst
\tlastInstance.mu.Unlock()
\tif inst == nil {{
\t\treturn
\t}}
\tif suspended != 0 {{
\t\tinst.Pause()
\t}} else {{
\t\tinst.Wake()
\t}}
}}

func bridgeTun() unsafe.Pointer {{
\tbridgeMu.Lock()
\tdefer bridgeMu.Unlock()
\treturn bridgeTunI
}}

// --- Dart message port ------------------------------------------------------

//export throne_init_dart_api
func throne_init_dart_api(api unsafe.Pointer) {{ initDartApi(api) }}

//export throne_attach_message_port
func throne_attach_message_port(port C.int64_t) {{
\tbridgeMu.Lock()
\tmessagePort = int64(port)
\tbridgeMu.Unlock()
}}

// sendEvent posts one JSON event to the attached message port (logs, ...).
func sendEvent(method string, data interface{{}}) {{
\tbridgeMu.Lock()
\tport := messagePort
\tbridgeMu.Unlock()
\tif port < 0 {{
\t\treturn
\t}}
\tmsg, _ := json.Marshal(map[string]interface{{}}{{"method": method, "data": data}})
\tsendToPort(port, string(msg))
}}

func postTo(port int64, method string, data interface{{}}) {{
\tif port < 0 {{
\t\treturn
\t}}
\tmsg, _ := json.Marshal(map[string]interface{{}}{{"method": method, "data": data}})
\tsendToPort(port, string(msg))
}}

// --- port-backed event handlers (LogSink + the three test handlers) ---------

type portLogSink struct{{}}

func (portLogSink) Write(level int32, message string) {{
\tsendEvent("log", map[string]interface{{}}{{"level": level, "message": message}})
}}

type portURLTest struct{{ port int64 }}

func (p portURLTest) OnResult(tag string, latencyMs int32, err string) {{
\tpostTo(p.port, "urlTestResult", map[string]interface{{}}{{"tag": tag, "latencyMs": latencyMs, "err": err}})
}}
func (p portURLTest) OnVPNStatus(tag string, connected bool, state string, err string) {{
\tpostTo(p.port, "urlTestVpnStatus", map[string]interface{{}}{{"tag": tag, "connected": connected, "state": state, "err": err}})
}}
func (p portURLTest) OnDone() {{ postTo(p.port, "urlTestDone", nil) }}

type portIPTest struct{{ port int64 }}

func (p portIPTest) OnResult(tag string, ip string, countryCode string, err string) {{
\tpostTo(p.port, "ipTestResult", map[string]interface{{}}{{"tag": tag, "ip": ip, "countryCode": countryCode, "err": err}})
}}
func (p portIPTest) OnDone() {{ postTo(p.port, "ipTestDone", nil) }}

type portSpeedTest struct{{ port int64 }}

func (p portSpeedTest) OnResult(result *SpeedTestResult) {{
\tpostTo(p.port, "speedTestResult", result)
}}
func (p portSpeedTest) OnDone() {{ postTo(p.port, "speedTestDone", nil) }}

// jniFunc adapts a Java-side Func token for ExchangeContext.OnCancel.
type jniFunc struct{{ obj unsafe.Pointer }}

func (f jniFunc) Invoke() error {{
\tC.call_func_invoke(f.obj)
\treturn nil
}}

// --- bridgePlatform ---------------------------------------------------------

// bridgePlatform is the single PlatformInterface implementation: everything the
// kernel asks of the platform crosses throne_callbacks_t into the JNI shim.
type bridgePlatformImpl struct{{}}

var bridgePlatform PlatformInterface = bridgePlatformImpl{{}}

// OpenTun feeds the core the tun fd. When throne_start_tun already pushed one
// (VpnService established before the start) it is returned as is; otherwise the
// open_tun callback establishes the VPN now — the shim builds VpnService.Builder
// from the TunOptions handle and feeds the fd back through throne_start_tun.
func (bridgePlatformImpl) OpenTun(options TunOptions) (int32, error) {{
\tbridgeMu.Lock()
\tfd := bridgeFd
\tbridgeMu.Unlock()
\tif fd > 0 {{
\t\treturn fd, nil
\t}}
\th := handleNew(options)
\tdefer handleRelease(h)
\tfd = int32(C.call_open_tun(C.int64_t(h)))
\tif fd < 0 {{
\t\treturn 0, errCallback
\t}}
\tbridgeMu.Lock()
\tbridgeFd = fd
\tbridgeMu.Unlock()
\treturn fd, nil
}}

func (bridgePlatformImpl) LocalDNSTransport() LocalDNSTransport        {{ return bridgeDNS{{}} }}
func (bridgePlatformImpl) UsePlatformAutoDetectInterfaceControl() bool {{ return C.call_use_platform_auto_detect_interface_control(bridgeTun()) != 0 }}
func (bridgePlatformImpl) UseProcFS() bool                            {{ return C.call_use_proc_fs(bridgeTun()) != 0 }}
func (bridgePlatformImpl) ClearDNSCache()                             {{ C.call_clear_dns_cache(bridgeTun()) }}

func (bridgePlatformImpl) AutoDetectInterfaceControl(fd int32) error {{
\treturn strErr(goStr(C.call_auto_detect_interface_control(bridgeTun(), C.int32_t(fd))))
}}

func (bridgePlatformImpl) FindConnectionOwner(ipProtocol int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (*ConnectionOwner, error) {{
\tsa := C.CString(sourceAddress)
\tdefer C.free(unsafe.Pointer(sa))
\tda := C.CString(destinationAddress)
\tdefer C.free(unsafe.Pointer(da))
\tjs := goStr(C.call_find_connection_owner(bridgeTun(), C.int32_t(ipProtocol), sa, C.int32_t(sourcePort), da, C.int32_t(destinationPort)))
\tif js == "" {{
\t\treturn nil, errCallback
\t}}
\treturn parseConnectionOwner(js)
}}

func (bridgePlatformImpl) PackageNamesByUid(uid int32) (StringIterator, error) {{
\tjs := goStr(C.call_package_names_by_uid(bridgeTun(), C.int32_t(uid)))
\treturn newIterator(parseStringSlice(js)), nil
}}

func (bridgePlatformImpl) StartDefaultInterfaceMonitor(listener InterfaceUpdateListener) error {{
\treturn strErr(goStr(C.call_start_default_interface_monitor(bridgeTun(), C.int64_t(handleNew(listener)))))
}}

func (bridgePlatformImpl) CloseDefaultInterfaceMonitor(listener InterfaceUpdateListener) error {{
\treturn strErr(goStr(C.call_close_default_interface_monitor(bridgeTun(), C.int64_t(handleNew(listener)))))
}}

func (bridgePlatformImpl) GetInterfaces() (NetworkInterfaceIterator, error) {{
\tjs := goStr(C.call_get_interfaces(bridgeTun()))
\treturn parseNetworkInterfaces(js), nil
}}

func (bridgePlatformImpl) ReadWIFIState() *WIFIState {{
\tjs := goStr(C.call_read_wifi_state(bridgeTun()))
\tif js == "" {{
\t\treturn nil
\t}}
\treturn parseWIFIState(js)
}}

func (bridgePlatformImpl) SendNotification(notification *Notification) error {{
\tjs := C.CString(mustJSON(notification))
\tdefer C.free(unsafe.Pointer(js))
\treturn strErr(goStr(C.call_send_notification(bridgeTun(), js)))
}}

func (bridgePlatformImpl) CancelNotification(identifier string, typeID int32) error {{
\tid := C.CString(identifier)
\tdefer C.free(unsafe.Pointer(id))
\treturn strErr(goStr(C.call_cancel_notification(bridgeTun(), id, C.int32_t(typeID))))
}}

// bridgeDNS adapts LocalDNSTransport to the same callback table.
type bridgeDNS struct{{}}

func (bridgeDNS) Raw() bool {{ return C.call_local_dns_raw(bridgeTun()) != 0 }}

func (bridgeDNS) Lookup(ctx *ExchangeContext, network string, domain string) error {{
\th := handleNew(ctx)
\tdefer handleRelease(h)
\tn := C.CString(network)
\tdefer C.free(unsafe.Pointer(n))
\td := C.CString(domain)
\tdefer C.free(unsafe.Pointer(d))
\treturn strErr(goStr(C.call_local_dns_lookup(bridgeTun(), C.int64_t(h), n, d)))
}}

func (bridgeDNS) Exchange(ctx *ExchangeContext, message []byte) error {{
\th := handleNew(ctx)
\tdefer handleRelease(h)
\tvar msg unsafe.Pointer
\tif len(message) > 0 {{
\t\tmsg = C.CBytes(message)
\t\tdefer C.free(msg)
\t}}
\treturn strErr(goStr(C.call_local_dns_exchange(bridgeTun(), C.int64_t(h), (*C.uint8_t)(msg), C.int32_t(len(message)))))
}}

// --- small adapters ---------------------------------------------------------

// goStr converts a callback-owned C string to Go and frees it.
func goStr(p *C.char) string {{
\tif p == nil {{
\t\treturn ""
\t}}
\ts := C.GoString(p)
\tC.free(unsafe.Pointer(p))
\treturn s
}}

func strErr(s string) error {{
\tif s == "" {{
\t\treturn nil
\t}}
\treturn errors.New(s)
}}

func mustJSON(v interface{{}}) string {{
\tb, _ := json.Marshal(v)
\treturn string(b)
}}

// splitJSONStrings decodes a JSON string array.
func splitJSONStrings(s string) []string {{
\tvar out []string
\tif json.Unmarshal([]byte(s), &out) != nil {{
\t\treturn nil
\t}}
\treturn out
}}

// parseConnectionOwner / parseWIFIState / parseNetworkInterfaces decode the JSON
// the JNI shim returns for object-shaped callbacks.
func parseConnectionOwner(js string) (*ConnectionOwner, error) {{
\tvar dto struct {{
\t\tUserId       int32    `json:"userId"`
\t\tUserName     string   `json:"userName"`
\t\tProcessPath  string   `json:"processPath"`
\t\tPackageNames []string `json:"packageNames"`
\t}}
\tif err := json.Unmarshal([]byte(js), &dto); err != nil {{
\t\treturn nil, err
\t}}
\tc := &ConnectionOwner{{UserId: dto.UserId, UserName: dto.UserName, ProcessPath: dto.ProcessPath}}
\tc.SetAndroidPackageNames(newIterator(dto.PackageNames))
\treturn c, nil
}}

func parseWIFIState(js string) *WIFIState {{
\tvar dto struct {{
\t\tSSID  string `json:"ssid"`
\t\tBSSID string `json:"bssid"`
\t}}
\tif json.Unmarshal([]byte(js), &dto) != nil {{
\t\treturn nil
\t}}
\treturn NewWIFIState(dto.SSID, dto.BSSID)
}}

func parseNetworkInterfaces(js string) NetworkInterfaceIterator {{
\tvar dtos []struct {{
\t\tIndex     int32    `json:"index"`
\t\tMTU       int32    `json:"mtu"`
\t\tName      string   `json:"name"`
\t\tAddresses []string `json:"addresses"`
\t\tFlags     int32    `json:"flags"`
\t\tType      int32    `json:"type"`
\t\tDNSServer []string `json:"dnsServer"`
\t\tGateway   []string `json:"gateway"`
\t\tMetered   bool     `json:"metered"`
\t}}
\tif json.Unmarshal([]byte(js), &dtos) != nil {{
\t\treturn newIterator([]*NetworkInterface(nil))
\t}}
\tout := make([]*NetworkInterface, 0, len(dtos))
\tfor _, d := range dtos {{
\t\tout = append(out, &NetworkInterface{{
\t\t\tIndex: d.Index, MTU: d.MTU, Name: d.Name, Flags: d.Flags,
\t\t\tType: d.Type, Metered: d.Metered,
\t\t\tAddresses: newIterator(d.Addresses),
\t\t\tDNSServer: newIterator(d.DNSServer),
\t\t\tGateway:   newIterator(d.Gateway),
\t\t}})
\t}}
\treturn newIterator(out)
}}

// lastInstance lets throne_suspend reach the running box.
var lastInstance struct {{
\tmu   sync.Mutex
\tinst *Instance
}}

// registerInstance is called from the generated Instance constructor.
func registerInstance(i *Instance) {{
\tlastInstance.mu.Lock()
\tlastInstance.inst = i
\tlastInstance.mu.Unlock()
}}

// --- tun options for VpnService.Builder ------------------------------------

//export throne_getAndroidVpnOptions
func throne_getAndroidVpnOptions(coreConfig *C.char) *C.char {{
\tvar raw map[string]interface{{}}
\tif json.Unmarshal([]byte(C.GoString(coreConfig)), &raw) != nil {{
\t\treturn C.CString("{{}}")
\t}}
\tinbounds, _ := raw["inbounds"].([]interface{{}})
\tfor _, ib := range inbounds {{
\t\tm, _ := ib.(map[string]interface{{}})
\t\tif m != nil && m["type"] == "tun" {{
\t\t\tb, _ := json.Marshal(m)
\t\t\treturn C.CString(string(b))
\t\t}}
\t}}
\treturn C.CString("{{}}")
}}

// handleRelease drops a temp handle created for a callback crossing.
func handleRelease(h int64) {{
\thandlesMu.Lock()
\tdefer handlesMu.Unlock()
\tdelete(handles, h)
}}

//export throne_TunOptions_toJSON
func throne_TunOptions_toJSON(handle C.int64_t) *C.char {{
\to, _ := handleGet(int64(handle)).(TunOptions)
\tif o == nil {{
\t\treturn C.CString("")
\t}}
\tprefixes := func(it RoutePrefixIterator) []map[string]interface{{}} {{
\t\tout := make([]map[string]interface{{}}, 0, 4)
\t\tfor it != nil && it.HasNext() {{
\t\t\tp := it.Next()
\t\t\tout = append(out, map[string]interface{{}}{{"address": p.Address(), "prefix": p.Prefix()}})
\t\t}}
\t\treturn out
\t}}
\tstringsOf := func(it StringIterator) []string {{
\t\tout := make([]string, 0, 4)
\t\tfor it != nil && it.HasNext() {{
\t\t\tout = append(out, it.Next())
\t\t}}
\t\treturn out
\t}}
\tdto := map[string]interface{{}}{{}}
\tdto["mtu"] = o.GetMTU()
\tdto["autoRoute"] = o.GetAutoRoute()
\tdto["strictRoute"] = o.GetStrictRoute()
\tdto["inet4Address"] = prefixes(o.GetInet4Address())
\tdto["inet6Address"] = prefixes(o.GetInet6Address())
\tdto["inet4RouteAddress"] = prefixes(o.GetInet4RouteAddress())
\tdto["inet6RouteAddress"] = prefixes(o.GetInet6RouteAddress())
\tdto["inet4RouteExcludeAddress"] = prefixes(o.GetInet4RouteExcludeAddress())
\tdto["inet6RouteExcludeAddress"] = prefixes(o.GetInet6RouteExcludeAddress())
\tdto["inet4RouteRange"] = prefixes(o.GetInet4RouteRange())
\tdto["inet6RouteRange"] = prefixes(o.GetInet6RouteRange())
\tdto["includePackage"] = stringsOf(o.GetIncludePackage())
\tdto["excludePackage"] = stringsOf(o.GetExcludePackage())
\tdto["httpProxyEnabled"] = o.IsHTTPProxyEnabled()
\tdto["httpProxyServer"] = o.GetHTTPProxyServer()
\tdto["httpProxyServerPort"] = o.GetHTTPProxyServerPort()
\tdto["httpProxyBypassDomain"] = stringsOf(o.GetHTTPProxyBypassDomain())
\tif mode := o.GetDNSMode(); mode != nil {{
\t\tdto["dnsMode"] = mode.Value
\t}}
\tif dns, err := o.GetDNSServerAddress(); err == nil {{
\t\tdto["dnsServerAddress"] = stringsOf(dns)
\t}}
\tb, _ := json.Marshal(dto)
\treturn C.CString(string(b))
}}

var _ = unsafe.Pointer(nil)
"""


# ---- Dart --------------------------------------------------------------

DART_C = {
    "void": "void", "int": "int", "long": "int", "boolean": "int",
    "String": "Pointer<Utf8>", "byte[]": "Pointer<Uint8>", None: "int",
}
DART_D = {"void": "void", "int": "int", "long": "int", "boolean": "bool",
          "String": "String", "byte[]": "List<int>"}


def dart_ffi_type(java: str) -> str:
    return {"void": "Void", "int": "Int32", "long": "Int64", "boolean": "Int8",
            "String": "Pointer<Utf8>", "byte[]": "Pointer<Uint8>"}.get(java, "Int64")


def emit_dart(surface: dict) -> str:
    L = [
        "// Code generated by tools/bindgen/bindgen.py. DO NOT EDIT.",
        "// ignore_for_file: non_constant_identifier_names, no_leading_underscores_for_local_identifiers, unused_field",
        "//",
        "// Dart FFI bindings for the throne_* C ABI (see bridge_symbols.h): a raw",
        "// lookup layer plus typed handle wrappers. The box_api facade calls the",
        "// wrappers instead of the kernel method channel.",
        "",
        "import 'dart:convert';",
        "import 'dart:ffi';",
        "import 'dart:typed_data';",
        "",
        "import 'package:ffi/ffi.dart';",
        "",
    ]
    # Raw lookups
    L.append("class ThroneFFI {")
    L.append("  final Pointer<T> Function<T extends NativeType>(String) _lookup;")
    L.append("  ThroneFFI(DynamicLibrary lib) : _lookup = lib.lookup;")
    L.append("")

    def raw_sig(name, ret, params):
        def c_map(t):
            return {"void *": "Pointer<Void>", "int32_t": "Int32", "int64_t": "Int64",
                    "int8_t": "Int8", "char *": "Pointer<Utf8>",
                    "uint8_t *": "Pointer<Uint8>",
                    "const char *": "Pointer<Utf8>", "const uint8_t *": "Pointer<Uint8>",
                    "void": "Void", "int": "Int32",
                    "throne_callbacks_t *": "Pointer<Void>",
                    "const throne_callbacks_t *": "Pointer<Void>"}.get(t, "Int64")

        def d_map(t):
            return {"void *": "Pointer<Void>", "int32_t": "int", "int64_t": "int",
                    "int8_t": "int", "char *": "Pointer<Utf8>",
                    "uint8_t *": "Pointer<Uint8>",
                    "const char *": "Pointer<Utf8>", "const uint8_t *": "Pointer<Uint8>",
                    "void": "void", "int": "int",
                    "throne_callbacks_t *": "Pointer<Void>",
                    "const throne_callbacks_t *": "Pointer<Void>"}.get(t, "int")
        nat = f"{c_map(ret)} Function({', '.join(c_map(t) for t, _ in params)})"
        det = f"{d_map(ret)} Function({', '.join(d_map(t) + ' ' + n for t, n in params)})"
        call = ", ".join(n for _, n in params)
        L.append(f"  late final _{name} =")
        L.append(f"      _lookup<NativeFunction<{nat}>>('{name}').asFunction<{det}>();")
        L.append(f"  {d_map(ret)} {name}({', '.join(d_map(t) + ' ' + n for t, n in params)}) =>")
        L.append(f"      _{name}({call});")
        L.append("")

    for group in ("java_to_go", "constructors", "go_impl_calls"):
        for m in surface[group]:
            sig = Signature(m, {})
            ret = "int64_t" if sig.is_ctor else c_type_of(sig.ret)
            params = []
            if not sig.is_static and not sig.is_ctor:
                params.append(("int64_t", "handle"))
            params += [(t, n) for t, n, _ in sig.params]
            raw_sig(sig.symbol, ret, params)
    for name, ret, params, _ in EXTRA_EXPORTS:
        raw_sig(name, ret, params)
    L.append("}")
    L.append("")

    # Helpers
    L += [
        "String _cstr(Pointer<Utf8> p, ThroneFFI ffi) {",
        "  if (p == nullptr) return '';",
        "  final s = p.toDartString();",
        "  ffi.throne_free(p);",
        "  return s;",
        "}",
        "",
        "void _checkErr(ThroneFFI ffi) {",
        "  final p = ffi.throne_last_error();",
        "  if (p == nullptr) return;",
        "  final msg = p.toDartString();",
        "  ffi.throne_free(p);",
        "  if (msg.isNotEmpty) throw StateError(msg);",
        "}",
        "",
        "extension _BytesMalloc on Uint8List {",
        "  Pointer<Uint8> mallocUint8() {",
        "    final p = malloc<Uint8>(length);",
        "    p.asTypedList(length).setAll(0, this);",
        "    return p;",
        "  }",
        "}",
        "",
    ]

    # Typed wrappers
    classes_seen: dict[str, list[dict]] = {}
    for group in ("java_to_go", "constructors", "go_impl_calls"):
        for m in surface[group]:
            classes_seen.setdefault(m["class"], []).append(m)

    def dart_type(java: str) -> str:
        t = {"void": "void", "String": "String", "int": "int", "long": "int",
             "boolean": "bool", "byte[]": "Uint8List"}.get(java)
        return t if t else f"Throne{java}?"

    for cls, methods in sorted(classes_seen.items()):
        L.append(f"class Throne{cls} {{")
        L.append("  final ThroneFFI _ffi;")
        L.append("  final int handle;")
        L.append(f"  Throne{cls}(this._ffi, this.handle);")
        L.append("")
        # constructors as factories
        for m in methods:
            sig = Signature(m, {})
            if not sig.is_ctor:
                continue
            fp = []
            fa = []
            for p in sig.orig_params:
                jt, n = p["type"], p["name"]
                if jt in DROP_PARAMS:
                    continue
                if jt == "String" or jt in JSON_PARAMS:
                    fp.append(f"String {n}")
                    fa.append(f"{n}.toNativeUtf8()")
                elif jt == "boolean":
                    fp.append(f"bool {n}")
                    fa.append(f"{n} ? 1 : 0")
                elif jt == "byte[]":
                    fp.append(f"Uint8List {n}")
                    fa.append(f"{n}.mallocUint8()")
                    fa.append(f"{n}.length")
                elif jt in PORT_PARAMS:
                    fp.append(f"int {n}")
                    fa.append(n)
                elif jt in JNI_PTR_PARAMS:
                    fp.append(f"Pointer<Void> {n}")
                    fa.append(n)
                else:
                    fp.append(f"int {n}")
                    fa.append(n)
            L.append(f"  static Throne{cls} create(ThroneFFI _ffi, {', '.join(fp)}) {{")
            pre, post = [], []
            for p in sig.orig_params:
                jt, n = p["type"], p["name"]
                if jt == "String" or jt in JSON_PARAMS:
                    pre.append(f"final _a_{n} = {n}.toNativeUtf8();")
                    post.append(f"malloc.free(_a_{n});")
                    fa = [f"_a_{n}" if x == f"{n}.toNativeUtf8()" else x for x in fa]
                elif jt == "byte[]":
                    pre.append(f"final _a_{n} = {n}.mallocUint8();")
                    post.append(f"malloc.free(_a_{n});")
                    fa = [f"_a_{n}" if x == f"{n}.mallocUint8()" else x for x in fa]
            L.extend("    " + line for line in pre)
            wrap_try = bool(post)
            if wrap_try:
                L.append("    try {")
            ind = "      " if wrap_try else "    "
            L.append(f"{ind}final h = _ffi.{sig.symbol}({', '.join(fa)});")
            if sig.throws:
                L.append(f"{ind}_checkErr(_ffi);")
            L.append(f"{ind}return Throne{cls}(_ffi, h);")
            if wrap_try:
                L.append("    } finally {")
                L.extend("      " + line for line in post)
                L.append("    }")
            L.append("  }")
            L.append("")
        for m in methods:
            sig = Signature(m, {})
            if sig.is_ctor:
                continue
            name = sig.java_name
            fp, pre, post, fa = [], [], [], []
            if not sig.is_static:
                fa.append("handle")
            for p in sig.orig_params:
                jt, n = p["type"], p["name"]
                if jt in DROP_PARAMS:
                    continue
                if jt == "String" or jt in JSON_PARAMS:
                    fp.append(f"String {n}")
                    pre.append(f"final _a_{n} = {n}.toNativeUtf8();")
                    post.append(f"malloc.free(_a_{n});")
                    fa.append(f"_a_{n}")
                elif jt == "boolean":
                    fp.append(f"bool {n}")
                    fa.append(f"{n} ? 1 : 0")
                elif jt == "byte[]":
                    fp.append(f"Uint8List {n}")
                    pre.append(f"final _a_{n} = {n}.mallocUint8();")
                    post.append(f"malloc.free(_a_{n});")
                    fa.append(f"_a_{n}")
                    fa.append(f"{n}.length")
                elif jt in PORT_PARAMS:
                    fp.append(f"int {n}")
                    fa.append(n)
                elif jt in JNI_PTR_PARAMS:
                    fp.append(f"Pointer<Void> {n}")
                    fa.append(n)
                else:
                    fp.append(f"int {n}")
                    fa.append(n)
            ret = dart_type(sig.ret)
            static = "static " if sig.is_static else ""
            recv = "_ffi" if sig.is_static else "_ffi"
            if sig.is_static:
                L.append(f"  static {ret} {name}(ThroneFFI _ffi, {', '.join(fp)}) {{")
            else:
                L.append(f"  {ret} {name}({', '.join(fp)}) {{")
            L.extend("    " + line for line in pre)
            wrap_try = bool(post)
            if wrap_try:
                L.append("    try {")
            ind = "      " if wrap_try else "    "
            call = f"_ffi.{sig.symbol}({', '.join(fa)})"
            if sig.ret == "String":
                L.append(f"{ind}final r = _cstr({call}, _ffi);")
            elif sig.ret == "void":
                L.append(f"{ind}{call};")
            else:
                L.append(f"{ind}final r = {call};")
            if sig.throws:
                L.append(f"{ind}_checkErr(_ffi);")
            if sig.ret == "String":
                L.append(f"{ind}return r;")
            elif sig.ret == "void":
                pass
            elif sig.ret in ("int", "long"):
                L.append(f"{ind}return r;")
            elif sig.ret == "boolean":
                L.append(f"{ind}return r != 0;")
            else:
                L.append(f"{ind}return r == 0 ? null : Throne{sig.ret}(_ffi, r);")
            if wrap_try:
                L.append("    } finally {")
                L.extend("      " + line for line in post)
                L.append("    }")
            else:
                L.extend("    " + line for line in post)
            L.append("  }")
            L.append("")
        L.append("}")
        L.append("")

    # Event stream helper for the message port (used by the kernel runtime).
    L += [
        "// Parse one JSON event posted by the Go side (sendEvent/postTo).",
        "Map<String, dynamic>? decodeBridgeEvent(Object? raw) {",
        "  if (raw is! String) return null;",
        "  try {",
        "    final v = json.decode(raw);",
        "    return v is Map<String, dynamic> ? v : null;",
        "  } catch (_) {",
        "    return null;",
        "  }",
        "}",
        "",
    ]
    return "\n".join(L) + "\n"


def emit_dartbridge() -> str:
    """The Dart_PostCObject glue (bettbox dart-bridge, package mobile)."""
    return """// Code generated by tools/bindgen/bindgen.py. DO NOT EDIT.
//
// Dart port plumbing: Dart_InitializeApiDL plus SendToPort, copied from the
// bettbox dart-bridge pattern. Requires dart_api_dl.h/.c in dartbridge/include/.
package mobile

/*
#cgo LDFLAGS: -ldl
#include <stdlib.h>
#include "stdint.h"
#include "dartbridge/include/dart_api_dl.h"
#include "dartbridge/include/dart_api_dl.c"
#include "dartbridge/include/dart_native_api.h"

bool GoDart_PostCObject(Dart_Port_DL port, Dart_CObject* obj) {
  return Dart_PostCObject_DL(port, obj);
}
*/
import "C"

import (
\t"fmt"
\t"unsafe"
)

// initDartApi wires the Dart API DL once per process (throne_init_dart_api).
func initDartApi(api unsafe.Pointer) {
\tif C.Dart_InitializeApiDL(api) != 0 {
\t\tpanic("bridge: Dart_InitializeApiDL failed")
\t}
\tfmt.Println("bridge: Dart API DL initialized")
}

// sendToPort posts one string message to a Dart ReceivePort.
func sendToPort(port int64, msg string) bool {
\tvar obj C.Dart_CObject
\tobj._type = C.Dart_CObject_kString
\tmsgString := C.CString(msg)
\tdefer C.free(unsafe.Pointer(msgString))
\tptr := unsafe.Pointer(&obj.value[0])
\t*(**C.char)(ptr) = msgString
\treturn bool(C.GoDart_PostCObject(C.Dart_Port_DL(port), &obj))
}
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--emit", default="manifest",
                    choices=["manifest", "symbols", "go", "dart", "all"])
    ap.add_argument("--out", default="build/bindgen")
    ap.add_argument("--go-src", default=str(REPO_ROOT.parent / "throne-go" / "core_mobile"),
                    help="core/mobile sources, for resolving Go field-vs-method names")
    args = ap.parse_args()

    if not SOURCES_JAR.exists():
        print(f"missing {SOURCES_JAR}", file=sys.stderr)
        return 2

    go_src = Path(args.go_src)
    if not go_src.is_dir():
        print(f"missing go sources at {go_src} (pass --go-src)", file=sys.stderr)
        return 2
    idx = index_go(go_src)

    classes = load_sources()
    surface = classify(classes)

    if args.emit == "manifest":
        json.dump(surface, sys.stdout, indent=2)
        print()
        c = surface["counts"]
        print(f"# {c['java_to_go']} java->go, {c['constructors']} ctors, "
              f"{c['go_impl_calls']} go-impl calls, {c['jni_callbacks']} jni callbacks, "
              f"{c['port_events']} port events, {surface['classes']} classes",
              file=sys.stderr)
        return 0

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    if args.emit in ("symbols", "all"):
        p = out / "bridge_symbols.h"
        p.write_text(emit_symbols(surface), encoding="utf-8")
        print(f"wrote {p}")
    if args.emit in ("go", "all"):
        p = out / "bridge_calls.go"
        p.write_text(emit_go(surface, idx, classes), encoding="utf-8")
        print(f"wrote {p}")
        p = out / "bridge_runtime.go"
        p.write_text(emit_go_runtime(), encoding="utf-8")
        print(f"wrote {p}")
        p = out / "dartbridge.go"
        p.write_text(emit_dartbridge(), encoding="utf-8")
        print(f"wrote {p}")
    if args.emit in ("dart", "all"):
        p = out / "throne_ffi.dart"
        p.write_text(emit_dart(surface), encoding="utf-8")
        print(f"wrote {p}")
    if args.emit == "all":
        p = out / "surface.json"
        p.write_text(json.dumps(surface, indent=2), encoding="utf-8")
        print(f"wrote {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
