#!/usr/bin/env python3
"""Re-check every saved result in Result/ against the raw Olist data.

Rebuilds the warehouse from 02_transform_build_dwh.sql and the 14 queries in
03_business_queries.sql with pandas, following the T-SQL rules exactly (including
how SQL Server averages INT columns and how it sorts FORMAT()ed text). Then:

  1. compares each rebuilt result with the CSV saved in Result/,
  2. shows what the three corrected queries return, and
  3. prints the extra figures quoted on the case-study page (index.html).

Run from the repository root:
    pip install pandas numpy
    python analysis/recheck_numbers.py
Optional argument: a different path to the data zip or to a folder of the CSVs.
"""
import sys
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATA = ROOT / "Brazilian E-Commerce Public Datas.zip.giz.zip"
RESULT = ROOT / "Result"

ID = str  # ids and zip prefixes stay text so leading zeros survive


# ---------------------------------------------------------------- load
def load(src):
    src = Path(src)
    if src.is_dir():
        def opener(name):
            return open(next(src.rglob(name)), "rb")
    else:
        z = zipfile.ZipFile(src)
        names = {Path(n).name: n for n in z.namelist()
                 if not n.startswith("__MACOSX") and n.endswith(".csv")}

        def opener(name):
            return z.open(names[name])

    def read(name, **kw):
        with opener(name) as f:
            return pd.read_csv(f, **kw)

    t = {
        "customers": read("olist_customers_dataset.csv", dtype=ID),
        "geolocation": read("olist_geolocation_dataset.csv", dtype={"geolocation_zip_code_prefix": ID}),
        "sellers": read("olist_sellers_dataset.csv", dtype=ID),
        "products": read("olist_products_dataset.csv", dtype={"product_id": ID, "product_category_name": ID}),
        "orders": read("olist_orders_dataset.csv", dtype=ID),
        "order_items": read("olist_order_items_dataset.csv", dtype={"order_id": ID, "product_id": ID, "seller_id": ID}),
        "order_payments": read("olist_order_payments_dataset.csv", dtype={"order_id": ID}),
        "order_reviews": read("olist_order_reviews_dataset.csv", dtype={"review_id": ID, "order_id": ID}),
        "category_translation": read("product_category_name_translation.csv", dtype=ID),
    }
    o = t["orders"]
    for c in ["order_purchase_timestamp", "order_approved_at", "order_delivered_carrier_date",
              "order_delivered_customer_date", "order_estimated_delivery_date"]:
        o[c] = pd.to_datetime(o[c])
    r = t["order_reviews"]
    for c in ["review_creation_date", "review_answer_timestamp"]:
        r[c] = pd.to_datetime(r[c])
    return t


# ---------------------------------------------------------------- T-SQL behaviour
def sql_avg_int(s):
    """AVG() over an INT column in SQL Server returns an INT (truncated)."""
    s = s.dropna()
    return int(np.trunc(s.mean())) if len(s) else np.nan


def datediff_day(a, b):
    """DATEDIFF(DAY, a, b) counts midnights crossed, not 24-hour periods."""
    return (b.dt.normalize() - a.dt.normalize()).dt.days


def datediff_hour(a, b):
    hour = pd.offsets.Hour()
    return (b.dt.floor(hour) - a.dt.floor(hour)).dt.total_seconds() / 3600


def pct_text(x):
    """FORMAT(x, 'P') returns text such as '9.76%'."""
    return f"{x * 100:.2f}%"


def money(s):
    return float(str(s).replace("$", "").replace(",", ""))


def pct(s):
    return float(str(s).replace("%", "").strip())


# ---------------------------------------------------------------- warehouse (02)
def build(t):
    w = {}
    geo = t["geolocation"]
    w["Dim_Geolocation"] = geo.groupby("geolocation_zip_code_prefix").agg(
        avg_lat=("geolocation_lat", "mean"), avg_lng=("geolocation_lng", "mean"))

    p = t["products"].merge(t["category_translation"], on="product_category_name", how="left")
    p["category_name"] = (p["product_category_name_english"]
                          .fillna(p["product_category_name"]).fillna("Unknown"))
    w["Dim_Products"] = p[["product_id", "category_name"]]

    r = t["order_reviews"].copy()
    r["_k"] = r["review_answer_timestamp"].fillna(r["review_creation_date"])
    w["Dim_Reviews"] = r.sort_values("_k", ascending=False).drop_duplicates("review_id")

    items = t["order_items"]
    fin = items.groupby("order_id").agg(total_order_value=("price", "sum"),
                                        total_freight=("freight_value", "sum"),
                                        items_count=("price", "size")).reset_index()
    fo = t["orders"].merge(t["customers"], on="customer_id", how="left").merge(fin, on="order_id", how="left")
    fo[["total_order_value", "total_freight", "items_count"]] = (
        fo[["total_order_value", "total_freight", "items_count"]].fillna(0))
    lead = datediff_day(fo["order_purchase_timestamp"], fo["order_delivered_customer_date"])
    lead[fo["order_delivered_customer_date"] < fo["order_purchase_timestamp"]] = np.nan
    fo["actual_lead_time_days"] = lead
    fo["is_late_delivery"] = (fo["order_delivered_customer_date"] > fo["order_estimated_delivery_date"]).astype(int)
    w["Fact_Orders"] = fo
    w["Fact_Order_Items"] = items
    w["Dim_Customer"] = t["customers"]
    w["Dim_Sellers"] = t["sellers"]

    # vw_order_metrics (03, part A): primary category = most expensive item; reviews joined on order_id
    it = items.merge(w["Dim_Products"], on="product_id", how="left")
    primary = it.sort_values("price", ascending=False).drop_duplicates("order_id")[["order_id", "category_name"]]
    vw = (fo.merge(primary, on="order_id", how="left")
            .merge(w["Dim_Reviews"][["order_id", "review_score"]], on="order_id", how="left"))
    vw["gmv"] = vw["total_order_value"]
    w["vw"] = vw
    w["items_cat"] = it
    return w


# ---------------------------------------------------------------- report helpers
ROWS = []


def report(q, title, ok, note="", fixed=""):
    ROWS.append((q, title, ok, note, fixed))
    mark = "reproduces" if ok else "DIFFERS"
    print(f"\n{q:>4}  {title}\n      {mark}{' - ' + note if note else ''}")
    if fixed:
        print(f"      corrected query: {fixed}")


CR_FOUND = []


def read_result(name):
    """Read a saved result. Category names saved from SQL Server end in a hidden carriage
    return: product_category_name_translation.csv has Windows (CRLF) line endings but was
    loaded with ROWTERMINATOR = '0x0a', so '\\r' stayed on every English name. Strip it."""
    df = pd.read_csv(RESULT / name)
    for c in df.columns:
        if df[c].dtype == object or pd.api.types.is_string_dtype(df[c]):
            s = df[c].astype(str)
            if s.str.endswith("\r").any():
                CR_FOUND.append(name)
            df[c] = s.str.rstrip("\r").str.strip()
    return df


# ---------------------------------------------------------------- the 14 queries (03)
def queries(t, w):
    vw, fo, items = w["vw"], w["Fact_Orders"], w["Fact_Order_Items"]
    dv = vw[vw["order_status"] == "delivered"]
    fixed_out = {}

    # Q1
    pub = read_result("Top 10 Product Categories by Revenue.csv")
    g = dv.groupby("category_name").agg(rev=("gmv", "sum"),
                                        rating_int=("review_score", sql_avg_int),
                                        rating=("review_score", "mean")).sort_values("rev", ascending=False).head(10)
    pr = pub.set_index("category_name")
    ok = (list(g.index) == list(pr.index)
          and all(abs(g.loc[c, "rev"] / money(pr.loc[c, "Total_Revenue"]) - 1) < 0.005 for c in g.index)
          and all(g.loc[c, "rating_int"] == float(pr.loc[c, "Avg_Rating"]) for c in g.index))
    fixed_out["Q1"] = g["rating"].round(2)
    report("Q1", "Top 10 categories by revenue", ok, "same ten categories, revenue within 0.5%",
           "AVG(CAST(review_score AS FLOAT)) gives ratings "
           f"{g['rating'].min():.2f}-{g['rating'].max():.2f}, not 4.00 for every category")

    # Q2
    pub = read_result("Delivery Performance by State.csv")
    s = dv.groupby("customer_state").agg(rows=("order_id", "size"), orders=("order_id", "nunique"),
                                         late=("is_late_delivery", "mean"))
    s = s[s["rows"] > 100]
    s["late_text"] = s["late"].map(pct_text)
    as_text = s.sort_values("late_text", ascending=False).head(5)
    ok = (list(as_text.index) == list(pub["customer_state"])
          and all(abs(as_text.loc[st, "late"] * 100 - pct(v)) < 0.05
                  for st, v in zip(pub["customer_state"], pub["Late_Rate"])))
    num = s.sort_values("late", ascending=False)
    fixed_out["Q2"] = num
    report("Q2", "Delivery performance by state (top 5 late rates)", ok,
           "same five states as saved: " + ", ".join(as_text.index),
           "ORDER BY the number, not the FORMAT()ed text, gives "
           + ", ".join(f"{st} {r * 100:.1f}%" for st, r in num.head(5)["late"].items()))

    # Q3
    pub = read_result("Monthly Sales Trend.csv")
    d3 = dv[dv["order_purchase_timestamp"] >= "2017-01-01"]
    m = d3.groupby(d3["order_purchase_timestamp"].dt.strftime("%Y-%m"))["gmv"].sum()
    diffs = [abs(m[r.Sales_Month] / money(r.Revenue) - 1) for r in pub.itertuples()]
    report("Q3", "Monthly sales trend", max(diffs) < 0.005, f"20 months, largest gap {max(diffs):.2%}")
    fixed_out["Q3"] = m

    # Q4
    pub = read_result("Delivery Speed vs Review Score Correlation.csv")
    d4 = dv[dv["actual_lead_time_days"].notna()].copy()
    d4["bucket"] = pd.cut(d4["actual_lead_time_days"], [-np.inf, 5, 10, 20, np.inf],
                          labels=["0-5 Days (Fast)", "6-10 Days (Normal)", "11-20 Days (Slow)", "20+ Days (Critical)"])
    b = d4.groupby("bucket", observed=True).agg(rows=("order_id", "size"),
                                                score_int=("review_score", sql_avg_int),
                                                score=("review_score", "mean"),
                                                low=("review_score", lambda x: (x.dropna() <= 2).mean()))
    pr = pub.set_index("Delivery_Speed_Bucket")
    ok = all(b.loc[k, "score_int"] == float(pr.loc[k, "Avg_Review_Score"])
             and abs(b.loc[k, "rows"] / pr.loc[k, "Orders"] - 1) < 0.005 for k in b.index)
    fixed_out["Q4"] = b
    report("Q4", "Delivery speed vs review score", ok, "same integer averages (4, 4, 4, 3), order counts within 0.5%",
           "AVG(CAST(review_score AS FLOAT)) gives "
           + ", ".join(f"{v:.2f}" for v in b["score"]) + "; share of 1-2 star reviews "
           + ", ".join(f"{v:.1%}" for v in b["low"]))

    # Q5
    pub = read_result("Customer Retention Rate.csv").set_index("Buyer_Type")
    cf = fo.groupby("customer_unique_id")["order_id"].nunique()
    one, rep = int((cf == 1).sum()), int((cf > 1).sum())
    report("Q5", "Customer retention", one == pub.loc["One-Time Buyer", "Customer_Count"]
           and rep == pub.loc["Repeat Buyer", "Customer_Count"], f"{one:,} one-time of {len(cf):,} customers ({one / len(cf):.2%})")

    # Q6
    pub = read_result("Payment method.csv").set_index("payment_type")
    share = t["order_payments"].groupby("payment_type")["order_id"].nunique() / len(fo)
    report("Q6", "Payment method mix", all(abs(share[k] * 100 - pct(pub.loc[k, "Order_Share"])) < 0.05 for k in pub.index),
           f"boleto {share['boleto']:.2%} of orders")

    # Q7
    pub = read_result("Freight Cost Ratio.csv").set_index("category_name")
    d7 = dv[dv["gmv"] > 0].assign(r=lambda x: x["total_freight"] / x["gmv"])
    f7 = d7.groupby("category_name")["r"].agg(["size", "mean"])
    f7 = f7[f7["size"] > 500].sort_values("mean", ascending=False).head(10)
    ok = set(f7.index) == set(pub.index) and all(
        abs(f7.loc[c, "mean"] * 100 - pub.loc[c, "Avg_Freight_Pct_Of_Price"]) < 0.25 for c in f7.index)
    report("Q7", "Freight cost ratio", ok, f"electronics {f7.loc['electronics', 'mean']:.1%} (saved 68.8%)")

    # Q8
    pub = read_result("Seller Concentration.csv")
    ss = items.groupby("seller_id")["price"].sum().sort_values(ascending=False)
    deciles = np.array_split(ss.values, 10)  # NTILE(10): larger groups first, like array_split
    shares = [d.sum() / ss.sum() * 100 for d in deciles]
    report("Q8", "Seller concentration (deciles)",
           all(abs(a - pct(b)) < 0.05 for a, b in zip(shares, pub["Share_of_Total"])),
           f"top decile ({len(deciles[0])} of {len(ss):,} sellers) {shares[0]:.2f}%")

    # Q9
    pub = read_result("Operational Mess Scale.csv").set_index("order_status")["Count"]
    vc = fo["order_status"].value_counts()
    report("Q9", "Order status counts", all(vc[k] == pub[k] for k in pub.index), f"{len(fo):,} orders")

    # Q10
    pub = pct(read_result("Global Late Delivery Rate.csv").iloc[0, 0])
    late = dv["is_late_delivery"].mean() * 100
    report("Q10", "Global late delivery rate", abs(late - pub) < 0.05, f"{late:.2f}% (saved {pub:.2f}%)")

    # Q11
    pub = read_result("Logistics Breakdown (Bottleneck Analysis).csv").set_index("customer_state")
    d11 = dv.assign(
        approve=datediff_hour(dv["order_purchase_timestamp"], dv["order_approved_at"]),
        pack=datediff_hour(dv["order_approved_at"], dv["order_delivered_carrier_date"]),
        transit=datediff_hour(dv["order_delivered_carrier_date"], dv["order_delivered_customer_date"]))
    stages = d11.groupby("customer_state")[["approve", "pack", "transit"]].agg(sql_avg_int) / 24
    top = stages.sort_values("transit", ascending=False).head(5)
    ok = list(top.index) == list(pub.index) and all(
        abs(top.loc[st, "transit"] - pub.loc[st, "Days_In_Transit"]) < 0.05 for st in top.index)
    report("Q11", "Logistics breakdown (slowest transit)", ok,
           f"RR {top.loc['RR', 'transit']:.2f} days in transit")
    fixed_out["Q11"] = top

    # Q12
    pub = read_result("Product Affinity.csv")
    it = w["items_cat"][["order_id", "product_id", "category_name"]]
    pairs = it.merge(it, on="order_id", suffixes=("_a", "_b"))
    pairs = pairs[(pairs["product_id_a"] != pairs["product_id_b"]) & (pairs["category_name_a"] < pairs["category_name_b"])]
    pc = pairs.groupby(["category_name_a", "category_name_b"]).size().sort_values(ascending=False).head(5)
    ok = all(pc.get((r.Category_A, r.Category_B), -1) == r.Times_Bought_Together for r in pub.itertuples())
    report("Q12", "Product affinity (category pairs)", ok, f"top pair counted {pc.iloc[0]} times (item pairs)")

    # Q13
    pub = read_result("Seller Matrix.csv").set_index("seller_id")
    sm = items.merge(w["Dim_Reviews"][["order_id", "review_score"]], on="order_id", how="left").groupby("seller_id").agg(
        orders=("order_id", "nunique"), rating=("review_score", "mean"))
    sm = sm[sm["orders"] > 20].sort_values("orders", ascending=False)
    gap = max(abs(sm.loc[s, "rating"] - float(pub.loc[s, "Rating"])) for s in pub.index)
    ok = all(sm.loc[s, "orders"] == int(pub.loc[s, "Orders"]) for s in pub.index) and gap < 0.05
    # Ratings can move by a few hundredths: 814 review_ids repeat across orders, and which
    # order keeps a repeated review depends on how ROW_NUMBER() breaks ties.
    report("Q13", "Seller matrix (top 30 sellers)", ok, f"orders exact, ratings within {gap:.2f}")
    fixed_out["Q13"] = sm

    # Q14
    pub = read_result("Purchasing Data (Day x Hour).csv")
    h = vw.groupby([vw["order_purchase_timestamp"].dt.day_name(), vw["order_purchase_timestamp"].dt.hour]).size()
    gaps = [abs(h[(r.Day_Of_Week, int(r.Hour_Of_Day))] - int(r.Orders)) for r in pub.itertuples()]
    report("Q14", "Purchasing heatmap (day x hour)", max(gaps) <= 5,
           f"{len(pub)} cells, largest gap {max(gaps)} orders")
    return fixed_out


# ---------------------------------------------------------------- figures quoted on the page
def page_figures(t, w, fixed):
    fo, items, vw = w["Fact_Orders"], w["Fact_Order_Items"], w["vw"]
    dv = vw[vw["order_status"] == "delivered"]
    print("\n\nFIGURES QUOTED ON THE CASE-STUDY PAGE")
    print("-" * 60)
    total = 0
    for k, v in t.items():
        total += len(v)
        print(f"raw {k:<24}{len(v):>12,}")
    print(f"raw rows, all nine files      {total:>12,}")
    print(f"Dim_Geolocation zip codes     {len(w['Dim_Geolocation']):>12,}")
    print(f"Dim_Reviews after dedupe      {len(w['Dim_Reviews']):>12,}  "
          f"({t['order_reviews']['review_id'].duplicated().sum()} repeated review_ids)")
    print(f"products with no category     {(w['Dim_Products']['category_name'] == 'Unknown').sum():>12,}")
    print(f"category names after join     {w['Dim_Products']['category_name'].nunique():>12,}")
    print(f"unique customers (people)     {fo['customer_unique_id'].nunique():>12,}")
    print(f"view rows vs orders           {len(vw):,} vs {len(fo):,}  "
          f"(delivered GMV +{dv['gmv'].sum() / fo.loc[fo['order_status'] == 'delivered', 'total_order_value'].sum() - 1:.2%} from orders with 2+ reviews)")
    print(f"purchase dates                {fo['order_purchase_timestamp'].min():%d %b %Y} to {fo['order_purchase_timestamp'].max():%d %b %Y}")

    m = fixed["Q3"]
    y18 = m[[f"2018-{i:02d}" for i in range(1, 9)]].sum()
    y17 = m[[f"2017-{i:02d}" for i in range(1, 9)]].sum()
    print(f"\nrevenue Aug 2018 / Jan 2017   {m['2018-08'] / m['2017-01']:.2f}x")
    print(f"revenue Jan-Aug 2018 / 2017   {y18 / y17:.2f}x")
    print(f"2018 monthly range            R${m[m.index >= '2018-01'].min():,.0f} to R${m[m.index >= '2018-01'].max():,.0f}")
    print(f"peak month                    {m.idxmax()} R${m.max():,.0f}")

    ss = items.groupby("seller_id")["price"].sum().sort_values(ascending=False)
    for k in (50, 100):
        print(f"top {k} sellers' revenue share  {ss.head(k).sum() / ss.sum():.1%}")
    print(f"bottom half of sellers share  {ss.iloc[len(ss) // 2:].sum() / ss.sum():.1%}")

    q2 = fixed["Q2"]
    q2 = q2.assign(late_orders=(q2["rows"] * q2["late"]).round().astype(int))
    print("\nlate rate by state (delivered, >100 rows), numeric sort:")
    print(q2.head(8)[["orders", "late", "late_orders"]].assign(late=lambda x: (x["late"] * 100).round(1)).to_string())
    print("most late orders:", ", ".join(f"{s} {n:,}" for s, n in q2["late_orders"].sort_values(ascending=False).head(5).items()))
    print(f"delivered orders RR {(dv['customer_state'] == 'RR').sum()}, AP {(dv['customer_state'] == 'AP').sum()}, "
          f"AM {(dv['customer_state'] == 'AM').sum()}")

    e = dv[(dv["category_name"] == "electronics") & (dv["gmv"] > 0)]
    print(f"\nelectronics orders where freight > item price  {(e['total_freight'] > e['gmv']).mean():.1%}, "
          f"median item value R${e['gmv'].median():.2f}")

    end = fo["order_purchase_timestamp"].max()
    sh = fo[fo["order_status"] == "shipped"]
    print(f"orders stuck at 'shipped'     {len(sh):,}; bought 60+ days before data ends: "
          f"{(sh['order_purchase_timestamp'] < end - pd.Timedelta(days=60)).sum():,}")
    print(f"orders not delivered (any)    {(fo['order_status'] != 'delivered').sum():,} "
          f"({(fo['order_status'] != 'delivered').mean():.1%})")

    n_prod = items.groupby("order_id")["product_id"].nunique()
    n_cat = w["items_cat"].groupby("order_id")["category_name"].nunique()
    it = w["items_cat"]
    both = set(it.loc[it["category_name"] == "bed_bath_table", "order_id"]) & set(
        it.loc[it["category_name"] == "furniture_decor", "order_id"])
    print(f"orders with 2+ different products {(n_prod >= 2).mean():.1%}; with 2+ categories {(n_cat >= 2).mean():.1%}; "
          f"orders with bed_bath_table + furniture_decor {len(both)}")

    sm = fixed["Q13"]
    big = sm[sm["orders"] > 50]
    risk, star = big[big["rating"] < 3.0], big[big["rating"] > 4.5]
    print(f"top-20 sellers rated below 3.5: {(sm.head(20)['rating'] < 3.5).sum()} "
          f"(lowest {sm.head(20)['rating'].min():.2f}); RISK sellers {len(risk)} with {ss[risk.index].sum() / ss.sum():.1%} of revenue; "
          f"STAR sellers {len(star)}")

    ts = vw["order_purchase_timestamp"]
    per_day = vw.groupby(ts.dt.day_name()).size() / ts.dt.normalize().groupby(ts.dt.day_name()).nunique()
    print("orders per calendar day:", ", ".join(f"{d[:3]} {v:.0f}" for d, v in per_day.sort_values(ascending=False).items()))
    print(f"orders placed 18:00-23:59     {(ts.dt.hour >= 18).mean():.1%}")

    q4 = fixed["Q4"]
    print("\ndelivery speed buckets (corrected):")
    print(q4.assign(score=lambda x: x["score"].round(2), low=lambda x: (x["low"] * 100).round(1)).to_string())
    print("\ntop-10 category ratings (corrected):", ", ".join(f"{c} {r:.2f}" for c, r in fixed["Q1"].items()))


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DATA
    print(f"Loading {src} ...")
    t = load(src)
    w = build(t)
    fixed = queries(t, w)
    n_ok = sum(r[2] for r in ROWS)
    n_fix = sum(1 for r in ROWS if r[4])
    print(f"\nSUMMARY: {n_ok} of {len(ROWS)} saved results reproduce from the raw data; "
          f"{n_fix} queries need a fix (Q1, Q2, Q4).")
    if CR_FOUND:
        print("Note: category names in " + ", ".join(sorted(set(CR_FOUND))) + " end in a hidden '\\r' "
              "(CRLF translation file loaded with ROWTERMINATOR = '0x0a').")
    page_figures(t, w, fixed)


if __name__ == "__main__":
    main()
