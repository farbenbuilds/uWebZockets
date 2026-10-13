#!/usr/bin/env python3
"""Automated LaTeX paper compilation pipeline using Tectonic.

Compiles both the English IEEE version (paper/main.tex) and the Vietnamese
UIT-NCKHSV-2026 version (paper/uit-nckhsv-2026/main.tex), then copies the
generated PDFs to the user's Downloads folder.

Injects private author identification (e.g. CCCD) locally from .author_private.json
during compilation only, guaranteeing sanitized placeholders in git repository.
"""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PAPER_DIR = PROJECT_ROOT / "paper"
UIT_DIR = PAPER_DIR / "uit-nckhsv-2026"
USER_DOWNLOADS = Path.home() / "Downloads"
PRIVATE_AUTHOR_FILE = PAPER_DIR / ".author_private.json"

TECTONIC_CANDIDATES = [
    Path(os.environ.get("TECTONIC_PATH", "")),
    USER_DOWNLOADS / "tectonic-bin" / "tectonic.exe",
    Path(shutil.which("tectonic") or ""),
]


def find_tectonic() -> Path:
    for candidate in TECTONIC_CANDIDATES:
        if candidate and candidate.is_file():
            return candidate
    raise FileNotFoundError(
        "Tectonic compiler executable not found. Please install tectonic or ensure it is in PATH."
    )


def safe_copy(src: Path, dst: Path) -> Path:
    for attempt in range(10):
        target = dst if attempt == 0 else dst.with_name(f"{dst.stem}-updated{'' if attempt == 1 else f'-v{attempt}'}{dst.suffix}")
        try:
            shutil.copy(src, target)
            if attempt > 0:
                print(f"[!] Target file '{dst.name}' is currently open/locked in a viewer.")
                print(f"[!] Saved as updated copy: {target}")
            return target
        except PermissionError:
            continue
    raise PermissionError(f"Could not copy {src} to {dst} after multiple fallback attempts.")


@contextmanager
def apply_local_private_info(tex_file: Path):
    """Temporarily inject local private author info during compilation only,

    ensuring git-tracked files always remain redacted/placeholder.
    """
    if not PRIVATE_AUTHOR_FILE.is_file():
        yield
        return

    with open(PRIVATE_AUTHOR_FILE, "r", encoding="utf-8") as f:
        private_data = json.load(f)

    with open(tex_file, "r", encoding="utf-8") as f:
        original_content = f.read()

    modified_content = original_content
    # Replace dummy placeholders with real local author credentials
    if "cccd" in private_data:
        modified_content = modified_content.replace(
            "079207012345", private_data["cccd"]
        )
    if "cccd_issue_date" in private_data:
        modified_content = modified_content.replace(
            "15/10/2021", private_data["cccd_issue_date"]
        )

    try:
        with open(tex_file, "w", encoding="utf-8") as f:
            f.write(modified_content)
        print("    [*] Injected local author private info for PDF compilation...")
        yield
    finally:
        with open(tex_file, "w", encoding="utf-8") as f:
            f.write(original_content)
        print("    [*] Reverted tex file to sanitized placeholder.")


def compile_doc(
    src_dir: Path, tex_filename: str, output_pdf_name: str, tectonic_bin: Path
) -> bool:
    tex_path = src_dir / tex_filename
    print(f"[+] Compiling {tex_path}...")

    cmd = [str(tectonic_bin), "--print", tex_filename]

    if src_dir == UIT_DIR:
        cm = apply_local_private_info(tex_path)
    else:
        cm = contextmanager(lambda: (yield))()

    with cm:
        res = subprocess.run(
            cmd, cwd=src_dir, capture_output=True, text=True, encoding="utf-8"
        )

    if res.returncode != 0:
        print(f"[ERROR] Failed to compile {tex_filename}:", file=sys.stderr)
        print(res.stderr or res.stdout, file=sys.stderr)
        return False

    built_pdf = src_dir / (Path(tex_filename).stem + ".pdf")
    if not built_pdf.is_file():
        print(f"[ERROR] Output PDF not found at {built_pdf}", file=sys.stderr)
        return False

    dest = USER_DOWNLOADS / output_pdf_name
    final_dest = safe_copy(built_pdf, dest)
    print(f"[OK] Successfully compiled: {built_pdf} -> {final_dest}")
    return True


def main():
    tectonic = find_tectonic()
    print(f"Using Tectonic: {tectonic}")

    # 1. Compile English Paper
    if not compile_doc(
        PAPER_DIR, "main.tex", "uWebZockets-Paper-IEEE.pdf", tectonic
    ):
        sys.exit(1)

    # 2. Compile Vietnamese Paper (UIT-NCKHSV-2026)
    if not compile_doc(
        UIT_DIR, "main.tex", "UIT-NCKHSV-2026-uWebZockets.pdf", tectonic
    ):
        sys.exit(1)

    print("\n[SUCCESS] Both papers successfully compiled and copied to Downloads!")


if __name__ == "__main__":
    main()
