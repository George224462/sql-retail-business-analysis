-- SQL Retail Business Analysis: all queries, in the order they were run
-- Database: SQLite (DB Browser for SQLite)
-- Raw table: online_retail (imported from the Kaggle Online Retail Dataset)
-- Expected results are noted in the comments so every step can be checked.

-- =====================================================================
-- 1. PROFILING THE RAW DATA
-- =====================================================================

-- Row count. Expected: 541909
SELECT COUNT(*) FROM online_retail;

-- Date range. Expected: 2010-12-01 to 2011-12-09
SELECT MIN(InvoiceDate), MAX(InvoiceDate) FROM online_retail;

-- Rows with no customer. Expected: 135080
SELECT COUNT(*) FROM online_retail
WHERE CustomerID IS NULL OR CustomerID = '';

-- Cancellation lines. Expected: 9288
SELECT COUNT(*) FROM online_retail
WHERE InvoiceNo LIKE 'C%';

-- Non-positive quantity or price. Expected: 11805
SELECT COUNT(*) FROM online_retail
WHERE Quantity <= 0 OR UnitPrice <= 0;

-- Column types (first row only, a quick check)
SELECT typeof(Quantity), typeof(UnitPrice), typeof(InvoiceDate), typeof(CustomerID)
FROM online_retail LIMIT 1;

-- =====================================================================
-- 2. CLEAN VIEWS (the raw table is never edited)
-- =====================================================================

CREATE VIEW sales_clean AS
SELECT
    InvoiceNo,
    StockCode,
    Description,
    Quantity,
    InvoiceDate,
    UnitPrice,
    CustomerID,
    Country,
    Quantity * UnitPrice AS line_total
FROM online_retail
WHERE InvoiceNo NOT LIKE 'C%'
  AND Quantity > 0
  AND UnitPrice > 0;

-- Expected: 530104 (541909 - 11805)
SELECT COUNT(*) FROM sales_clean;

CREATE VIEW order_totals AS
SELECT InvoiceNo,
       MIN(InvoiceDate) AS order_date,
       SUM(line_total) AS order_value
FROM sales_clean
GROUP BY InvoiceNo;

-- =====================================================================
-- 3. Q1: REPEAT PURCHASES
-- =====================================================================

-- 3a. Share of eligible first-time customers who reordered within 60 days.
-- Expected: 3741 customers, 1314 repeaters, 35.1 percent
WITH first_orders AS (
    SELECT CustomerID, MIN(InvoiceDate) AS first_date
    FROM sales_clean
    WHERE CustomerID IS NOT NULL AND CustomerID <> ''
    GROUP BY CustomerID
),
eligible AS (
    SELECT CustomerID, first_date
    FROM first_orders
    WHERE first_date <= date('2011-12-09', '-60 days')
),
flagged AS (
    SELECT e.CustomerID,
           MAX(CASE WHEN s.InvoiceDate > e.first_date
                     AND s.InvoiceDate <= date(e.first_date, '+60 days')
                    THEN 1 ELSE 0 END) AS repeated
    FROM eligible e
    JOIN sales_clean s ON s.CustomerID = e.CustomerID
    GROUP BY e.CustomerID
)
SELECT COUNT(*) AS first_time_customers,
       SUM(repeated) AS repeat_customers,
       ROUND(100.0 * SUM(repeated) / COUNT(*), 1) AS repeat_rate_pct
FROM flagged;

-- 3b. Hand check: customer 17850 ordered on 2010-12-01 and 2010-12-02.
-- Run the CTEs from 3a, then end with the line below. Expected: repeated = 1
-- SELECT * FROM flagged WHERE CustomerID = 17850;

-- 3c. Among customers who had NOT reordered by day 14, share who reordered
-- on days 15 to 60. Expected: 3359 targets, 932 reordered, 27.7 percent
WITH first_orders AS (
    SELECT CustomerID, MIN(InvoiceDate) AS first_date
    FROM sales_clean
    WHERE CustomerID IS NOT NULL AND CustomerID <> ''
    GROUP BY CustomerID
),
eligible AS (
    SELECT CustomerID, first_date
    FROM first_orders
    WHERE first_date <= date('2011-12-09', '-60 days')
),
flagged AS (
    SELECT e.CustomerID,
           MAX(CASE WHEN s.InvoiceDate > e.first_date
                     AND s.InvoiceDate <= date(e.first_date, '+14 days')
                    THEN 1 ELSE 0 END) AS early_repeat,
           MAX(CASE WHEN s.InvoiceDate > date(e.first_date, '+14 days')
                     AND s.InvoiceDate <= date(e.first_date, '+60 days')
                    THEN 1 ELSE 0 END) AS late_repeat
    FROM eligible e
    JOIN sales_clean s ON s.CustomerID = e.CustomerID
    GROUP BY e.CustomerID
)
SELECT COUNT(*) AS email_targets,
       SUM(late_repeat) AS reordered_day15_to_60,
       ROUND(100.0 * SUM(late_repeat) / COUNT(*), 1) AS rate_pct
FROM flagged
WHERE early_repeat = 0;

-- 3d. Totals check: replace the final SELECT of 3c with the line below.
-- Expected: total 3741, early 382, late 1166
-- SELECT COUNT(*) AS total, SUM(early_repeat) AS early, SUM(late_repeat) AS late FROM flagged;

-- 3e. Date arithmetic check. Expected: 2010-12-15 and 2011-01-30
SELECT date('2010-12-01', '+14 days'), date('2010-12-01', '+60 days');

-- =====================================================================
-- 4. Q2: CANCELLATION RATE BY PRODUCT
-- =====================================================================

-- 4a. What the cancelled rows contain (checks for non-product codes and
-- huge single-line reversals). Cancel lines in total: 9288
SELECT StockCode,
       MIN(Description) AS description,
       SUM(-Quantity) AS cancelled_units,
       COUNT(*) AS cancel_lines
FROM online_retail
WHERE InvoiceNo LIKE 'C%'
GROUP BY StockCode
ORDER BY cancelled_units DESC
LIMIT 15;

-- 4b. Cancellation rate by product (lines, not units), products with 50+ sold lines.
-- Expected top row: 22461, 53 sold lines, 13 cancel lines, 24.5 percent
WITH sold AS (
    SELECT StockCode,
           MIN(Description) AS description,
           COUNT(*) AS sold_lines
    FROM sales_clean
    WHERE StockCode GLOB '[0-9][0-9][0-9][0-9][0-9]*'
    GROUP BY StockCode
),
cancelled AS (
    SELECT StockCode,
           COUNT(*) AS cancel_lines
    FROM online_retail
    WHERE InvoiceNo LIKE 'C%'
    GROUP BY StockCode
)
SELECT s.StockCode,
       s.description,
       s.sold_lines,
       COALESCE(c.cancel_lines, 0) AS cancel_lines,
       ROUND(100.0 * COALESCE(c.cancel_lines, 0) / s.sold_lines, 1) AS cancel_rate_pct
FROM sold s
LEFT JOIN cancelled c ON c.StockCode = s.StockCode
WHERE s.sold_lines >= 50
ORDER BY cancel_rate_pct DESC
LIMIT 10;

-- 4c. Hand checks for product 22461. Expected: 53, then 13
SELECT COUNT(*) FROM sales_clean WHERE StockCode = '22461';
SELECT COUNT(*) FROM online_retail WHERE InvoiceNo LIKE 'C%' AND StockCode = '22461';

-- =====================================================================
-- 5. Q3: ORDER VALUES AND FREE-SHIPPING THRESHOLDS (Jul to Sep 2011)
-- =====================================================================

-- 5a. Orders by value band. Expected: 362, 253, 863, 1932, 1263 (total 4673)
SELECT
    CASE WHEN order_value < 50  THEN '1: under 50'
         WHEN order_value < 100 THEN '2: 50 to 99.99'
         WHEN order_value < 200 THEN '3: 100 to 199.99'
         WHEN order_value < 500 THEN '4: 200 to 499.99'
         ELSE '5: 500 and over' END AS value_band,
    COUNT(*) AS orders,
    ROUND(100.0 * COUNT(*) /
        (SELECT COUNT(*) FROM order_totals
         WHERE order_date >= '2011-07-01' AND order_date < '2011-10-01'), 1) AS pct_of_orders
FROM order_totals
WHERE order_date >= '2011-07-01' AND order_date < '2011-10-01'
GROUP BY value_band
ORDER BY value_band;

-- 5b. Check: distinct orders in the quarter. Expected: 4673
SELECT COUNT(DISTINCT InvoiceNo) FROM sales_clean
WHERE InvoiceDate >= '2011-07-01' AND InvoiceDate < '2011-10-01';

-- 5c. Candidate thresholds. Expected pct_below / pct_near_miss:
-- 100: 13.2 / 2.3   150: 23.1 / 5.2   200: 31.6 / 6.7   300: 44.9 / 7.4
WITH q AS (
    SELECT order_value
    FROM order_totals
    WHERE order_date >= '2011-07-01' AND order_date < '2011-10-01'
),
t(threshold) AS (VALUES (100), (150), (200), (300))
SELECT t.threshold,
       ROUND(100.0 * SUM(CASE WHEN q.order_value < t.threshold THEN 1 ELSE 0 END)
             / COUNT(*), 1) AS pct_below,
       ROUND(100.0 * SUM(CASE WHEN q.order_value >= t.threshold * 0.8
                              AND q.order_value < t.threshold THEN 1 ELSE 0 END)
             / COUNT(*), 1) AS pct_near_miss
FROM t
CROSS JOIN q
GROUP BY t.threshold
ORDER BY t.threshold;
