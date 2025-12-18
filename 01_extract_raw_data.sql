-- 1. CREATE DB
CREATE DATABASE olist_db;
GO
USE olist_db;
GO

-- 2. SETUP SCHEMA
CREATE SCHEMA olist;
GO

-- 3. CREATE TABLES
-- Customers
CREATE TABLE olist.customers (
customer_id VARCHAR(32) PRIMARY KEY,
customer_unique_id VARCHAR(32),
customer_zip_code_prefix VARCHAR(10),
customer_city NVARCHAR(100),
customer_state CHAR(2)
);

-- Geolocation
CREATE TABLE olist.geolocation (
geolocation_zip_code_prefix VARCHAR(10),
geolocation_lat DECIMAL(18,15),
geolocation_lng DECIMAL(18,15),
geolocation_city NVARCHAR(100),
geolocation_state CHAR(2)
);

-- Sellers
CREATE TABLE olist.sellers (
seller_id VARCHAR(32) PRIMARY KEY,
seller_zip_code_prefix VARCHAR(10),
seller_city NVARCHAR(100),
seller_state CHAR(2)
);

-- Products
CREATE TABLE olist.products (
product_id VARCHAR(32) PRIMARY KEY,
product_category_name NVARCHAR(100),
product_name_lenght INT,
product_description_lenght INT,
product_photos_qty INT,
product_weight_g INT,
product_length_cm INT,
product_height_cm INT,
product_width_cm INT
);

-- Orders
CREATE TABLE olist.orders (
order_id VARCHAR(32) PRIMARY KEY,
customer_id VARCHAR(32),
order_status VARCHAR(50),
order_purchase_timestamp DATETIME2,
order_approved_at DATETIME2,
order_delivered_carrier_date DATETIME2,
order_delivered_customer_date DATETIME2,
order_estimated_delivery_date DATETIME2
);

-- Order Items
CREATE TABLE olist.order_items (
order_id VARCHAR(32),
order_item_id INT,
product_id VARCHAR(32),
seller_id VARCHAR(32),
shipping_limit_date DATETIME2,
price DECIMAL(10,2),
freight_value DECIMAL(10,2)
);

-- Order Payments
CREATE TABLE olist.order_payments (
order_id VARCHAR(32),
payment_sequential INT,
payment_type VARCHAR(50),
payment_installments INT,
payment_value DECIMAL(10,2)
);

-- Order Reviews
CREATE TABLE olist.order_reviews (
review_id VARCHAR(32),
order_id VARCHAR(32),
review_score INT,
review_comment_title NVARCHAR(MAX),
review_comment_message NVARCHAR(MAX),
review_creation_date DATETIME2,
review_answer_timestamp DATETIME2
);

-- Category Translation
CREATE TABLE olist.product_category_name_translation (
product_category_name NVARCHAR(100),
product_category_name_english NVARCHAR(100)
);
GO
-- 4.IMPORT DATA
USE olist_db;
GO

-- 1. Customers
BULK INSERT olist.customers
FROM '/var/opt/mssql/data/olist_customers_dataset.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a');

-- 2. Geolocation
BULK INSERT olist.geolocation
FROM '/var/opt/mssql/data/olist_geolocation_dataset.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a');

-- 3. Sellers
BULK INSERT olist.sellers
FROM '/var/opt/mssql/data/olist_sellers_dataset.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a');

-- 4. Products
BULK INSERT olist.products
FROM '/var/opt/mssql/data/olist_products_dataset.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a');

-- 5. Orders
BULK INSERT olist.orders
FROM '/var/opt/mssql/data/olist_orders_dataset.csv'
WITH (
FORMAT = 'CSV',
FIRSTROW = 2,
FIELDTERMINATOR = ',',
ROWTERMINATOR = '0x0a'
);

-- 6. Order Items
BULK INSERT olist.order_items
FROM '/var/opt/mssql/data/olist_order_items_dataset.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a');

-- 7. Order Payments
BULK INSERT olist.order_payments
FROM '/var/opt/mssql/data/olist_order_payments_dataset.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a');

-- 8. Order Reviews
BULK INSERT olist.order_reviews
FROM '/var/opt/mssql/data/olist_order_reviews_dataset.csv'
WITH (
FORMAT = 'CSV',
FIRSTROW = 2,
FIELDTERMINATOR = ',',
ROWTERMINATOR = '0x0a'
);

-- 9. Product Category Translations
BULK INSERT olist.product_category_name_translation
FROM '/var/opt/mssql/data/product_category_name_translation.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a');

USE olist_db;
GO

SELECT 
    t.name AS Table_Name,
    s.name AS Schema_Name,
    p.rows AS Row_Count,
    CASE 
        WHEN p.rows = 0 THEN 'EMPTY - CHECK IMPORT' 
        ELSE 'OK' 
    END AS Status
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE s.name = 'olist' 
  AND p.index_id IN (0, 1) 
ORDER BY p.rows DESC;

