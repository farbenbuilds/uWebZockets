# uWebZockets research papers

This branch contains the publication sources for the uWebZockets research proposal. It is intentionally independent of the implementation history and contains only the paper sources and bibliographies.

## Contents

- `paper/main.tex` and `paper/ref.bib`: English manuscript.
- `paper/uit-nckhsv-2026/main.tex` and `paper/uit-nckhsv-2026/ref.bib`: Vietnamese UIT-HCM SVNCKH 2026 manuscript.

The manuscripts use repository benchmark contracts and external benchmark suites as methodological references. They do not claim that libxev is faster than libuv without a paired experiment using the same workload, compiler, CPU, protocol semantics, and measurement procedure. Placeholder figures are explicitly marked as synthetic and are not measured results.

## Build

From the repository root, compile each manuscript with a LaTeX distribution and BibTeX. The Vietnamese manuscript uses the UIT-HCM SVNCKH template and the `biblatex` BibTeX backend.

```text
cd paper
pdflatex main.tex
bibtex main
pdflatex main.tex
pdflatex main.tex

cd uit-nckhsv-2026
pdflatex main.tex
bibtex main
pdflatex main.tex
pdflatex main.tex
```

Before publication, verify author metadata, institutional fields, dates, bibliography records, benchmark provenance, and all numerical results against the final experimental runs.
