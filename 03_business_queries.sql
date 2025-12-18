USE olist_db;
GO

Print('=========================================================')
Print('PART A: THE SEMANTIC LAYER')
Print('=========================================================')

PRINT 'Creating Semantic View: dwh.vw_order_metrics...';
GO

CREATE OR ALTER VIEW dwh.vw_order_metrics AS
SELECT 
    f.order_id,
    f.customer_id,
    f.order_status,
    
    -- Date Mapping (Friendly Names for Analysts)
    CAST(f.order_purchase_timestamp AS DATE) AS purchase_date,
    f.order_purchase_timestamp AS purchase_ts,
    f.order_approved_at AS approved_ts,
    f.order_delivered_carrier_date AS carrier_ts,
    f.order_delivered_customer_date AS delivered_ts,
    f.order_estimated_delivery_date AS estimated_ts,
    
    -- Dimensions
    c.customer_city,
    c.customer_state,
    
    -- Product Category Logic:
    -- An order might have multiple items. We pick the category of the most expensive item
    -- to define the "Primary Category" of the order.
    (SELECT TOP 1 p.category_name 
     FROM dwh.Fact_Order_Items foi
     JOIN dwh.Dim_Products p ON foi.product_id = p.product_id 
     WHERE foi.order_id = f.order_id 
     ORDER BY foi.price DESC) AS category_name,
    
    -- Financials
    f.total_order_value AS gmv,
    f.total_freight,
    f.items_count,
    
    -- Logistics Metrics
    f.actual_lead_time_days,
    f.delivery_gap_days, -- Positive = Early, Negative = Late
    f.is_late_delivery,
    
    -- Quality Metrics
    r.review_score,
    CASE 
        WHEN r.review_score <= 2 THEN 'Detractor'
        WHEN r.review_score >= 4 THEN 'Promoter'
        ELSE 'Passive'
    END AS nps_bucket

FROM dwh.Fact_Orders f
LEFT JOIN dwh.Dim_Customer c ON f.customer_id = c.customer_id
LEFT JOIN dwh.Dim_Reviews r ON f.order_id = r.order_id;
GO

PRINT 'View Created Successfully.';
PRINT '----------------------------------------------------';
PRINT 'PART B: THE 10 CORE BUSINESS QUESTIONS';
PRINT '----------------------------------------------------';

-- Q1. Top 10 Product Categories by Revenue (GMV)
SELECT TOP 10
    category_name,
    FORMAT(SUM(gmv), 'C', 'en-US') AS Total_Revenue,
    COUNT(DISTINCT order_id) AS Total_Orders,
    CAST(AVG(review_score) AS DECIMAL(3,2)) AS Avg_Rating
FROM dwh.vw_order_metrics
WHERE order_status = 'delivered'
GROUP BY category_name
ORDER BY SUM(gmv) DESC;

-- Q2. Delivery Performance by State (Logistics Bottlenecks)
SELECT TOP 5
    customer_state,
    COUNT(DISTINCT order_id) AS Orders,
    CAST(AVG(actual_lead_time_days) AS DECIMAL(4,1)) AS Avg_Days_To_Deliver,
    FORMAT(SUM(CASE WHEN is_late_delivery = 1 THEN 1 ELSE 0 END) * 1.0 / COUNT(*), 'P') AS Late_Rate
FROM dwh.vw_order_metrics
WHERE order_status = 'delivered'
GROUP BY customer_state
HAVING COUNT(*) > 100 
ORDER BY Late_Rate DESC;

-- Q3. Monthly Sales Trend (Seasonality)
SELECT 
    FORMAT(purchase_date, 'yyyy-MM') AS Sales_Month,
    FORMAT(SUM(gmv), 'C', 'en-US') AS Revenue
FROM dwh.vw_order_metrics
WHERE order_status = 'delivered' AND purchase_date >= '2017-01-01'
GROUP BY FORMAT(purchase_date, 'yyyy-MM')
ORDER BY Sales_Month DESC;

-- Q4. Review Score vs Delivery Speed Correlation
SELECT 
    CASE 
        WHEN actual_lead_time_days <= 5 THEN '0-5 Days (Fast)'
        WHEN actual_lead_time_days <= 10 THEN '6-10 Days (Normal)'
        WHEN actual_lead_time_days <= 20 THEN '11-20 Days (Slow)'
        ELSE '20+ Days (Critical)'
    END AS Delivery_Speed_Bucket,
    COUNT(*) as Orders,
    CAST(AVG(review_score) AS DECIMAL(3,2)) AS Avg_Review_Score
FROM dwh.vw_order_metrics
WHERE order_status = 'delivered' AND actual_lead_time_days IS NOT NULL
GROUP BY CASE 
        WHEN actual_lead_time_days <= 5 THEN '0-5 Days (Fast)'
        WHEN actual_lead_time_days <= 10 THEN '6-10 Days (Normal)'
        WHEN actual_lead_time_days <= 20 THEN '11-20 Days (Slow)'
        ELSE '20+ Days (Critical)'
    END
ORDER BY Avg_Review_Score DESC;

-- Q5. Customer Retention Rate (Lifetime Value Check)
WITH CustomerFrequency AS (
    SELECT customer_unique_id, COUNT(DISTINCT order_id) as Lifetime_Orders
    FROM dwh.Dim_Customer c
    JOIN dwh.Fact_Orders f ON c.customer_id = f.customer_id
    GROUP BY customer_unique_id
)
SELECT 
    CASE WHEN Lifetime_Orders = 1 THEN 'One-Time Buyer' ELSE 'Repeat Buyer' END AS Buyer_Type,
    COUNT(*) as Customer_Count,
    FORMAT(COUNT(*) * 1.0 / (SELECT COUNT(*) FROM CustomerFrequency), 'P') as Share_of_Base
FROM CustomerFrequency
GROUP BY CASE WHEN Lifetime_Orders = 1 THEN 'One-Time Buyer' ELSE 'Repeat Buyer' END;

-- Q6. Payment Method Mix
SELECT 
    p.payment_type,
    FORMAT(SUM(p.payment_value), 'C', 'en-US') as Total_Volume,
    FORMAT(COUNT(DISTINCT p.order_id) * 1.0 / (SELECT COUNT(*) FROM dwh.Fact_Orders), 'P') as Order_Share
FROM olist.order_payments p
GROUP BY p.payment_type
ORDER BY SUM(p.payment_value) DESC;

-- Q7. Freight Cost Ratio
SELECT TOP 10
    category_name,
    CAST(AVG(total_freight / NULLIF(gmv, 0)) * 100 AS DECIMAL(5,1)) AS Avg_Freight_Pct_Of_Price
FROM dwh.vw_order_metrics
WHERE order_status = 'delivered' AND gmv > 0
GROUP BY category_name
HAVING COUNT(*) > 500
ORDER BY Avg_Freight_Pct_Of_Price DESC;

-- Q8. Seller Concentration (Pareto Principle)
WITH SellerSales AS (
    SELECT seller_id, SUM(price) as Revenue
    FROM dwh.Fact_Order_Items
    GROUP BY seller_id
),
RankedSellers AS (
    SELECT Revenue, NTILE(10) OVER (ORDER BY Revenue DESC) as Decile
    FROM SellerSales
)
SELECT 
    Decile,
    FORMAT(SUM(Revenue), 'C', 'en-US') as Total_Revenue,
    FORMAT(SUM(Revenue) * 1.0 / (SELECT SUM(Revenue) FROM SellerSales), 'P') as Share_of_Total
FROM RankedSellers
GROUP BY Decile
ORDER BY Decile;

-- Q9. The "Operational Mess" Scale
SELECT order_status, COUNT(*) as Count
FROM dwh.Fact_Orders
GROUP BY order_status
ORDER BY Count DESC;

-- Q10. Global Late Delivery Rate
SELECT 
    FORMAT(SUM(CASE WHEN is_late_delivery = 1 THEN 1 ELSE 0 END) * 1.0 / COUNT(*), 'P') as Late_Delivery_Rate
FROM dwh.vw_order_metrics
WHERE order_status = 'delivered';


PRINT '----------------------------------------------------';
PRINT 'PART C: ADVANCED DATA SCIENCE ANALYTICS';
PRINT '----------------------------------------------------';

-- Q11. Logistics Breakdown (Bottleneck Analysis)
-- Insight: Does the delay happen at Approval, Packing (Seller), or Transit (Carrier)?
SELECT TOP 5
    customer_state,
    AVG(DATEDIFF(HOUR, purchase_ts, approved_ts))/24.0 as Days_To_Approve,
    AVG(DATEDIFF(HOUR, approved_ts, carrier_ts))/24.0 as Days_To_Pack,
    AVG(DATEDIFF(HOUR, carrier_ts, delivered_ts))/24.0 as Days_In_Transit
FROM dwh.vw_order_metrics
WHERE order_status = 'delivered'
GROUP BY customer_state
ORDER BY Days_In_Transit DESC;

-- Q12. Product Affinity (Market Basket Analysis)
SELECT TOP 5
    p1.category_name as Category_A,
    p2.category_name as Category_B,
    COUNT(*) as Times_Bought_Together
FROM dwh.Fact_Order_Items oi1
JOIN dwh.Fact_Order_Items oi2 
    ON oi1.order_id = oi2.order_id 
    AND oi1.product_id != oi2.product_id -- Match distinct products in same order
JOIN dwh.Dim_Products p1 ON oi1.product_id = p1.product_id
JOIN dwh.Dim_Products p2 ON oi2.product_id = p2.product_id
WHERE p1.category_name < p2.category_name -- FIX: Enforce alphabetical order & exclude same-cat
GROUP BY p1.category_name, p2.category_name
ORDER BY Times_Bought_Together DESC;

-- Q13. Seller Matrix (High Volume vs High Quality)
SELECT TOP 30
    s.seller_id,
    COUNT(DISTINCT oi.order_id) as Orders,
    CAST(AVG(CAST(r.review_score AS FLOAT)) AS DECIMAL(3,2)) as Rating,
    CASE 
        WHEN COUNT(DISTINCT oi.order_id) > 50 AND AVG(CAST(r.review_score AS FLOAT)) < 3.0 THEN 'RISK'
        WHEN COUNT(DISTINCT oi.order_id) > 50 AND AVG(CAST(r.review_score AS FLOAT)) > 4.5 THEN 'STAR'
        ELSE 'Normal'
    END as Seller_Segment
FROM dwh.Dim_Sellers s
JOIN dwh.Fact_Order_Items oi ON s.seller_id = oi.seller_id
LEFT JOIN dwh.Dim_Reviews r ON oi.order_id = r.order_id
GROUP BY s.seller_id
HAVING COUNT(DISTINCT oi.order_id) > 20
ORDER BY Orders DESC;

-- Q14. Purchasing Heatmap Data (Day x Hour)
-- Insight: Use this for Ad Spend targeting.
SELECT 
    DATENAME(WEEKDAY, purchase_ts) AS Day_Of_Week,
    DATEPART(HOUR, purchase_ts) AS Hour_Of_Day,
    COUNT(*) as Orders
FROM dwh.vw_order_metrics
GROUP BY DATENAME(WEEKDAY, purchase_ts), DATEPART(HOUR, purchase_ts)
ORDER BY COUNT(*) DESC;

PRINT 'Analysis Complete.';