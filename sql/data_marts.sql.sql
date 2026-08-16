-- =====================================================================
--  Olist 데이터마트 빌드 스크립트  (MySQL 8.0+)
--  구조: 원본 9테이블 → 전처리 → fact_order(중심) → 목적별 마트 5종
--  키 통일: order_id / customer_unique_id / state
--  관측기간: 2017-01-01 ~ 2018-06-30
--  ※ 각 마트는 fact_order에서 파생되어 마트 간 값이 어긋나지 않음(SSOT)
-- =====================================================================


-- =====================================================================
-- STEP 0. 전처리 (Staging)
-- =====================================================================

-- 0-1. geolocation: zip 접두사당 여러 좌표 → 평균으로 대표 좌표 1개
DROP TABLE IF EXISTS geo_zip;
CREATE TABLE geo_zip AS
SELECT geolocation_zip_code_prefix        AS zip,
       AVG(geolocation_lat)               AS lat,
       AVG(geolocation_lng)               AS lng
FROM   olist_geolocation_dataset
GROUP BY geolocation_zip_code_prefix;

CREATE INDEX idx_geo_zip ON geo_zip(zip);

SELECT * FROM geo_zip LIMIT 100;

-- 0-2. order_items_geo: items(1:N) 그레인 + 판매자주 + 하버사인 거리
--       거리 = 판매자 zip 좌표 ↔ 고객 zip 좌표 (직선거리, km)
DROP TABLE IF EXISTS order_items_geo;
CREATE TABLE order_items_geo AS
SELECT i.order_id,
       i.order_item_id,
       i.seller_id,
       s.seller_state,
       i.price,
       i.freight_value,
       6371 * 2 * ASIN(SQRT(
         POWER(SIN(RADIANS(cg.lat - sg.lat) / 2), 2) +
         COS(RADIANS(sg.lat)) * COS(RADIANS(cg.lat)) *
         POWER(SIN(RADIANS(cg.lng - sg.lng) / 2), 2)
       ))                                 AS distance_km
FROM   olist_order_items_dataset i
JOIN   olist_sellers_dataset     s  ON i.seller_id  = s.seller_id
JOIN   olist_orders_dataset      o  ON i.order_id   = o.order_id
JOIN   olist_customers_dataset   c  ON o.customer_id = c.customer_id
LEFT   JOIN geo_zip sg ON s.seller_zip_code_prefix   = sg.zip
LEFT   JOIN geo_zip cg ON c.customer_zip_code_prefix = cg.zip;

SELECT * FROM order_items_geo LIMIT 100;


-- =====================================================================
-- STEP 1. fact_order  (grain = order_id)  ── 중심 팩트
--   · items 1:N → order 단위 collapse (SUM/MAX/대표값)
--   · 배송 소요 4구간 분해 (승인→발송→운송→도착)
--   · 취소/지연/장기배송 플래그
-- =====================================================================
DROP TABLE IF EXISTS fact_order;
CREATE TABLE fact_order AS
SELECT
    o.order_id,
    c.customer_unique_id,
    c.customer_state,
    i.seller_state,
    o.order_status,
    o.order_purchase_timestamp                                   AS order_purchase_ts,
    DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m')             AS order_ym,
    CASE WHEN o.order_status = 'canceled' THEN 1 ELSE 0 END      AS is_canceled,
-- ── 배송 소요 4구간 분해 ──────────────────────────────────
    TIMESTAMPDIFF(HOUR,  o.order_purchase_timestamp, o.order_approved_at)                       AS approving_time_h,   -- 결제→승인
    TIMESTAMPDIFF(SECOND, o.order_approved_at,        o.order_delivered_carrier_date)/86400     AS preprocessing_day,  -- 승인→발송(셀러)
    TIMESTAMPDIFF(SECOND, o.order_delivered_carrier_date, o.order_delivered_customer_date)/86400 AS transit_day,       -- 발송→도착(운송)
    TIMESTAMPDIFF(SECOND, o.order_approved_at,        o.order_delivered_customer_date)/86400     AS delivery_days,      -- 승인→도착(총)
--     ── 지연/장기배송 (개념 구분) ────────────────────────────
    DATEDIFF(o.order_delivered_customer_date, o.order_estimated_delivery_date)                  AS estimate_diff,      -- 예상일 대비
    CASE WHEN DATEDIFF(o.order_delivered_customer_date, o.order_estimated_delivery_date) > 0
         THEN 1 ELSE 0 END                                                                     AS is_late,            -- 지연(예상 초과)
    CASE WHEN TIMESTAMPDIFF(SECOND, o.order_approved_at, o.order_delivered_customer_date)/86400 >= 30
         THEN 1 ELSE 0 END                                                                     AS is_prolonged,       -- 장기배송(절대 30일+)
    i.order_value,
    i.distance_km,
    rv.review_score
FROM        olist_orders_dataset    o
JOIN        olist_customers_dataset c  ON o.customer_id = c.customer_id
LEFT JOIN ( -- ★ items(1:N) → order 단위로 접기
    SELECT order_id,
           SUM(price + freight_value)                                            AS order_value,
           MAX(distance_km)                                                      AS distance_km,   -- 대표(최대) 거리
           SUBSTRING_INDEX(GROUP_CONCAT(seller_state ORDER BY price DESC), ',', 1) AS seller_state -- 최고가 품목의 판매자주
    FROM   order_items_geo
    GROUP  BY order_id
) i  ON o.order_id = i.order_id
LEFT JOIN ( -- 주문당 리뷰 1개로 축약 (중복 방지)
    SELECT order_id, MAX(review_score) AS review_score
    FROM   olist_order_reviews_dataset
    GROUP  BY order_id
) rv ON o.order_id = rv.order_id
WHERE o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-07-01';   -- 관측기간 고정(절단 편향 제거)

 SELECT * FROM fact_order LIMIT 100;


-- =====================================================================
-- STEP 2. dim_customer_rfm  (grain = customer_unique_id)  → RFM 대시보드
--   · Recency/Monetary = NTILE(10),  Frequency = 1/2/3
--   · 고객별 avg_review / avg_delivery (RFM × 리뷰·배송)
-- =====================================================================
DROP TABLE IF EXISTS dim_customer_rfm;
CREATE TABLE dim_customer_rfm AS
WITH agg AS (   -- 고객 단위 집계
    SELECT customer_unique_id,
           DATEDIFF('2018-06-30', MAX(order_purchase_ts))   AS recency,
           COUNT(DISTINCT order_id)                         AS frequency,
           AVG(review_score)                                AS avg_review,
           AVG(CASE WHEN transit_day > 0 THEN delivery_days END) AS avg_delivery
    FROM   fact_order
    WHERE  order_status = 'delivered'      
  	AND  order_value IS NOT NULL      
    GROUP  BY customer_unique_id
), first_val AS (  -- 첫 주문 결제액 = Monetary
    SELECT customer_unique_id, order_value AS monetary
    FROM (
        SELECT customer_unique_id, order_value,
               ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                                  ORDER BY order_purchase_ts) AS rn
        FROM   fact_order
        WHERE  order_status = 'delivered'    
        AND  order_value IS NOT NULL      
    ) t
    WHERE rn = 1
)
SELECT a.customer_unique_id,
       a.recency,
       a.frequency,
       fv.monetary,
       a.avg_review,
       a.avg_delivery,
       NTILE(10) OVER (ORDER BY a.recency DESC)  AS r_score,   -- 최근일수록 10점
       CASE WHEN a.frequency >= 3 THEN 3
            WHEN a.frequency  = 2 THEN 2
            ELSE 1 END                           AS f_score,
       NTILE(10) OVER (ORDER BY fv.monetary)     AS m_score,   -- 고액일수록 10점
       CASE WHEN a.frequency >= 2 THEN 1 ELSE 0 END AS is_repeat
FROM   agg a
JOIN   first_val fv ON a.customer_unique_id = fv.customer_unique_id;

SELECT * FROM dim_customer_rfm LIMIT 1000;

-- =====================================================================
-- STEP 3. agg_review_score  (grain = review_score)  → 만족도 대시보드(표)
--   · 취소율/취소금액/평균결제/평균배송
--   · canceled_value_rate(% of total)는 Tableau 표계산으로 처리
-- =====================================================================
DROP TABLE IF EXISTS agg_review_score;
CREATE TABLE agg_review_score AS
SELECT review_score,
       COUNT(*)                                              AS total_order,
       SUM(is_canceled)                                      AS canceled_order,
       ROUND(SUM(is_canceled) / COUNT(*) * 100, 2)           AS canceled_rate,
       SUM(CASE WHEN is_canceled = 1 THEN order_value END)   AS canceled_value,
       SUM(order_value)                                      AS total_revenue,
       ROUND(AVG(order_value), 1)                            AS avg_monetary,
       ROUND(AVG(CASE WHEN is_canceled = 0 AND transit_day > 0 THEN delivery_days END), 1) AS avg_delivery
FROM   fact_order
WHERE  review_score IS NOT NULL
GROUP  BY review_score
ORDER  BY review_score;

SELECT * FROM agg_review_score LIMIT 100;

-- =====================================================================
-- STEP 4. agg_monthly  (grain = order_ym)  → 만족도 대시보드(월별)
-- =====================================================================
DROP TABLE IF EXISTS agg_monthly;
CREATE TABLE agg_monthly AS
SELECT order_ym,
       ROUND(AVG(CASE WHEN is_canceled = 0 THEN review_score END), 2)  AS avg_review,
       ROUND(AVG(CASE WHEN is_canceled = 0 AND transit_day > 0 THEN delivery_days END), 1) AS avg_delivery,
       SUM(CASE WHEN is_canceled = 1 THEN order_value END)             AS canceled_revenue
FROM   fact_order
GROUP  BY order_ym
ORDER  BY order_ym;

SELECT * FROM agg_monthly LIMIT 100;

-- =====================================================================
-- STEP 5. agg_state  (grain = state)  → 배송 대시보드(지도)
--   · 고객수 + 판매자수를 한 마트에 (블렌드 불필요)
--   · 두 축의 주(state)를 UNION으로 모두 확보
-- =====================================================================
DROP TABLE IF EXISTS agg_state;
CREATE TABLE agg_state AS
WITH states AS (
    SELECT DISTINCT customer_state AS state FROM fact_order
    UNION
    SELECT DISTINCT seller_state         FROM order_items_geo
)
SELECT s.state,
       (SELECT COUNT(DISTINCT f.customer_unique_id)
        FROM   fact_order f      WHERE f.customer_state = s.state) AS customer_cnt,
       (SELECT COUNT(DISTINCT g.seller_id)
        FROM   order_items_geo g WHERE g.seller_state   = s.state) AS seller_cnt
FROM   states s
WHERE  s.state IS NOT NULL;

SELECT * FROM agg_state LIMIT 100;


-- =====================================================================
-- STEP 6. dim_seller  (grain = seller_id)  → 지도 판매자 좌표(점)
-- =====================================================================
DROP TABLE IF EXISTS dim_seller;
CREATE TABLE dim_seller AS
SELECT s.seller_id,
       s.seller_state,
       s.seller_zip_code_prefix AS zip,
       g.lat,
       g.lng
FROM   olist_sellers_dataset s
LEFT   JOIN geo_zip g ON s.seller_zip_code_prefix = g.zip;

SELECT * FROM dim_seller LIMIT 100;

-- =====================================================================
-- STEP 7. 데이터 정합성 · 품질 검증  (실행해서 결과 확인용)
-- =====================================================================

-- (1) PK 유일성: 두 값이 같아야 함 (order_id 중복 없음)
SELECT COUNT(*) AS rows_cnt, COUNT(DISTINCT order_id) AS pk_cnt FROM fact_order;

-- (2) 1:N 카디널리티: 원본 items가 order당 여러 행인지 확인
SELECT order_id, COUNT(*) AS item_cnt
FROM   olist_order_items_dataset
GROUP  BY order_id HAVING COUNT(*) > 1 LIMIT 10;

-- (3) 참조 무결성: 고객 매칭 안 되는 고아 주문 탐지 (0 이어야 정상)
SELECT COUNT(*) AS orphan_orders
FROM   olist_orders_dataset o
LEFT   JOIN olist_customers_dataset c ON o.customer_id = c.customer_id
WHERE  c.customer_id IS NULL;

-- (4) 행 수 정합성(reconciliation): 마트 고객 총합 = 팩트 고유 고객수
SELECT (SELECT SUM(customer_cnt) FROM agg_state)                       AS state_sum,
       (SELECT COUNT(DISTINCT customer_unique_id) FROM fact_order)     AS fact_cust;

-- (5) 이상치·결측: 운송 0/음수, 승인 결측 건수
SELECT SUM(transit_day <= 0)             AS bad_transit,
       SUM(order_purchase_ts IS NULL)    AS null_ts
FROM   fact_order;

-- (6) 재구매율 확인 (≈ 3.04%)
SELECT ROUND(AVG(is_repeat) * 100, 2) AS repeat_rate_pct FROM dim_customer_rfm;
