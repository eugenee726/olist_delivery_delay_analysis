# Olist: Delivery-Driven Customer Satisfaction (KPI) Analysis

> 🇰🇷 [한국어 README](README.md)

> Diagnosing the key driver of **Review Score (KPI)** — a leading indicator of repurchase — in a low-retention marketplace, and translating the analysis into data-driven marketing actions.

**`DBeaver` · `MySQL` · `Python (Pandas, SciPy, Seaborn)` · `Tableau`**

**📊 [View Interactive Dashboards on Tableau Public](https://public.tableau.com/app/profile/yujin.park5440/viz/olist_project_17861784755450/conclusion)** — RFM Segmentation · Customer Satisfaction · Prolonged Delivery Analysis

---

## 📌 Project Overview

| Item | Detail |
|---|---|
| **Title** | Olist: Delivery-Driven Customer Satisfaction (KPI) Analysis |
| **Goal** | Diagnose the key factor driving Review Score (KPI), a leading indicator of repurchase, and derive improvement directions |
| **Period** | 2026.07.19 – 2026.08.02 |
| **Result** | Identified delivery as the KPI driver · split delay causes (long- vs mid-distance) · verified monthly delivery improvement lifts KPI |
| **Data** | [Olist Brazilian E-Commerce (Kaggle)](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) · 9 tables · 2017.01–2018.06 |
| **Stack** | DBeaver, MySQL, Python (Pandas, SciPy, Seaborn), Tableau |

---

## 1. Problem Definition

### 1) Background
Olist is a **B2B e-commerce platform** that acts as a single gateway for small sellers to reach Brazil's large marketplaces. Unlike Coupang or Amazon, it has a **structurally low repurchase rate** — most customers churn after a single purchase.

### 2) Goal
Because repurchase is extremely rare (hard to manage LTV/Frequency), repurchase rate is unsuitable as an outcome metric. Instead, we set **Customer Satisfaction (Review Score) as the KPI**, since it directly relates to **brand reputation, new-customer acquisition, and cancellation prevention**.

Grounded in evidence that satisfaction is a significant leading factor of repurchase intent — especially sensitive in the low-score range (Yoo Hyun-mi, 2017; *JCR*) — the project aims to **diagnose the key driver of the KPI and derive improvement directions**.

---

## 2. Hypotheses

Based on the delivery–satisfaction relationship found in EDA:

- **H1.** As delivery time lengthens, customer satisfaction (Review) falls and cancellation rate rises sharply.
- **H2.** Delivery delays are caused by the distance between seller and customer.

---

## 3. Data Collection & Analysis

### 1) Collection & Cleaning (SQL)

**EDA**
- Olist public dataset (Kaggle): ~100K orders (2016–2018) across **9 tables** (orders, items, customers, sellers, payments, reviews, geolocation, etc.).
- Loaded into **MySQL via DBeaver**.
- **Observation window:** `2017-01-01 – 2018-06-30` (18 months), verified complete without missing records.
- Analyzed table relationships by `order_id` / `customer_unique_id`; compared category, payment, and **delivery delay by region**.

**Data Mart Design**

Built **purpose-specific marts derived from a single fact table (`fact_order`)** as the single source of truth (SSOT). SQL handles aggregation/cleaning; Tableau handles relationship-based joins and visualization.

*Architecture — star schema (1 fact + 5 marts)*

| Mart | Grain | Dashboard | Key SQL |
|---|---|---|---|
| **fact_order** | order_id | (central) | 9-table JOIN, 1:N collapse, delivery 4-stage split |
| dim_customer_rfm | customer_unique_id | RFM | `NTILE(10)`·`ROW_NUMBER()` |
| agg_review_score | review_score | Satisfaction (table) | `CASE` aggregation |
| agg_monthly | month | Monthly trend | `DATE_FORMAT` |
| agg_state | state | Map | Combined customer/seller counts |
| dim_seller | seller_id | Seller distribution | Haversine coordinate join |

*Design decisions & data integrity/quality validation*
- **Unified grain:** delivery, review, and cancellation are all order-level events, so the fact grain is fixed at `order_id`, with RFM rolled up to `customer_unique_id`.
- **1:N cardinality:** collapsed orders : items (1:N) to order level and **validated `order_id` PK uniqueness** (0 orphan orders).
- **Delivery 4-stage split:** approved → shipped → transit → delivered, enabling bottleneck tracing (transit = 85%).
- **Blend removed:** pre-aggregated customer & seller counts into `agg_state` for a single-source map.
- **Fan-out prevented:** marts of differing grain are combined via **Tableau relationships (logical layer)** instead of physical joins, avoiding aggregation inflation.
- **Integrity check:** a 28-row gap in row-count reconciliation was confirmed to be **customers ordering across multiple states** (expected).
- **Quality control:** excluded outliers (transit ≤ 0, 30 rows), handled empty timestamps, fixed the observation window, and filtered RFM to **delivered (actual purchase) orders**.
- **Basis stated:** repurchase rate managed separately as **2.98% (delivered) / 3.04% (all orders)**.

Full build script: [`01_sql/30_data_marts.sql`](01_sql/30_data_marts.sql)

### 2) Dashboards & Findings (Tableau)

**RFM Segmentation**
- Recency & Monetary scored in deciles; Frequency in 1/2/3 tiers.
- **96.96% of customers are single-purchase (repurchase 3.04%)** → standard RFM segmentation is limited.
- Across all three axes, **faster delivery → higher review** (higher-spend segments ship slower / score lower); Recency in particular shows an inverse review–delivery pattern, indicating **delivery drives the Review (KPI)**.

**Customer Satisfaction × Delivery — stage decomposition**

| Stage | Score 1 | Score 5 | Gap | Share |
|---|---|---|---|---|
| Transit | 17.73 | 8.30 | 9.43d | ~85% |
| Preprocessing | 4.25 | 2.53 | 1.72d | ~15% |
| **Total (arrived)** | **21.98** | **10.83** | **11.15d** | **100%** |

- Lower reviews correspond to sharply longer delivery — **delivery time is directly tied to satisfaction**.
- **85% of the gap occurs in the transit stage**; seller-prep and payment-approval have minimal impact.

**Cancellation & P&L by Delivery Time**
- **Cancellations concentrate in the low-review (1-star) band** — cancel rate ~**47×** that of 5-star, and average delivery ~2× longer.
- **Losses also concentrate in 1-star** — **76%** of total cancellation loss sits in the 1-star band, and its per-order value (**193.5 BRL**) is the highest, amplifying the loss.

### 3) In-depth Delivery Diagnosis (Python)

**Review × Delivery Relationship**

| Avg lateness | Avg delivery | Avg transit | Avg preprocessing | On-time review | Late review |
|---|---|---|---|---|---|
| -11.34d | 12.47d | 9.19d | 2.84d | 4.3 | 2.45 |

- Reviews collapse as delivery lengthens; **median drops below 2 once delivery exceeds 30 days**.
- Delivery is mostly transit; both are right-tailed → a **small set of extreme prolonged deliveries** exists.
- Late orders are only **8.3%**, but their review (2.45) is far below on-time (4.3).

**Customer & Seller Distribution and Distance**
- **Sellers are heavily concentrated near the capital (SP) / southeast**, while customers span the north, northeast, and interior nationwide.
- For prolonged orders (30+ days), sellers remain in the southeast while customers skew further to the north/northeast/interior.
- Median distance: **439 km** overall vs **825 km** for prolonged orders (~2×) → **prolonged orders concentrate at long distances**.

**Regional Delivery & Distance Analysis**
- Fast states: southeast (SP·RJ·MG); slow states: north/northeast (RR·AP·AM·PA·MA·AL) → the farther from the seller hub (SP), the slower.
- Distance computed via the **Haversine formula**: longer distance → longer transit (**Spearman 0.61**); distance is a **structural driver** of transit.
- However, the distance distribution of 30+ day orders is **bimodal** — long-distance (2,000km+) reflects a distance problem, while mid-distance (300–900km) shows **33.7 days (3.4× the 9.9-day norm)**, an **operational anomaly unexplained by distance**.
- → Delays split into two axes: **long-distance structural issue (regional hub)** and **mid-distance operational issue (carrier exception management)**.

---

## 4. Results & Recommendations

### 1) Findings

**H1. Longer delivery → lower satisfaction & higher cancellation → Accepted**
- 85% (9.43d) of the 11.15-day review 1–5 delivery gap occurs in **transit**, and reviews collapse below a median of 2 once delivery exceeds 30 days. *(transit bottleneck)*
- 1-star **cancel rate is ~47×** that of 5-star, **76% of cancellation loss concentrates in 1-star**, and its average delivery (**21.9 days**) is the longest. *(P&L loss)*
- After the peak-delivery month (**2018-02**), as delivery shortened, **reviews recovered in tandem** → the inverse delivery–review relationship holds on the time axis too.

> **Insight:** Delivery delay, low satisfaction, and cancellation converge in the 1-star band, showing that poor delivery quality translates beyond reputation into **direct financial loss (P&L)**.

**H2. Delays are caused by seller–customer distance → Partially rejected · dual cause**
- Overall, longer distance → longer transit (Spearman 0.61), but the 30+ day orders form a **bimodal distribution** splitting the cause:
  - **Long-distance (2,000km+):** a **structural** geographic limit
  - **Mid-distance (300–900km):** delays of **33.7 days — 3.4× the 9.9-day norm** — concentrate here

> **Insight:** Partially rejecting "distance causes delay," the hidden driver of extreme prolonged delivery is estimated to be **carrier mishandling / operational incidents**, not distance.

### 2) Conclusion & Recommendations

**Conclusion**
In a low-repurchase (3.04%) marketplace, **delivery is the factor that drives Review (KPI)** — the leading indicator of repurchase — and improving delivery restores the KPI. Where repurchase is structurally hard, marketing can act as a **lever that defends against negative delivery experiences and capitalizes on positive ones to protect reputation and new-customer inflow**.

**Recommendations — distance-based 3-tier strategy**

| Distance tier | Delivery / Review | Marketing action |
|---|---|---|
| **Near** (southeast) | Fast · high review | **"Fast delivery" positioning** (conversion/acquisition) |
| **Long** (2,000km+) | Structural delay · low review | **30-day-trigger expectation management** (defense) |
| **Mid** (300–900km) | Operational delay 3.4× · low review | **Root-cause investigation first** + defense |

- **Near — capitalize on strength:** feature "fast delivery" front-and-center in ads/PDPs for fast regions & categories to strengthen conversion and satisfaction.
- **Long — expectation-management CRM:** close the expectation–experience gap with realistic delivery estimates and stage-by-stage tracking alerts. In particular, **auto-flag orders with an estimate exceeding 30 days as "high-risk"** and send proactive communication from order time to defend against 1-star reviews / cancellations.
- **Mid — investigate root cause first:** operational delay unexplained by distance requires **internal investigation and logistics-team collaboration** (e.g., carrier mishandling) before action.

> ✅ Marketing manages delivery experience differentially by distance — capitalizing positives via "fast delivery" positioning and defending negatives via 30-day-trigger expectation management — acting as a lever to protect reputation and new-customer inflow even where repurchase is hard.

---

## 5. Retrospective

**Keep**
- Double-verified the delivery↔review (KPI) inverse relationship from **two angles — by review score (cross-section) and by month (time series)** — securing robustness.
- Went beyond the simple "it's the distance" hypothesis to **discover a bimodal distribution**, surfacing the mid-distance operational-incident twist.
- Executed the practical analytics loop end-to-end: **SQL (mart) → Tableau (discovery) → Python (deep-dive) → Tableau (synthesis)**.

**Problem**
- No **carrier identifier** in the data, so the specific logistics vendor behind mid-distance delays could not be pinpointed.
- Distance used **straight-line (Haversine)** rather than actual road routes, introducing error.
- With structurally low repurchase, Review was used as a **proxy KPI**, so the direct causal link between delivery and repurchase could not be established.

**Try**
- **Real-time detection of mid-distance delays via anomaly-detection algorithms**, plus enriching carrier / order-status data, could narrow operational bottlenecks to the vendor level.
- **Securing behavioral event (session/conversion) data** would enable growth-oriented funnel/cohort analysis.

---

## 🛠 Tech Stack

| Stage | Tool | Role |
|---|---|---|
| Load & mart design | DBeaver, MySQL | 9-table JOIN, delivery-stage split, purpose-built marts |
| Discovery & viz | Tableau | RFM segmentation, delivery↔review dashboards, P&L |
| Deep-dive diagnosis | Python (Pandas, SciPy, Seaborn) | Correlation, distance (Haversine), bimodal distribution |

## 📁 Repository Structure

```
.
├── README.md            # Korean
├── README.en.md         # English
├── notebooks/
│   └── olist_delivery_analysis.ipynb   # Delivery deep-dive (Python)
├── sql/
│   └── data_marts.sql               # Mart build script
└── data/                # (raw CSVs downloaded separately from Kaggle)
```

## 🔗 References
- Dataset: [Olist Brazilian E-Commerce (Kaggle)](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
- Olist business model: [olist.com](https://olist.com/)
- Yoo Hyun-mi (2017), Nonlinear relationship between customer satisfaction and repurchase intention, *JCR*