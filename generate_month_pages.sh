#!/usr/bin/env bash
#
# generate_month_pages.sh
# ------------------------------------------------------------
# Asks for a Month + Year, pulls the detail records for that
# month out of the "rz" MariaDB database, and builds four
# report pages in the Roz Jewellers style:
#
#   {mon}p.html  - purchase ledger (+ OLD/NEW breakdown)   -> linked from sp.html
#   {mon}s.html  - sales ledger                            -> linked from sp.html
#   {mon}j.html  - jewellery profit ledger                 -> linked from list.html
#   {mon}e.html  - expense ledger                          -> linked from list.html
#
# e.g. Aug 2026 -> augp.html, augs.html, augj.html, auge.html
#
# Usage:
#   ./generate_month_pages.sh [path-to-folder-containing-the-html-files]
#
# If no folder is given, the current directory is used.
# ------------------------------------------------------------

set -euo pipefail

HTML_DIR="${1:-.}"
SP_PATH="${HTML_DIR%/}/sp.html"
LIST_PATH="${HTML_DIR%/}/list.html"

# ---------- month lookup tables ----------
declare -A MONTH_NUM_MAP=( [jan]=01 [feb]=02 [mar]=03 [apr]=04 [may]=05 [jun]=06
                            [jul]=07 [aug]=08 [sep]=09 [oct]=10 [nov]=11 [dec]=12 )
declare -A MONTH_ABBR_MAP=( [jan]="Jan" [feb]="Feb" [mar]="Mar" [apr]="Apr" [may]="May" [jun]="Jun"
                             [jul]="Jul" [aug]="Aug" [sep]="Sep" [oct]="Oct" [nov]="Nov" [dec]="Dec" )
declare -A MONTH_FULL_MAP=( [jan]="January" [feb]="February" [mar]="March" [apr]="April" [may]="May" [jun]="June"
                             [jul]="July" [aug]="August" [sep]="September" [oct]="October" [nov]="November" [dec]="December" )

# ---------- ask the user ----------
read -rp "Month (e.g. Aug / August): " month_input
read -rp "Year (e.g. 2026): " year_input

month_key="$(echo "${month_input:0:3}" | tr '[:upper:]' '[:lower:]')"

if [[ -z "${MONTH_NUM_MAP[$month_key]:-}" ]]; then
  echo "ERROR: '$month_input' is not a valid month." >&2
  exit 1
fi

if ! [[ "$year_input" =~ ^[0-9]{4}$ ]]; then
  echo "ERROR: '$year_input' is not a valid 4-digit year." >&2
  exit 1
fi

year="$year_input"
month_num="${MONTH_NUM_MAP[$month_key]}"
month_abbr="${MONTH_ABBR_MAP[$month_key]}"
month_full="${MONTH_FULL_MAP[$month_key]}"
date_pattern="${year}-${month_num}%"

p_file="${month_key}p.html"
s_file="${month_key}s.html"
j_file="${month_key}j.html"
e_file="${month_key}e.html"

echo "Building pages for ${month_full} ${year} (pattern: ${date_pattern}) ..."

# ---------- temp folder for raw query output ----------
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_query() {
  # $1 = sql, $2 = output file
  sudo mariadb -D rz -e "$1" > "$2" 2>&1 || true
}

# ----- purchase ledger -----
run_query "select * from p_table
union all select '===========','====','================','===','========','========','========'
union all select ' ',' ','TOTAL PURCHASE',sum(QNTY),' ',sum(TOTAL),' ' from p_table where DATE like '${date_pattern}'
union all select '===========','====','================','===','========','========','========';" \
  "$tmp_dir/purchase_main.txt"

run_query "select STATUS,sum(QNTY),sum(TOTAL) from p_table where STATUS='OLD' AND DATE like '${date_pattern}';" \
  "$tmp_dir/purchase_old.txt"

run_query "select STATUS,sum(QNTY),sum(TOTAL) from p_table where STATUS='NEW' AND DATE like '${date_pattern}';" \
  "$tmp_dir/purchase_new.txt"

# ----- sales ledger -----
run_query "SELECT date, invoice_no, name, order_id, amount, status
FROM invoices
WHERE DATE LIKE '${date_pattern}'
ORDER BY invoice_no;
SELECT 'TOTAL', '', '', '', SUM(amount), ''
FROM invoices
WHERE DATE LIKE '${date_pattern}';" \
  "$tmp_dir/sales_main.txt"

# ----- jewellery profit ledger -----
run_query "SELECT * FROM (
    SELECT ROW_NUMBER() OVER (ORDER BY invoice_no) AS S_NO,
           date, invoice_no, name, e_order_id, order_id,
           amount, '' AS expense, p_price, shipping, profit, status
    FROM invoices
    WHERE DATE LIKE '${date_pattern}'
    ORDER BY invoice_no
    LIMIT 18446744073709551615
) AS sorted_inv
UNION ALL
SELECT '---','----------','----------','----------','-----------',
       '-----------------','---------','--------','--------','--------','---------','-------'
UNION ALL
SELECT ' ',' ',' ',' ',' ','TOTAL',
       SUM(i.amount),
       COALESCE((SELECT SUM(e.amount)
                 FROM expense e
                 WHERE e.DATE LIKE '${date_pattern}'), 0),
       SUM(i.p_price),
       SUM(i.shipping),
       (
           SUM(i.amount)
           - COALESCE((SELECT SUM(e.amount)
                       FROM expense e
                       WHERE e.DATE LIKE '${date_pattern}'), 0)
           - SUM(i.p_price)
           - SUM(i.shipping)
       ),
       ' '
FROM invoices i
WHERE i.DATE LIKE '${date_pattern}'
UNION ALL
SELECT '---','----------','----------','----------','-----------',
       '-----------------','---------','--------','--------','--------','---------','-------';" \
  "$tmp_dir/jewellery.txt"

# ----- expense ledger -----
run_query "select * from (SELECT ROW_NUMBER() OVER (ORDER BY DATE) AS S_NO,
                     DATE, NAME, AMOUNT
                FROM expense
                WHERE DATE like '${date_pattern}'
                ORDER BY DATE LIMIT 18446744073709551615
        ) AS sorted_exp
        union all select '---','----------','----------','---------'
        union all select ' ',' ','TOTAL',sum(AMOUNT) from expense where DATE like '${date_pattern}'
        union all select '---','----------','----------','---------';" \
  "$tmp_dir/expense.txt"

# ---------- hand everything to python for page-building + link updates ----------
export YEAR="$year"
export MONTH_ABBR="$month_abbr"
export MONTH_FULL="$month_full"
export MONTH_KEY="$month_key"
export P_FILE="$p_file"
export S_FILE="$s_file"
export J_FILE="$j_file"
export E_FILE="$e_file"
export SP_PATH="$SP_PATH"
export LIST_PATH="$LIST_PATH"
export HTML_DIR="${HTML_DIR%/}"
export TMP_DIR="$tmp_dir"

python3 <<'PYEOF'
import os
import re
import json
import html

MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]

year        = os.environ["YEAR"]
month_abbr  = os.environ["MONTH_ABBR"]
month_full  = os.environ["MONTH_FULL"]
month_key   = os.environ["MONTH_KEY"]
p_file      = os.environ["P_FILE"]
s_file      = os.environ["S_FILE"]
j_file      = os.environ["J_FILE"]
e_file      = os.environ["E_FILE"]
sp_path     = os.environ["SP_PATH"]
list_path   = os.environ["LIST_PATH"]
html_dir    = os.environ["HTML_DIR"]
tmp_dir     = os.environ["TMP_DIR"]


def read_raw(name):
    path = os.path.join(tmp_dir, name)
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().rstrip("\n")


AMOUNT_KEYWORDS = ("amount", "total", "price", "profit", "shipping")


def is_amount_col(col_name):
    n = col_name.lower()
    return any(k in n for k in AMOUNT_KEYWORDS)


def parse_table(raw_text):
    """Turn tab-separated mariadb output into (header, rows, total_row).
    Drops '===' / '---' divider rows the SQL injects for visual spacing,
    and pulls out any row that mentions TOTAL so it can be rendered as a
    footer instead of a normal ledger line."""
    lines = [l for l in raw_text.splitlines() if l.strip() != ""]
    if not lines:
        return None, [], None

    header = lines[0].split("\t")
    rows, total_row = [], None

    for line in lines[1:]:
        cells = line.split("\t")
        if len(cells) < len(header):
            cells += [""] * (len(header) - len(cells))
        elif len(cells) > len(header):
            cells = cells[: len(header)]

        stripped = [c.strip() for c in cells]
        nonempty = [c for c in stripped if c]

        # divider rows made of only '=' / '-' characters -> drop
        if nonempty and all(set(c) <= set("=-") for c in nonempty):
            continue

        # any cell mentioning TOTAL -> treat as the footer/total row
        if any("total" in c.lower() for c in stripped):
            total_row = cells
            continue

        rows.append(cells)

    return header, rows, total_row


def fmt_cell(col_name, value):
    """Returns (display_text, is_negative) with currency/number formatting."""
    v = value.strip()
    if v in ("", "NULL", "None"):
        return "", False
    try:
        num = float(v.replace(",", ""))
    except ValueError:
        return html.escape(v), False

    if is_amount_col(col_name):
        neg = num < 0
        minus_sign = "\u2212" if neg else ""
        text = f"{minus_sign}\u20b9{abs(num):,.2f}"
        return html.escape(text), neg

    if num == int(num):
        return html.escape(str(int(num))), False
    return html.escape(f"{num:,.2f}"), False


def render_table(raw_text, sub_heading=None):
    """Builds a styled <table> (Roz Jewellers ledger look) from raw
    tab-separated query output. Returns (html_snippet, entry_count, total_value)."""
    header, rows, total_row = parse_table(raw_text)
    if header is None:
        return "", 0, None

    thead_cells = []
    for col in header:
        cls = ' class="num"' if is_amount_col(col) else ""
        thead_cells.append(f"<th{cls}>{html.escape(col)}</th>")

    body_html = []
    for row in rows:
        tds = []
        for col, cell in zip(header, row):
            text, is_neg = fmt_cell(col, cell)
            classes = []
            if is_amount_col(col):
                classes.append("num")
            if is_neg:
                classes.append("credit")
            cls = f' class="{" ".join(classes)}"' if classes else ""
            tds.append(f"<td{cls}>{text}</td>")
        body_html.append(f"<tr>{''.join(tds)}</tr>")

    foot_html = ""
    total_value = None
    if total_row:
        tds = []
        for col, cell in zip(header, total_row):
            text, is_neg = fmt_cell(col, cell)
            if is_amount_col(col) and text and total_value is None:
                try:
                    total_value = float(cell.strip().replace(",", ""))
                except ValueError:
                    pass
            cls = ' class="num"' if is_amount_col(col) else ""
            tds.append(f"<td{cls}>{text}</td>")
        foot_html = f"<tfoot><tr>{''.join(tds)}</tr></tfoot>"

    heading_html = f'<h2 class="section-heading">{html.escape(sub_heading)}</h2>' if sub_heading else ""

    table_html = f"""{heading_html}
  <div class="ledger">
    <table>
      <thead><tr>{''.join(thead_cells)}</tr></thead>
      <tbody>{''.join(body_html) if body_html else '<tr><td colspan="%d" class="empty">No records</td></tr>' % len(header)}</tbody>
      {foot_html}
    </table>
  </div>"""

    return table_html, len(rows), total_value


PAGE_CSS = """
  :root{
    --ink:#141110;
    --panel-line:#3a3128;
    --gold:#cda653;
    --gold-soft:#e8d5a3;
    --cream:#f3ecdd;
    --cream-dim:#a99f8d;
    --credit:#6b9e78;
    --row-size:1rem;
  }
  *{ box-sizing:border-box; }
  body{
    margin:0; min-height:100vh;
    font-family:'Poppins', sans-serif;
    background: radial-gradient(circle at 50% -10%, #2a221b 0%, var(--ink) 55%), var(--ink);
    color:var(--cream);
    padding:40px 20px 80px;
  }
  .topbar{
    max-width:900px; margin:0 auto 10px;
    display:flex; justify-content:space-between; align-items:center;
  }
  .back-link{
    font-size:0.82rem; letter-spacing:0.04em; color:var(--cream-dim);
    text-decoration:none; border:1px solid var(--panel-line);
    padding:8px 16px; border-radius:999px;
    transition:border-color .3s ease, color .3s ease;
  }
  .back-link:hover{ border-color:var(--gold); color:var(--gold-soft); }
  .zoom-controls{ display:flex; gap:6px; }
  .zoom-controls button{
    font-family:'Poppins', sans-serif; font-size:0.78rem; font-weight:500;
    color:var(--gold-soft); background:#1d1815; border:1px solid var(--panel-line);
    padding:8px 14px; border-radius:999px; cursor:pointer;
    transition:border-color .3s ease, color .3s ease;
  }
  .zoom-controls button:hover{ border-color:var(--gold); color:var(--gold-soft); }
  .page-title{ max-width:900px; margin:0 auto 6px; text-align:center; }
  .page-title h1{
    font-family:'Cormorant Garamond', serif; font-weight:600;
    font-size:clamp(1.9rem, 4.2vw, 2.5rem); color:var(--gold-soft); margin:0 0 6px;
  }
  .page-title p{ margin:0; font-size:0.8rem; letter-spacing:0.14em; color:var(--cream-dim); }
  .summary-strip{
    max-width:900px; margin:26px auto 34px; display:flex;
    justify-content:center; gap:14px; flex-wrap:wrap;
  }
  .summary-pill{
    border:1px solid var(--panel-line); border-radius:14px; padding:12px 22px;
    background:linear-gradient(160deg, #201a15, #171310); text-align:center; min-width:120px;
  }
  .summary-pill .label{ font-size:0.68rem; letter-spacing:0.1em; color:var(--cream-dim); margin-bottom:4px; }
  .summary-pill .value{
    font-family:'Cormorant Garamond', serif; font-size:1.3rem; font-weight:600; color:var(--gold-soft);
  }
  .section-heading{
    max-width:900px; margin:26px auto 8px; padding:0 4px;
    font-family:'Cormorant Garamond', serif; font-weight:600; font-size:1.2rem; color:var(--gold-soft);
  }
  .ledger{
    max-width:900px; margin:0 auto 18px;
    background:linear-gradient(160deg, #201a15, #171310);
    border:1px solid var(--panel-line); border-radius:20px; padding:8px 0 0;
    box-shadow:0 14px 30px -18px rgba(0,0,0,0.75); overflow:auto;
  }
  table{ width:100%; border-collapse:collapse; font-size:var(--row-size); }
  thead th{
    font-size:0.72rem; letter-spacing:0.08em; color:var(--cream-dim); font-weight:500;
    text-align:left; padding:14px 18px; border-bottom:1px solid var(--panel-line); white-space:nowrap;
  }
  thead th.num, td.num{ text-align:right; }
  tbody td{
    padding:12px 18px; border-bottom:1px solid rgba(58,49,40,0.5);
    font-variant-numeric:tabular-nums; color:var(--cream); white-space:nowrap;
  }
  tbody tr:last-of-type td{ border-bottom:none; }
  tbody tr:nth-child(even){ background:rgba(243,236,221,0.02); }
  tbody tr:hover{ background:rgba(205,166,83,0.06); }
  td.credit{ color:var(--credit); }
  td.empty{ text-align:center; color:var(--cream-dim); padding:22px; }
  tfoot td{
    padding:16px 18px; font-family:'Cormorant Garamond', serif; font-size:1.1rem;
    font-weight:600; color:var(--gold-soft); border-top:1px solid var(--gold);
    background:rgba(205,166,83,0.06);
  }
  @media (max-width:560px){
    thead th, tbody td, tfoot td{ padding:10px 12px; }
    .summary-pill{ min-width:100px; padding:10px 16px; }
  }
"""

PAGE_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=Poppins:wght@400;500;600&display=swap" rel="stylesheet">
<style>{css}</style>
</head>
<body>

  <div class="topbar">
    <a class="back-link" href="{back_href}">&larr; {back_label}</a>
    <div class="zoom-controls">
      <button onclick="zoomOut()">A&minus;</button>
      <button onclick="resetZoom()">Reset</button>
      <button onclick="zoomIn()">A+</button>
    </div>
  </div>

  <div class="page-title">
    <h1>{title}</h1>
    <p>Roz Jewellers &middot; Business Records</p>
  </div>

  <div class="summary-strip">
{summary_pills}
  </div>

{sections}

  <script>
    let fontScale = 1;
    function applyScale() {{
      document.querySelector(':root').style.setProperty('--row-size', (1 * fontScale) + 'rem');
    }}
    function zoomIn() {{ fontScale = Math.min(fontScale + 0.1, 1.8); applyScale(); }}
    function zoomOut() {{ fontScale = Math.max(fontScale - 0.1, 0.7); applyScale(); }}
    function resetZoom() {{ fontScale = 1; applyScale(); }}
  </script>
</body>
</html>
"""


def build_page(title, back_href, back_label, sections):
    """sections: list of (sub_heading_or_None, raw_text). The first section's
    stats drive the ENTRIES/TOTAL summary pills at the top of the page."""
    table_blocks = []
    entry_count, total_value = None, None
    for i, (heading, raw_text) in enumerate(sections):
        table_html, count, total = render_table(raw_text, sub_heading=heading)
        table_blocks.append(table_html)
        if i == 0:
            entry_count, total_value = count, total

    pills = [f'    <div class="summary-pill"><div class="label">ENTRIES</div><div class="value">{entry_count}</div></div>']
    if total_value is not None:
        sign = "&minus;" if total_value < 0 else ""
        pills.append(
            f'    <div class="summary-pill"><div class="label">TOTAL</div>'
            f'<div class="value">{sign}\u20b9{abs(total_value):,.2f}</div></div>'
        )

    return PAGE_TEMPLATE.format(
        title=title, css=PAGE_CSS, back_href=back_href, back_label=back_label,
        summary_pills="\n".join(pills),
        sections="\n".join(table_blocks),
    )


def write_page(filename, html_text):
    out_path = os.path.join(html_dir, filename)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html_text)
    print(f"  wrote {out_path}")


# ---------- 1. purchase ledger ----------
purchase_sections = [
    (None, read_raw("purchase_main.txt")),
    ("Old Gold", read_raw("purchase_old.txt")),
    ("New Gold", read_raw("purchase_new.txt")),
]
write_page(p_file, build_page(f"{month_full} Purchases", "sp.html", "Sales vs Purchases", purchase_sections))

# ---------- 2. sales ledger ----------
sales_sections = [(None, read_raw("sales_main.txt"))]
write_page(s_file, build_page(f"{month_full} Sales", "sp.html", "Sales vs Purchases", sales_sections))

# ---------- 3. jewellery profit ledger ----------
jewellery_sections = [(None, read_raw("jewellery.txt"))]
write_page(j_file, build_page(f"{month_full} Jewellery Profit", "list.html", "Monthly Report", jewellery_sections))

# ---------- 4. expense ledger ----------
expense_sections = [(None, read_raw("expense.txt"))]
write_page(e_file, build_page(f"{month_full} Expenses", "list.html", "Monthly Report", expense_sections))


# ================= link updates =================

def gen_default_links(prefix):
    links = {}
    for i, m in enumerate(MONTHS):
        links[m] = f"{prefix}_{m.lower()}.html" if i >= 9 else f"{prefix}{m.lower()}.html"
    return links


def js_obj_to_json(s):
    s = s.replace("'", '"')
    s = re.sub(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)', r'\1"\2"\3', s)
    return s


def extract_data_by_year(content):
    m = re.search(r"const dataByYear = \{(.*?)\n\s*\};", content, re.DOTALL)
    if not m:
        raise RuntimeError("Could not locate 'const dataByYear = {...};' block")
    data = json.loads("{" + js_obj_to_json(m.group(1)) + "}")
    return m, data


def update_sp_links(path, year, month_abbr, p_link, s_link):
    content = open(path, encoding="utf-8").read()
    m, data = extract_data_by_year(content)
    yk = str(year)
    if yk not in data:
        data[yk] = {
            "saleAmounts": [0] * 12,
            "saleQuantities": [0] * 12,
            "purchaseAmounts": [0] * 12,
            "purchaseQuantities": [0] * 12,
            "purchaseLinks": gen_default_links("p"),
            "saleLinks": gen_default_links("s"),
        }
    data[yk]["purchaseLinks"][month_abbr] = p_link
    data[yk]["saleLinks"][month_abbr] = s_link
    data = dict(sorted(data.items(), key=lambda kv: int(kv[0])))
    new_block = "const dataByYear = " + json.dumps(data, indent=6) + ";"
    new_content = content[: m.start()] + new_block + content[m.end():]
    open(path, "w", encoding="utf-8").write(new_content)
    print(f"  sp.html: {month_abbr} {year} -> purchase='{p_link}', sale='{s_link}'")


def update_list_links(path, year, month_full, j_link, e_link):
    content = open(path, encoding="utf-8").read()
    pattern = re.compile(
        r'<div class="month-card" data-year="(\d+)">\s*<h2>(\w+)</h2>.*?</div>\s*</div>\s*</div>',
        re.DOTALL,
    )
    for m in pattern.finditer(content):
        if m.group(1) == str(year) and m.group(2) == month_full:
            block = m.group(0)
            block = re.sub(
                r"(bar-phone\" data-total=\"[^\"]*\" onclick=\"openPage\(')[^']*('\))",
                rf"\g<1>{j_link}\g<2>", block,
            )
            block = re.sub(
                r"(bar-expenses\" data-total=\"[^\"]*\" onclick=\"openPage\(')[^']*('\))",
                rf"\g<1>{e_link}\g<2>", block,
            )
            content = content[: m.start()] + block + content[m.end():]
            open(path, "w", encoding="utf-8").write(content)
            print(f"  list.html: {month_full} {year} -> profit='{j_link}', expenses='{e_link}'")
            return
    print(
        f"  NOTE: no month-card found for {month_full} {year} in list.html yet. "
        f"Run update_report.sh first to create the totals card, then re-run this script "
        f"(or add the card manually) so the links can be attached."
    )


update_sp_links(sp_path, year, month_abbr, p_file, s_file)
update_list_links(list_path, year, month_full, j_file, e_file)

print("Done.")
PYEOF
