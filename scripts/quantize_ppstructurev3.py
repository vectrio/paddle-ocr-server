#!/usr/bin/env python3

import argparse
import importlib
import inspect
import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Tuple


@dataclass
class ModelSpec:
    name: str
    model_dir: str
    source: str


def normalize_path(path_text: str, base_dir: str) -> str:
    candidate = pathlib.Path(path_text)
    if candidate.is_absolute():
        return str(candidate)
    return str((pathlib.Path(base_dir) / candidate).resolve())


def iter_dict_paths(node: Any, current_path: str = "root") -> Iterable[Tuple[str, Any]]:
    if isinstance(node, dict):
        yield current_path, node
        for key, value in node.items():
            child_path = f"{current_path}.{key}"
            yield from iter_dict_paths(value, child_path)
    elif isinstance(node, list):
        for idx, value in enumerate(node):
            child_path = f"{current_path}[{idx}]"
            yield from iter_dict_paths(value, child_path)


def collect_model_specs(config_obj: Dict[str, Any], config_dir: str) -> List[ModelSpec]:
    specs: List[ModelSpec] = []
    for path, obj in iter_dict_paths(config_obj):
        if not isinstance(obj, dict):
            continue

        model_dir = obj.get("model_dir")
        if model_dir in (None, "null", "None", ""):
            continue

        model_name = obj.get("model_name", "unknown_model")
        module_name = obj.get("module_name", "unknown_module")
        key_name = path.split(".")[-1]
        safe_name = re.sub(r"[^a-zA-Z0-9._-]+", "_", f"{key_name}__{module_name}__{model_name}")
        specs.append(
            ModelSpec(
                name=safe_name,
                model_dir=normalize_path(str(model_dir), config_dir),
                source=path,
            )
        )
    return specs


def detect_model_and_params(model_dir: str) -> Tuple[Optional[str], Optional[str], Optional[str], List[str]]:
    warnings: List[str] = []
    path_obj = pathlib.Path(model_dir)
    if not path_obj.exists() or not path_obj.is_dir():
        warnings.append("model_dir does not exist")
        return None, None, None, warnings

    def select_model_pair(base_dir: pathlib.Path, model_files: List[pathlib.Path], params_files: List[pathlib.Path]) -> Tuple[Optional[str], Optional[str], List[str]]:
        local_warnings: List[str] = []

        if not model_files:
            local_warnings.append("no .pdmodel file found")
            return None, None, local_warnings
        if not params_files:
            local_warnings.append("no .pdiparams file found")
            return None, None, local_warnings

        if len(model_files) == 1 and len(params_files) == 1:
            return model_files[0].name, params_files[0].name, local_warnings

        model_stems = {m.stem: m for m in model_files}
        params_stems = {p.stem: p for p in params_files}
        shared = sorted(set(model_stems.keys()) & set(params_stems.keys()))
        if shared:
            stem = shared[0]
            local_warnings.append(f"multiple model files found; selected stem '{stem}'")
            return model_stems[stem].name, params_stems[stem].name, local_warnings

        local_warnings.append("multiple model/params files found; using first files")
        return model_files[0].name, params_files[0].name, local_warnings

    model_files = sorted(path_obj.glob("*.pdmodel"))
    params_files = sorted(path_obj.glob("*.pdiparams"))
    model_filename, params_filename, local_warnings = select_model_pair(path_obj, model_files, params_files)
    warnings.extend(local_warnings)
    if model_filename is not None and params_filename is not None:
        return str(path_obj), model_filename, params_filename, warnings

    # Fallback: recursively search for inference files under model_dir.
    candidate_pairs: List[Tuple[pathlib.Path, str, str]] = []
    for candidate_dir in sorted({p.parent for p in path_obj.rglob("*.pdmodel")}):
        candidate_model_files = sorted(candidate_dir.glob("*.pdmodel"))
        candidate_params_files = sorted(candidate_dir.glob("*.pdiparams"))
        c_model_filename, c_params_filename, _ = select_model_pair(candidate_dir, candidate_model_files, candidate_params_files)
        if c_model_filename is not None and c_params_filename is not None:
            candidate_pairs.append((candidate_dir, c_model_filename, c_params_filename))

    if not candidate_pairs:
        return None, None, None, warnings

    candidate_pairs.sort(key=lambda t: len(t[0].parts))
    selected_dir, selected_model, selected_params = candidate_pairs[0]
    warnings.append(f"inference files found in nested directory; using '{selected_dir}'")
    return str(selected_dir), selected_model, selected_params, warnings


def call_with_supported_kwargs(func: Any, kwargs: Dict[str, Any]) -> Any:
    sig = inspect.signature(func)
    allowed = {name for name in sig.parameters.keys()}
    filtered = {k: v for k, v in kwargs.items() if k in allowed}
    return func(**filtered)


def quantize_dynamic(
    model_dir: str,
    save_dir: str,
    model_filename: str,
    params_filename: str,
    weight_bits: int,
    quantizable_op_type: List[str],
) -> Tuple[bool, str]:
    import paddle

    place = paddle.CPUPlace()
    exe = paddle.static.Executor(place)

    base_kwargs = {
        "executor": exe,
        "model_dir": model_dir,
        "save_model_dir": save_dir,
        "model_filename": model_filename,
        "params_filename": params_filename,
        "weight_bits": weight_bits,
        "quantizable_op_type": quantizable_op_type,
    }

    try:
        paddleslim_quant = importlib.import_module("paddleslim.quant")
        quant_post_dynamic = getattr(paddleslim_quant, "quant_post_dynamic")
        call_with_supported_kwargs(quant_post_dynamic, base_kwargs)
        return True, "paddleslim.quant.quant_post_dynamic"
    except Exception as first_error:
        try:
            paddle_quant = importlib.import_module("paddle.static.quantization")
            quant_post_dynamic = getattr(paddle_quant, "quant_post_dynamic")
            call_with_supported_kwargs(quant_post_dynamic, base_kwargs)
            return True, "paddle.static.quantization.quant_post_dynamic"
        except Exception as second_error:
            return (
                False,
                f"dynamic quantization failed. paddleslim error: {first_error}; paddle.static error: {second_error}",
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Quantize PPStructureV3 sub-module inference models.")
    parser.add_argument("--config", required=True, help="Path to PP-StructureV3 YAML config")
    parser.add_argument("--output-root", required=True, help="Root output directory for quantized models")
    parser.add_argument("--weight-bits", type=int, default=8, help="Weight bit-width for dynamic quantization")
    parser.add_argument(
        "--quant-ops",
        default="conv2d,depthwise_conv2d,mul,matmul",
        help="Comma-separated quantizable op types",
    )
    parser.add_argument(
        "--extra-model-dirs",
        default="",
        help="Comma-separated additional model directories to quantize",
    )
    parser.add_argument(
        "--fail-on-error",
        action="store_true",
        help="Exit non-zero if any model quantization fails",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        import yaml
    except Exception:
        print("Missing dependency: pyyaml. Install with: pip install pyyaml")
        return 1

    config_path = pathlib.Path(args.config).resolve()
    if not config_path.exists():
        print(f"Config not found: {config_path}")
        return 1

    output_root = pathlib.Path(args.output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    with config_path.open("r", encoding="utf-8") as f:
        config_obj = yaml.safe_load(f)

    quant_ops = [op.strip() for op in args.quant_ops.split(",") if op.strip()]
    specs = collect_model_specs(config_obj, str(config_path.parent))

    extra_dirs = [item.strip() for item in args.extra_model_dirs.split(",") if item.strip()]
    for idx, extra_dir in enumerate(extra_dirs, start=1):
        resolved = normalize_path(extra_dir, str(pathlib.Path.cwd()))
        specs.append(
            ModelSpec(
                name=f"extra_{idx}",
                model_dir=resolved,
                source="cli.extra_model_dirs",
            )
        )

    unique: Dict[str, ModelSpec] = {}
    for spec in specs:
        unique[os.path.normpath(spec.model_dir)] = spec
    specs = list(unique.values())

    if not specs:
        print("No local model_dir entries found in config and no extra model dirs provided.")
        print("Tip: add model_dir paths in PP-StructureV3.yaml or pass --extra-model-dirs.")
        return 0

    summary: Dict[str, Any] = {
        "config": str(config_path),
        "output_root": str(output_root),
        "weight_bits": args.weight_bits,
        "quant_ops": quant_ops,
        "total": len(specs),
        "success": 0,
        "failed": 0,
        "items": [],
    }

    for spec in specs:
        item: Dict[str, Any] = {
            "name": spec.name,
            "model_dir": spec.model_dir,
            "source": spec.source,
            "status": "pending",
            "warnings": [],
        }
        resolved_model_dir, model_filename, params_filename, detect_warnings = detect_model_and_params(spec.model_dir)
        item["warnings"].extend(detect_warnings)

        if resolved_model_dir is None or model_filename is None or params_filename is None:
            item["status"] = "skipped"
            item["reason"] = "model files not detected"
            summary["failed"] += 1
            summary["items"].append(item)
            continue

        save_dir = output_root / spec.name
        save_dir.mkdir(parents=True, exist_ok=True)

        ok, backend = quantize_dynamic(
            model_dir=resolved_model_dir,
            save_dir=str(save_dir),
            model_filename=model_filename,
            params_filename=params_filename,
            weight_bits=args.weight_bits,
            quantizable_op_type=quant_ops,
        )

        item["resolved_model_dir"] = resolved_model_dir
        item["output_dir"] = str(save_dir)
        item["model_filename"] = model_filename
        item["params_filename"] = params_filename

        if ok:
            item["status"] = "success"
            item["backend"] = backend
            summary["success"] += 1
        else:
            item["status"] = "failed"
            item["reason"] = backend
            summary["failed"] += 1

        summary["items"].append(item)

    summary_path = output_root / "quantization_summary.json"
    with summary_path.open("w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print(json.dumps(summary, indent=2))
    print(f"Summary written to: {summary_path}")

    if args.fail_on_error and summary["failed"] > 0:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
