-- SQL 1 validasi jumlah data

USE retail_supply_chain;

SELECT 'categories' AS nama_tabel, COUNT(*) AS jumlah_baris
FROM categories
UNION ALL
SELECT 'suppliers', COUNT(*) FROM suppliers
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'warehouses', COUNT(*) FROM warehouses
UNION ALL
SELECT 'sales_orders', COUNT(*) FROM sales_orders
UNION ALL
SELECT 'sales_order_items', COUNT(*) FROM sales_order_items
UNION ALL
SELECT 'purchase_orders', COUNT(*) FROM purchase_orders
UNION ALL
SELECT 'purchase_order_items', COUNT(*) FROM purchase_order_items
UNION ALL
SELECT 'inventory_snapshots', COUNT(*) FROM inventory_snapshots;


-- SQL 2 Data Quality check

-- 1. Cek primary key duplikat
SELECT 'products' AS tabel,
       COUNT(*) - COUNT(DISTINCT product_id) AS duplikat
FROM products

UNION ALL

SELECT 'sales_orders',
       COUNT(*) - COUNT(DISTINCT sales_order_id)
FROM sales_orders

UNION ALL

SELECT 'purchase_orders',
       COUNT(*) - COUNT(DISTINCT purchase_order_id)
FROM purchase_orders

UNION ALL

SELECT 'inventory_snapshots',
       COUNT(*) - COUNT(DISTINCT snapshot_id)
FROM inventory_snapshots;


-- 2. Cek produk tanpa kategori atau supplier
SELECT COUNT(*) AS produk_tanpa_kategori
FROM products p
LEFT JOIN categories c
    ON p.category_id = c.category_id
WHERE c.category_id IS NULL;

SELECT COUNT(*) AS produk_tanpa_supplier
FROM products p
LEFT JOIN suppliers s
    ON p.supplier_id = s.supplier_id
WHERE s.supplier_id IS NULL;


-- 3. Cek detail penjualan tanpa order atau produk
SELECT COUNT(*) AS detail_penjualan_orphan
FROM sales_order_items i
LEFT JOIN sales_orders o
    ON i.sales_order_id = o.sales_order_id
LEFT JOIN products p
    ON i.product_id = p.product_id
WHERE o.sales_order_id IS NULL
   OR p.product_id IS NULL;


-- 4. Cek detail pembelian tanpa order atau produk
SELECT COUNT(*) AS detail_pembelian_orphan
FROM purchase_order_items i
LEFT JOIN purchase_orders po
    ON i.purchase_order_id = po.purchase_order_id
LEFT JOIN products p
    ON i.product_id = p.product_id
WHERE po.purchase_order_id IS NULL
   OR p.product_id IS NULL;


-- 5. Cek kuantitas pembelian
SELECT COUNT(*) AS kuantitas_pembelian_tidak_valid
FROM purchase_order_items
WHERE ordered_qty <= 0
   OR received_qty < 0
   OR received_qty > ordered_qty;


-- 6. Cek rumus dan nilai stok
SELECT COUNT(*) AS stok_tidak_valid
FROM inventory_snapshots
WHERE ending_stock <> (
    beginning_stock
    + received_qty
    - sold_qty
    + adjustment_qty
)
OR beginning_stock < 0
OR ending_stock < 0;


-- 7. Cek kombinasi unik snapshot
SELECT COUNT(*) AS kombinasi_snapshot_duplikat
FROM (
    SELECT snapshot_month, product_id, warehouse_id
    FROM inventory_snapshots
    GROUP BY snapshot_month, product_id, warehouse_id
    HAVING COUNT(*) > 1
) AS duplikat;


-- SQL 3A: Nilai persediaan terbaru per gudang

WITH latest_month AS (
    SELECT MAX(snapshot_month) AS bulan_terbaru
    FROM inventory_snapshots
)
SELECT
    w.warehouse_name,
    COUNT(*) AS jumlah_produk,
    SUM(i.ending_stock) AS total_unit_stok,
    ROUND(SUM(i.ending_stock * i.unit_cost), 2)
        AS nilai_persediaan
FROM inventory_snapshots i
JOIN latest_month lm
    ON i.snapshot_month = lm.bulan_terbaru
JOIN warehouses w
    ON i.warehouse_id = w.warehouse_id
GROUP BY w.warehouse_id, w.warehouse_name
ORDER BY nilai_persediaan DESC;


-- SQL 3B: 20 stok terendah per produk-gudang

WITH latest_month AS (
    SELECT MAX(snapshot_month) AS bulan_terbaru
    FROM inventory_snapshots
)
SELECT
    p.product_id,
    p.product_name,
    w.warehouse_name,
    i.ending_stock AS stok_tersedia,
    p.reorder_point,
    p.selling_price,
    i.unit_cost,
    ROUND(i.ending_stock * i.unit_cost, 2)
        AS nilai_stok
FROM inventory_snapshots i
JOIN latest_month lm
    ON i.snapshot_month = lm.bulan_terbaru
JOIN products p
    ON i.product_id = p.product_id
JOIN warehouses w
    ON i.warehouse_id = w.warehouse_id
WHERE i.ending_stock <= p.reorder_point
ORDER BY i.ending_stock ASC
LIMIT 20;


-- SQL 3C: Ringkasan kebutuhan restock

WITH latest_month AS (
    SELECT MAX(snapshot_month) AS bulan_terbaru
    FROM inventory_snapshots
)
SELECT
    COUNT(*) AS total_kombinasi_produk_gudang,
    SUM(
        CASE
            WHEN i.ending_stock <= p.reorder_point THEN 1
            ELSE 0
        END
    ) AS kombinasi_perlu_restock,
    ROUND(
        SUM(i.ending_stock * i.unit_cost), 2
    ) AS total_nilai_persediaan
FROM inventory_snapshots i
JOIN latest_month lm
    ON i.snapshot_month = lm.bulan_terbaru
JOIN products p
    ON i.product_id = p.product_id;

-- SQL 4. analisis Performa Supplier

WITH supplier_delivery AS (
    -- Satu baris per purchase order
    SELECT
        supplier_id,
        purchase_order_id,
        DATEDIFF(actual_delivery_date, order_date)
            AS lead_time_hari,
        CASE
            WHEN actual_delivery_date <= expected_delivery_date
            THEN 1
            ELSE 0
        END AS tepat_waktu
    FROM purchase_orders
    WHERE purchase_status IN ('Received', 'Partial')
      AND actual_delivery_date IS NOT NULL
),

delivery_summary AS (
    SELECT
        supplier_id,
        COUNT(*) AS jumlah_order_terkirim,
        ROUND(AVG(lead_time_hari), 1)
            AS rata_rata_lead_time_hari,
        ROUND(AVG(tepat_waktu) * 100, 2)
            AS on_time_rate_persen
    FROM supplier_delivery
    GROUP BY supplier_id
),

fill_summary AS (
    -- Fill rate dihitung dari kuantitas barang
    SELECT
        po.supplier_id,
        SUM(poi.received_qty) AS total_diterima,
        SUM(poi.ordered_qty) AS total_dipesan,
        ROUND(
            100.0 * SUM(poi.received_qty)
            / NULLIF(SUM(poi.ordered_qty), 0),
            2
        ) AS fill_rate_persen
    FROM purchase_orders po
    JOIN purchase_order_items poi
        ON po.purchase_order_id = poi.purchase_order_id
    WHERE po.purchase_status IN ('Received', 'Partial')
      AND po.actual_delivery_date IS NOT NULL
    GROUP BY po.supplier_id
)

SELECT
    s.supplier_id,
    s.supplier_name,
    d.jumlah_order_terkirim,
    d.rata_rata_lead_time_hari,
    d.on_time_rate_persen,
    f.fill_rate_persen
FROM suppliers s
JOIN delivery_summary d
    ON s.supplier_id = d.supplier_id
JOIN fill_summary f
    ON s.supplier_id = f.supplier_id
WHERE d.jumlah_order_terkirim >= 5
ORDER BY
    d.rata_rata_lead_time_hari DESC,
    d.on_time_rate_persen ASC
LIMIT 20;

-- SQL 5 Trend Penjualan

SELECT
    DATE_FORMAT(o.order_date, '%Y-%m') AS bulan,
    COUNT(DISTINCT o.sales_order_id) AS total_order,
    SUM(i.quantity) AS total_unit_terjual,

    ROUND(
        SUM(i.quantity * i.unit_selling_price), 2
    ) AS revenue,

    ROUND(
        SUM(i.quantity * i.unit_cost_at_sale), 2
    ) AS cogs,

    ROUND(
        SUM(i.quantity * (i.unit_selling_price - i.unit_cost_at_sale)), 2
    ) AS profit

FROM sales_orders o
JOIN sales_order_items i
    ON o.sales_order_id = i.sales_order_id

WHERE o.order_status = 'Completed'

GROUP BY DATE_FORMAT(o.order_date, '%Y-%m')
ORDER BY bulan;

# SQL 6 produk dengan permintaan tertinggi
SELECT
    p.product_id,
    p.product_name,
    SUM(i.quantity) AS total_unit_terjual,

    ROUND(
        SUM(i.quantity * i.unit_selling_price), 2
    ) AS revenue,

    ROUND(
        SUM(
            i.quantity
            * (i.unit_selling_price - i.unit_cost_at_sale)
        ), 2
    ) AS profit

FROM sales_orders o
JOIN sales_order_items i
    ON o.sales_order_id = i.sales_order_id
JOIN products p
    ON i.product_id = p.product_id

WHERE o.order_status = 'Completed'

GROUP BY p.product_id, p.product_name
ORDER BY total_unit_terjual DESC
LIMIT 20;



