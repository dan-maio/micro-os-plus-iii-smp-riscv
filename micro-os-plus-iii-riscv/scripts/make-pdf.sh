#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# make-pdf.sh -- render a Markdown document to PDF, beside it.
#
#     scripts/make-pdf.sh README.md            -> README.pdf
#     scripts/make-pdf.sh doc.md out.pdf
#
# pandoc (GitHub-flavoured Markdown -> HTML, with a table of contents) and
# weasyprint (HTML -> PDF), styled by scripts/readme-pdf.css. Images are
# resolved relative to the Markdown file.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD="$(realpath "$1")"
PDF="${2:-${MD%.md}.pdf}"
TITLE="$(grep -m1 '^# ' "$MD" | sed 's/^# //')"

command -v pandoc >/dev/null || { echo "make-pdf.sh: needs pandoc" >&2; exit 2; }
command -v weasyprint >/dev/null || { echo "make-pdf.sh: needs weasyprint" >&2; exit 2; }

TMP="$(mktemp --suffix=.html)"
trap 'rm -f "$TMP"' EXIT

pandoc "$MD" -f gfm -t html5 -s --toc --toc-depth=2 \
  --metadata title="${TITLE:-$(basename "$MD" .md)}" --metadata toc-title="Contents" \
  --css "$HERE/readme-pdf.css" -o "$TMP"
# pandoc adds a title block; the document has its own H1.
sed -i '/<header id="title-block-header">/,/<\/header>/d' "$TMP"
weasyprint --base-url "$(dirname "$MD")/" "$TMP" "$PDF" 2>/dev/null
echo "$PDF ($(pdfinfo "$PDF" 2>/dev/null | awk '/^Pages/ {print $2}') pages)"
