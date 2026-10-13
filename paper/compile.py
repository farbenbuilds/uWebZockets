"""Automated LaTeX to PDF compiler for uWebZockets papers using Tectonic.

Runs with:
    uv run python paper/compile.py
"""

from contextlib import contextmanager
import json
import shutil
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

# Paths
REPO_ROOT = Path(__file__).resolve().parent.parent
PAPER_DIR = REPO_ROOT / "paper"
UIT_DIR = PAPER_DIR / "uit-nckhsv-2026"
DOWNLOADS_DIR = Path.home() / "Downloads"
PRIVATE_AUTHOR_FILE = PAPER_DIR / ".author_private.json"

TECTONIC_CANDIDATES = [
    Path(r"C:\Users\Sh1ro\Downloads\tectonic-bin\tectonic.exe"),
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
    try:
        shutil.copy(src, dst)
        return dst
    except PermissionError:
        # File might be open in a PDF viewer (Acrobat, Chrome, Edge)
        fallback = dst.with_name(dst.stem + "-updated" + dst.suffix)
        shutil.copy(src, fallback)
        print(f"[!] Target file '{dst.name}' is currently open/locked in a viewer.")
        print(f"[!] Saved as updated copy: {fallback}")
        return fallback


@contextmanager
def apply_local_private_info(tex_file: Path):
    """Temporarily inject local private author info during compilation only,

    ensuring git-tracked files always remain redacted/placeholder.
    """
    if not PRIVATE_AUTHOR_FILE.is_file():
        yield
        return

    try:
        with open(PRIVATE_AUTHOR_FILE, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        real_cccd = cfg.get("cccd")
        real_ngay_cap = cfg.get("ngay_cap")
    except Exception as e:
        print(f"[!] Warning reading private author info: {e}")
        yield
        return

    if not real_cccd or not real_ngay_cap:
        yield
        return

    original_content = tex_file.read_text(encoding="utf-8")
    placeholder_line = "Số CCCD: & 079207012345 & Ngày cấp: & 15/10/2021 \\\\"
    real_line = f"Số CCCD: & {real_cccd} & Ngày cấp: & {real_ngay_cap} \\\\"

    if placeholder_line in original_content:
        tex_file.write_text(
            original_content.replace(placeholder_line, real_line),
            encoding="utf-8",
        )
        print("[*] Injected local author private info for PDF compilation...")
        try:
            yield
        finally:
            tex_file.write_text(original_content, encoding="utf-8")
            print("[*] Reverted tex file to sanitized placeholder.")
    else:
        yield


def compile_doc(
    tex_dir: Path, main_file: str, output_pdf_name: str, tectonic_bin: Path
) -> bool:
    print(f"[+] Compiling {tex_dir / main_file}...")
    tex_path = tex_dir / main_file
    with apply_local_private_info(tex_path):
        cmd = [str(tectonic_bin), main_file]
        result = subprocess.run(
            cmd, cwd=tex_dir, capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"[-] Compilation failed for {main_file}:", file=sys.stderr)
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            return False

        built_pdf = tex_dir / (Path(main_file).stem + ".pdf")
        if not built_pdf.exists():
            print(
                f"[-] Output PDF {built_pdf} was not produced!", file=sys.stderr
            )
            return False

        dest = DOWNLOADS_DIR / output_pdf_name
        final_dest = safe_copy(built_pdf, dest)
        print(f"[OK] Successfully compiled: {built_pdf} -> {final_dest}")
        return True


def main():
    try:
        tectonic = find_tectonic()
        print(f"Using Tectonic: {tectonic}")
    except FileNotFoundError as err:
        print(f"Error: {err}", file=sys.stderr)
        sys.exit(1)

    success = True
    # Compile IEEE English paper
    if not compile_doc(
        PAPER_DIR, "main.tex", "uWebZockets-Paper-IEEE.pdf", tectonic
    ):
        success = False

    # Compile UIT Vietnamese proposal
    if not compile_doc(
        UIT_DIR, "main.tex", "UIT-NCKHSV-2026-uWebZockets.pdf", tectonic
    ):
        success = False

    if success:
        print(
            "\n[SUCCESS] Both papers successfully compiled and copied to Downloads!"
        )
    else:
        print("\n[FAILURE] One or more compilations had errors.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
