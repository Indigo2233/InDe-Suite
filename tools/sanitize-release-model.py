#!/usr/bin/env python3
"""Create public ONNX copies with project-owned graph identifiers.

The source models remain untouched.  This utility rewrites names and textual
model metadata only; tensor values, operator types, attributes, and graph
topology are preserved.  It is intended for release staging, not for runtime
use.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Iterable

import onnx
from onnx import ModelProto, NodeProto, TensorProto, ValueInfoProto


MODEL_NAMES = {
    "InDeConv.onnx": "InDeConv",
    "InDeNoise.onnx": "InDeNoise",
    "InDeStars.onnx": "InDeStars",
}

FORBIDDEN = re.compile(
    r"(?:blurxterminator|starxterminator|"
    r"noisexterminator|rc[ -]astro|"
    r"rcroman|starx|nxt|bxt)",
    re.IGNORECASE,
)

FORBIDDEN_PATH = re.compile(
    r"(?:/users/|[a-z]:\\.*downloads|\.pb\b)",
    re.IGNORECASE,
)


def iter_graphs(model: ModelProto):
    """Yield every graph, including graphs nested in node attributes."""

    def visit(graph):
        yield graph
        for node in graph.node:
            for attribute in node.attribute:
                if attribute.HasField("g"):
                    yield from visit(attribute.g)
                for nested in attribute.graphs:
                    yield from visit(nested)

    yield from visit(model.graph)
    for function in model.functions:
        for node in function.node:
            for attribute in node.attribute:
                if attribute.HasField("g"):
                    yield from visit(attribute.g)
                for nested in attribute.graphs:
                    yield from visit(nested)


def iter_tensor_names(model: ModelProto) -> Iterable[str]:
    for graph in iter_graphs(model):
        for value in (*graph.input, *graph.output, *graph.value_info):
            if value.name:
                yield value.name
        for initializer in graph.initializer:
            if initializer.name:
                yield initializer.name
        for sparse in graph.sparse_initializer:
            if sparse.values.name:
                yield sparse.values.name
            if sparse.indices.name:
                yield sparse.indices.name
        for node in graph.node:
            yield from (name for name in node.input if name)
            yield from (name for name in node.output if name)


def iter_attribute_tensors(model: ModelProto) -> Iterable[TensorProto]:
    for graph in iter_graphs(model):
        for node in graph.node:
            for attribute in node.attribute:
                if attribute.HasField("t"):
                    yield attribute.t
                yield from attribute.tensors


def collect_public_names(model: ModelProto) -> set[str]:
    names: set[str] = set()
    for graph in iter_graphs(model):
        names.update(value.name for value in graph.input if value.name)
        names.update(value.name for value in graph.output if value.name)
    return names


def make_tensor_map(model: ModelProto) -> dict[str, str]:
    public_names = collect_public_names(model)
    mapping = {name: name for name in public_names}
    used = set(public_names)
    counter = 0
    for original in iter_tensor_names(model):
        if original in mapping:
            continue
        while True:
            candidate = f"tensor_{counter:06d}"
            counter += 1
            if candidate not in used:
                break
        mapping[original] = candidate
        used.add(candidate)
    for tensor in iter_attribute_tensors(model):
        if tensor.name and tensor.name not in mapping:
            while True:
                candidate = f"tensor_{counter:06d}"
                counter += 1
                if candidate not in used:
                    break
            mapping[tensor.name] = candidate
            used.add(candidate)
    return mapping


def rewrite_attribute(attribute, tensor_map: dict[str, str]) -> None:
    if attribute.HasField("t"):
        rewrite_tensor(attribute.t, tensor_map)
    for tensor in attribute.tensors:
        rewrite_tensor(tensor, tensor_map)
    if attribute.HasField("g"):
        rewrite_graph(attribute.g, tensor_map)
    for graph in attribute.graphs:
        rewrite_graph(graph, tensor_map)


def rewrite_tensor(tensor: TensorProto, tensor_map: dict[str, str]) -> None:
    if tensor.name:
        tensor.name = tensor_map.get(tensor.name, tensor.name)


def rewrite_value(value: ValueInfoProto, tensor_map: dict[str, str]) -> None:
    if value.name:
        value.name = tensor_map.get(value.name, value.name)


def rewrite_node(node: NodeProto, tensor_map: dict[str, str], node_number: int) -> None:
    node.name = f"node_{node_number:06d}"
    for index, name in enumerate(node.input):
        if name:
            node.input[index] = tensor_map[name]
    for index, name in enumerate(node.output):
        if name:
            node.output[index] = tensor_map[name]
    if node.domain:
        raise ValueError(f"Unsupported non-empty operator domain: {node.domain!r}")
    for attribute in node.attribute:
        rewrite_attribute(attribute, tensor_map)


def rewrite_graph(graph, tensor_map: dict[str, str]) -> None:
    graph.name = "graph"
    for value in (*graph.input, *graph.output, *graph.value_info):
        rewrite_value(value, tensor_map)
    for initializer in graph.initializer:
        rewrite_tensor(initializer, tensor_map)
    for sparse in graph.sparse_initializer:
        rewrite_tensor(sparse.values, tensor_map)
        rewrite_tensor(sparse.indices, tensor_map)
    for annotation in graph.quantization_annotation:
        if annotation.tensor_name:
            annotation.tensor_name = tensor_map[annotation.tensor_name]
    for number, node in enumerate(graph.node, start=1):
        rewrite_node(node, tensor_map, number)


def rewrite_function(function, tensor_map: dict[str, str], number: int) -> None:
    function.name = f"function_{number:06d}"
    function.doc_string = ""
    for index, name in enumerate(function.input):
        if name:
            function.input[index] = tensor_map.get(name, name)
    for index, name in enumerate(function.output):
        if name:
            function.output[index] = tensor_map.get(name, name)
    if function.domain:
        raise ValueError(f"Unsupported non-empty function domain: {function.domain!r}")
    for number, node in enumerate(function.node, start=1):
        rewrite_node(node, tensor_map, number)


def rewrite_model(model: ModelProto, public_name: str) -> None:
    tensor_map = make_tensor_map(model)
    rewrite_graph(model.graph, tensor_map)
    for number, function in enumerate(model.functions, start=1):
        rewrite_function(function, tensor_map, number)

    model.producer_name = "InDe Model Export"
    model.producer_version = "1.0"
    model.domain = ""
    model.doc_string = ""
    model.graph.name = public_name
    model.graph.doc_string = ""

    del model.metadata_props[:]
    metadata = {
        "author": "Indigo, LLC",
        "product_name": public_name,
        "license": "All rights reserved",
        "copyright": "Copyright © 2026 Indigo, LLC. All rights reserved.",
    }
    for key, value in metadata.items():
        entry = model.metadata_props.add()
        entry.key = key
        entry.value = value


def forbidden_strings(model: ModelProto) -> list[str]:
    hits: list[str] = []

    def visit(message, path: str) -> None:
        for field, value in message.ListFields():
            field_path = f"{path}.{field.name}"
            if field.type == field.TYPE_STRING:
                values = value if field.is_repeated else (value,)
                for item in values:
                    text = item.decode("utf-8", "replace") if isinstance(item, bytes) else item
                    if FORBIDDEN.search(text) or FORBIDDEN_PATH.search(text):
                        hits.append(f"{field_path}: {text!r}")
            elif field.type == field.TYPE_MESSAGE:
                if field.is_repeated:
                    for index, item in enumerate(value):
                        visit(item, f"{field_path}[{index}]")
                else:
                    visit(value, field_path)

    visit(model, "model")
    return hits


def sanitize(source: Path, destination: Path) -> None:
    public_name = MODEL_NAMES.get(source.name)
    if public_name is None:
        raise ValueError(f"Unsupported model filename: {source.name}")
    model = onnx.load_model(str(source), load_external_data=True)
    rewrite_model(model, public_name)
    onnx.checker.check_model(model)
    hits = forbidden_strings(model)
    if hits:
        raise ValueError("Forbidden source identifiers remain:\n" + "\n".join(hits[:20]))
    destination.parent.mkdir(parents=True, exist_ok=True)
    onnx.save_model(model, str(destination), save_as_external_data=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    sanitize(args.source, args.destination)
    print(f"sanitized {args.source.name} -> {args.destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
