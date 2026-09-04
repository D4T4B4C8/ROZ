#!/usr/bin/env bash
#
# update_report.sh
# ------------------------------------------------------------
# Asks for a Month + Year, pulls the totals for that month out
# of the "rz" MariaDB database, and writes the numbers into
# sp.html, all.html and list.html.
#
# Usage:
#   ./update_report.sh [path-to-folder-containing-the-html-files]
#
# If no folder is given, the current directory is used.
# ------------------------------------------------------------

set -euo pipefail

HTML_DIR="${1:-.}"
SP_PATH="${HTML_DIR%/}/sp.html"
ALL_PATH="${HTML_DIR%/}/all.html"
LIST_PATH="${HTML_DIR%/}/list.html"

for f in "$SP_PATH" "$ALL_PATH" "$LIST_PATH"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: could not find $f" >&2
    exit 1
  fi
done

# ---------- month lookup tables ----------
declare -A MONTH_NUM_MAP=( [jan]=01 [feb]=02 [mar]=03 [apr]=04 [may]=05 [jun]=06
                            [jul]=07 [aug]=08 [sep]=09 [oct]=10 [nov]=11 [dec]=12 )
declare -A MONTH_ABBR_MAP=( [jan]="Jan" [feb]="Feb" [mar]="Mar" [apr]="Apr" [may]="May" [jun]="Jun"
                             [jul]="Jul" [aug]="Aug" [sep]="Sep" [oct]="Oct" [nov]="Nov" [dec]="Dec" )
declare -A MONTH_FULL_MAP=( [jan]="January" [feb]="February" [mar]="March" [apr]="April" [may]="May" [jun]="June"
                             [jul]="July" [aug]="August" [sep]="September" [oct]="October" [nov]="November" [dec]="December" )
declare -A MONTH_IDX_MAP=( [jan]=0 [feb]=1 [mar]=2 [apr]=3 [may]=4 [jun]=5
                            [jul]=6 [aug]=7 [sep]=8 [oct]=9 [nov]=10 [dec]=11 )

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
month_idx="${MONTH_IDX_MAP[$month_key]}"
date_pattern="${year}-${month_num}%"

echo "Fetching figures for ${month_full} ${year} (pattern: ${date_pattern}) ..."

# ---------- helper to strip NULL / blank ----------
norm() {
  local v="$1"
  if [[ -z "$v" || "$v" == "NULL" ]]; then
    echo 0
  else
    echo "$v"
  fi
}

# ---------- run the queries ----------
purchase_row=$(sudo mariadb -N -B -D rz -e \
  "select sum(TOTAL), sum(QNTY) from p_table where DATE like '${date_pattern}'")
IFS=$'\t' read -r purchase_total purchase_qty <<< "$purchase_row"

sale_amount=$(sudo mariadb -N -B -D rz -e \
  "select sum(AMOUNT) from invoices where DATE like '${date_pattern}'")

sale_qty=$(sudo mariadb -N -B -D rz -e \
  "select sum(QNTY) from sold where DATE like '${date_pattern}'")

profit=$(sudo mariadb -N -B -D rz -e \
  "SELECT
      (SELECT COALESCE(SUM(profit), 0)
       FROM invoices
       WHERE DATE LIKE '${date_pattern}')
      -
      (SELECT COALESCE(SUM(amount), 0)
       FROM expense
       WHERE DATE LIKE '${date_pattern}') AS net_profit;")

p=$(sudo mariadb -N -B -D rz -e \
  "SELECT SUM(profit)
       FROM invoices
       WHERE DATE LIKE '${date_pattern}'")

expense=$(sudo mariadb -N -B -D rz -e \
  "select sum(AMOUNT) from expense where DATE like '${date_pattern}'")

purchase_total="$(norm "$purchase_total")"
purchase_qty="$(norm "$purchase_qty")"
sale_amount="$(norm "$sale_amount")"
sale_qty="$(norm "$sale_qty")"
profit="$(norm "$profit")"
p="$(norm "$p")"
expense="$(norm "$expense")"

echo "  Purchase total : $purchase_total   (qty: $purchase_qty)"
echo "  Sale amount    : $sale_amount   (qty: $sale_qty)"
echo "  Jewellery profit (net, for all.html): $profit"
echo "  Jewellery profit (p, for list.html) : $p"
echo "  Expenses       : $expense"

# ---------- hand everything to python for the actual file edits ----------
export YEAR="$year"
export MONTH_ABBR="$month_abbr"
export MONTH_FULL="$month_full"
export MONTH_IDX="$month_idx"
export PURCHASE_TOTAL="$purchase_total"
export PURCHASE_QTY="$purchase_qty"
export SALE_AMOUNT="$sale_amount"
export SALE_QTY="$sale_qty"
export PROFIT="$profit"
export P_VALUE="$p"
export EXPENSE="$expense"
export SP_PATH="$SP_PATH"
export ALL_PATH="$ALL_PATH"
export LIST_PATH="$LIST_PATH"

python3 <<'PYEOF'
import os
import re
import json

MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]


def num(v):
    v = float(v)
    return int(v) if v == int(v) else v


def gen_links(prefix):
    links = {}
    for i, m in enumerate(MONTHS):
        if i >= 9:  # Oct, Nov, Dec use an underscore, matching the existing files
            links[m] = f"{prefix}_{m.lower()}.html"
        else:
            links[m] = f"{prefix}{m.lower()}.html"
    return links


def js_obj_to_json(s):
    s = s.replace("'", '"')
    # quote bare object keys: identifier followed by a colon
    s = re.sub(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)', r'\1"\2"\3', s)
    return s


def extract_data_by_year(content):
    m = re.search(r"const dataByYear = \{(.*?)\n\s*\};", content, re.DOTALL)
    if not m:
        raise RuntimeError("Could not locate 'const dataByYear = {...};' block")
    json_text = "{" + js_obj_to_json(m.group(1)) + "}"
    data = json.loads(json_text)
    return m, data


def write_data_by_year(content, m, data):
    data = dict(sorted(data.items(), key=lambda kv: int(kv[0])))
    new_block = "const dataByYear = " + json.dumps(data, indent=6) + ";"
    return content[:m.start()] + new_block + content[m.end():]


def update_sp(path, year, month_idx, purchase_total, purchase_qty, sale_amount, sale_qty):
    content = open(path, encoding="utf-8").read()
    m, data = extract_data_by_year(content)
    yk = str(year)
    if yk not in data:
        data[yk] = {
            "saleAmounts": [0] * 12,
            "saleQuantities": [0] * 12,
            "purchaseAmounts": [0] * 12,
            "purchaseQuantities": [0] * 12,
            "purchaseLinks": gen_links("p"),
            "saleLinks": gen_links("s"),
        }
    yd = data[yk]
    yd["purchaseAmounts"][month_idx] = purchase_total
    yd["purchaseQuantities"][month_idx] = purchase_qty
    yd["saleAmounts"][month_idx] = sale_amount
    yd["saleQuantities"][month_idx] = sale_qty
    new_content = write_data_by_year(content, m, data)
    open(path, "w", encoding="utf-8").write(new_content)


def update_all(path, year, month_idx, profit, expense):
    content = open(path, encoding="utf-8").read()
    m, data = extract_data_by_year(content)
    yk = str(year)
    if yk not in data:
        data[yk] = {"j": [0] * 12, "e": [0] * 12}
    data[yk]["j"][month_idx] = profit
    data[yk]["e"][month_idx] = expense
    new_content = write_data_by_year(content, m, data)
    open(path, "w", encoding="utf-8").write(new_content)


def fmt(v):
    return str(int(v)) if float(v) == int(v) else str(v)


def render_card(year, month_full, profit, expense, month_lower):
    p = fmt(profit)
    e = fmt(expense)
    return (
        f'    <div class="month-card" data-year="{year}">\n'
        f'      <h2>{month_full}</h2>\n'
        f'      <div class="chart-container">\n'
        f'        <div class="bar bar-phone" data-total="{p}" onclick="openPage(\'{month_lower}j.html\')">\n'
        f'          <div class="tooltip">\u20b9{p}</div><div class="bar-label">JEWELL PROFIT</div>\n'
        f'        </div>\n'
        f'        <div class="bar bar-expenses" data-total="{e}" onclick="openPage(\'{month_lower}e.html\')">\n'
        f'          <div class="tooltip">\u20b9{e}</div><div class="bar-label">EXPENSES</div>\n'
        f'        </div>\n'
        f'      </div>\n'
        f'    </div>'
    )


def update_list(path, year, month_full, month_abbr, profit, expense):
    content = open(path, encoding="utf-8").read()
    pattern = re.compile(
        r'<div class="month-card" data-year="(\d+)">\s*<h2>(\w+)</h2>.*?</div>\s*</div>\s*</div>',
        re.DOTALL,
    )
    matches = list(pattern.finditer(content))
    new_card = render_card(year, month_full, profit, expense, month_abbr.lower())

    for m in matches:
        if m.group(1) == str(year) and m.group(2) == month_full:
            content = content[: m.start()] + new_card + content[m.end():]
            open(path, "w", encoding="utf-8").write(content)
            return

    marker = '<div id="monthData">'
    idx = content.index(marker) + len(marker)
    content = content[:idx] + "\n" + new_card + content[idx:]
    open(path, "w", encoding="utf-8").write(content)


year = os.environ["YEAR"]
month_abbr = os.environ["MONTH_ABBR"]
month_full = os.environ["MONTH_FULL"]
month_idx = int(os.environ["MONTH_IDX"])
purchase_total = num(os.environ["PURCHASE_TOTAL"])
purchase_qty = num(os.environ["PURCHASE_QTY"])
sale_amount = num(os.environ["SALE_AMOUNT"])
sale_qty = num(os.environ["SALE_QTY"])
profit = num(os.environ["PROFIT"])
p_value = num(os.environ["P_VALUE"])
expense = num(os.environ["EXPENSE"])

update_sp(os.environ["SP_PATH"], year, month_idx, purchase_total, purchase_qty, sale_amount, sale_qty)
update_all(os.environ["ALL_PATH"], year, month_idx, profit, expense)
update_list(os.environ["LIST_PATH"], year, month_full, month_abbr, p_value, expense)

print("Done: sp.html, all.html and list.html updated.")
PYEOF
