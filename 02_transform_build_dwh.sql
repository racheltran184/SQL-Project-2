USE olist_db;
GO

-- 1. Safe Schema Creation
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'dwh')
BEGIN
    EXEC('CREATE SCHEMA dwh');
END
GO

PRINT 'Building Dim_Geolocation...';
DROP TABLE IF EXISTS dwh.Dim_Geolocation; -- FIX: Drop to prevent "Table exists" error

WITH Geo_Frequency AS (
    SELECT 
        geolocation_zip_code_prefix,
        geolocation_city,
        geolocation_state,
        COUNT(*) as freq,
        ROW_NUMBER() OVER (PARTITION BY geolocation_zip_code_prefix ORDER BY COUNT(*) DESC) as rn
    FROM olist.geolocation
    GROUP BY geolocation_zip_code_prefix, geolocation_city, geolocation_state
),
Geo_Centroids AS (
    SELECT 
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) as avg_lat,
        AVG(geolocation_lng) as avg_lng
    FROM olist.geolocation
    GROUP BY geolocation_zip_code_prefix
)
SELECT 
    c.geolocation_zip_code_prefix AS zip_code,
    c.avg_lat,
    c.avg_lng,
    f.geolocation_city AS city,
    f.geolocation_state AS state
INTO dwh.Dim_Geolocation
FROM Geo_Centroids c
JOIN Geo_Frequency f ON c.geolocation_zip_code_prefix = f.geolocation_zip_code_prefix
WHERE f.rn = 1;

ALTER TABLE dwh.Dim_Geolocation ALTER COLUMN zip_code VARCHAR(10) NOT NULL;
ALTER TABLE dwh.Dim_Geolocation ADD CONSTRAINT PK_Dim_Geo PRIMARY KEY (zip_code);
GO

PRINT 'Building Dim_Products...';
DROP TABLE IF EXISTS dwh.Dim_Products; -- FIX

SELECT 
    p.product_id,
    COALESCE(t.product_category_name_english, p.product_category_name, 'Unknown') AS category_name,
    p.product_photos_qty,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
INTO dwh.Dim_Products
FROM olist.products p
LEFT JOIN olist.product_category_name_translation t 
    ON p.product_category_name = t.product_category_name;

ALTER TABLE dwh.Dim_Products ALTER COLUMN product_id VARCHAR(32) NOT NULL;
ALTER TABLE dwh.Dim_Products ADD CONSTRAINT PK_Dim_Products PRIMARY KEY (product_id);
GO

PRINT 'Building Dim_Reviews...';
DROP TABLE IF EXISTS dwh.Dim_Reviews; -- FIX

WITH Reviews_Ranked AS (
    SELECT 
        review_id,
        order_id,
        review_score,
        review_comment_title,
        review_comment_message,
        review_creation_date,
        review_answer_timestamp,
        -- FIX: Fallback to creation date if answer date is NULL
        ROW_NUMBER() OVER (
            PARTITION BY review_id 
            ORDER BY COALESCE(review_answer_timestamp, review_creation_date) DESC
        ) as rn
    FROM olist.order_reviews
)
SELECT 
    review_id,
    order_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp
INTO dwh.Dim_Reviews
FROM Reviews_Ranked
WHERE rn = 1; 

ALTER TABLE dwh.Dim_Reviews ALTER COLUMN review_id VARCHAR(32) NOT NULL;
ALTER TABLE dwh.Dim_Reviews ADD CONSTRAINT PK_Dim_Reviews PRIMARY KEY (review_id);
GO

PRINT 'Building Fact_Orders...';
DROP TABLE IF EXISTS dwh.Fact_Orders; -- FIX

-- FIX: Calculate Financials first (Pre-Aggregation)
-- We must aggregate items to the Order grain to join them to Fact_Orders
WITH Order_Financials AS (
    SELECT 
        order_id,
        SUM(price) AS total_order_value,
        SUM(freight_value) AS total_freight,
        COUNT(*) AS items_count
    FROM olist.order_items
    GROUP BY order_id
)
SELECT 
    o.order_id,
    o.customer_id,
    o.order_status,
    o.order_purchase_timestamp,
    
    -- Financials (Added)
    ISNULL(f.total_order_value, 0) AS total_order_value,
    ISNULL(f.total_freight, 0) AS total_freight,
    ISNULL(f.items_count, 0) AS items_count,

    -- Logistics
    CASE 
        WHEN o.order_delivered_customer_date < o.order_purchase_timestamp THEN NULL
        ELSE DATEDIFF(DAY, o.order_purchase_timestamp, o.order_delivered_customer_date)
    END AS actual_lead_time_days,

    DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) AS delivery_gap_days,

    -- Flags
    CASE WHEN o.order_status = 'delivered' THEN 1 ELSE 0 END AS is_delivered,
    CASE WHEN o.order_status IN ('canceled', 'unavailable') THEN 1 ELSE 0 END AS is_canceled,
    
    CASE 
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date THEN 1 
        ELSE 0 
    END AS is_late_delivery,

    -- Dimensions
    c.customer_city,
    c.customer_state,
    c.customer_zip_code_prefix AS customer_zip

INTO dwh.Fact_Orders
FROM olist.orders o
LEFT JOIN olist.customers c ON o.customer_id = c.customer_id
LEFT JOIN Order_Financials f ON o.order_id = f.order_id; -- FIX: Join Financials

ALTER TABLE dwh.Fact_Orders ALTER COLUMN order_id VARCHAR(32) NOT NULL;
ALTER TABLE dwh.Fact_Orders ADD CONSTRAINT PK_Fact_Orders PRIMARY KEY (order_id);
GO

PRINT 'Building Dim_Customer...';
DROP TABLE IF EXISTS dwh.Dim_Customer;

SELECT 
    c.customer_id,          -- The Key on the Order
    c.customer_unique_id,   -- The Real Person (for retention)
    c.customer_city,
    c.customer_state,
    c.customer_zip_code_prefix
INTO dwh.Dim_Customer
FROM olist.customers c;

ALTER TABLE dwh.Dim_Customer ALTER COLUMN customer_id VARCHAR(32) NOT NULL;
ALTER TABLE dwh.Dim_Customer ADD CONSTRAINT PK_Dim_Cust PRIMARY KEY (customer_id);
GO

PRINT 'Building Dim_Sellers...';
DROP TABLE IF EXISTS dwh.Dim_Sellers;

SELECT 
    s.seller_id,
    s.seller_city,
    s.seller_state,
    s.seller_zip_code_prefix
INTO dwh.Dim_Sellers
FROM olist.sellers s;

ALTER TABLE dwh.Dim_Sellers ALTER COLUMN seller_id VARCHAR(32) NOT NULL;
ALTER TABLE dwh.Dim_Sellers ADD CONSTRAINT PK_Dim_Seller PRIMARY KEY (seller_id);
GO

PRINT 'Building Fact_Order_Items...';
DROP TABLE IF EXISTS dwh.Fact_Order_Items;

-- This table tracks individual line items (vital for "Market Basket" analysis)
SELECT 
    oi.order_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    oi.price,
    oi.freight_value
INTO dwh.Fact_Order_Items
FROM olist.order_items oi;

-- Composite Primary Key (Order + Item Number)
ALTER TABLE dwh.Fact_Order_Items ALTER COLUMN order_id VARCHAR(32) NOT NULL;
ALTER TABLE dwh.Fact_Order_Items ALTER COLUMN order_item_id INT NOT NULL;
ALTER TABLE dwh.Fact_Order_Items ADD CONSTRAINT PK_Fact_Items PRIMARY KEY (order_id, order_item_id);
GO

-- Validation
SELECT 'Geolocation' AS TableName, COUNT(*) AS Rows FROM dwh.Dim_Geolocation
UNION ALL
SELECT 'Products', COUNT(*) FROM dwh.Dim_Products
UNION ALL
SELECT 'Reviews', COUNT(*) FROM dwh.Dim_Reviews
UNION ALL
SELECT 'Customers', COUNT(*) FROM dwh.Dim_Customer 
UNION ALL
SELECT 'Sellers', COUNT(*) FROM dwh.Dim_Sellers    
UNION ALL
SELECT 'Fact_Orders', COUNT(*) FROM dwh.Fact_Orders
UNION ALL
SELECT 'Fact_Items', COUNT(*) FROM dwh.Fact_Order_Items;

